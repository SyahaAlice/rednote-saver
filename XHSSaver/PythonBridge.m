#import "PythonBridge.h"

#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>

static BOOL gStarted = NO;
static NSString *gStartError = nil;

static void AppendPath(PyConfig *config, NSString *path) {
    wchar_t *w = Py_DecodeLocale(path.UTF8String, NULL);
    if (w) {
        PyWideStringList_Append(&config->module_search_paths, w);
        PyMem_RawFree(w);
    }
}

/// 取出当前 Python 异常的文字说明（调用时必须持有 GIL）
static NSString *CurrentPythonError(void) {
    PyObject *type = NULL, *value = NULL, *tb = NULL;
    PyErr_Fetch(&type, &value, &tb);
    PyErr_NormalizeException(&type, &value, &tb);
    NSString *text = @"未知的 Python 错误";
    PyObject *s = value ? PyObject_Str(value) : (type ? PyObject_Str(type) : NULL);
    if (s) {
        const char *c = PyUnicode_AsUTF8(s);
        if (c) {
            NSString *name = type ? [NSString stringWithUTF8String:((PyTypeObject *)type)->tp_name] : @"";
            text = [NSString stringWithFormat:@"%@: %@", name, [NSString stringWithUTF8String:c]];
        }
        Py_DECREF(s);
    }
    PyErr_Clear();
    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(tb);
    return text;
}

BOOL XHSPythonStart(NSString *firstPath, NSString **error) {
    @synchronized([NSBundle class]) {
        if (gStarted) return YES;
        if (gStartError) {
            if (error) *error = gStartError;
            return NO;
        }

        NSString *resources = [[NSBundle mainBundle] resourcePath];
        NSString *home = [resources stringByAppendingPathComponent:@"python"];
        NSString *stdlib = [home stringByAppendingPathComponent:@"lib/python3.13"];

        PyStatus status;
        PyPreConfig preconfig;
        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;
        status = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(status)) {
            gStartError = [NSString stringWithFormat:@"Python 预初始化失败：%s", status.err_msg ?: "?"];
            if (error) *error = gStartError;
            return NO;
        }

        PyConfig config;
        PyConfig_InitIsolatedConfig(&config);
        config.install_signal_handlers = 0;
        config.write_bytecode = 0;
        config.buffered_stdio = 0;
        status = PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
        if (!PyStatus_Exception(status)) {
            config.module_search_paths_set = 1;
            if (firstPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:firstPath]) {
                AppendPath(&config, firstPath);
            }
            AppendPath(&config, stdlib);
            AppendPath(&config, [stdlib stringByAppendingPathComponent:@"lib-dynload"]);
            AppendPath(&config, [resources stringByAppendingPathComponent:@"app"]);
            AppendPath(&config, [resources stringByAppendingPathComponent:@"app_packages"]);
            status = Py_InitializeFromConfig(&config);
        }
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            gStartError = [NSString stringWithFormat:@"Python 启动失败：%s", status.err_msg ?: "?"];
            if (error) *error = gStartError;
            return NO;
        }

        // 释放 GIL，之后每次调用都在 XHSPythonCall 里重新获取
        PyEval_SaveThread();
        gStarted = YES;
        return YES;
    }
}

NSString *XHSPythonCall(NSString *module, NSString *function, NSString *arg, NSString **error) {
    if (!gStarted) {
        if (error) *error = gStartError ?: @"Python 还没有启动";
        return nil;
    }
    PyGILState_STATE gil = PyGILState_Ensure();
    NSString *result = nil;
    NSString *failure = nil;

    PyObject *mod = PyImport_ImportModule(module.UTF8String);
    if (mod) {
        PyObject *fn = PyObject_GetAttrString(mod, function.UTF8String);
        if (fn) {
            PyObject *ret = arg ? PyObject_CallFunction(fn, "s", arg.UTF8String) : PyObject_CallNoArgs(fn);
            if (ret) {
                const char *c = PyUnicode_Check(ret) ? PyUnicode_AsUTF8(ret) : NULL;
                if (c) {
                    result = [NSString stringWithUTF8String:c];
                } else {
                    failure = PyErr_Occurred() ? CurrentPythonError() : @"Python 函数没有返回字符串";
                }
                Py_DECREF(ret);
            } else {
                failure = CurrentPythonError();
            }
            Py_DECREF(fn);
        } else {
            failure = CurrentPythonError();
        }
        Py_DECREF(mod);
    } else {
        failure = CurrentPythonError();
    }

    PyGILState_Release(gil);
    if (!result && error) *error = failure ?: @"未知错误";
    return result;
}
