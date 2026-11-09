#!/usr/bin/env python3
"""生成 XHSSaver.xcodeproj/project.pbxproj（手写工程文件，不依赖 Xcode 或第三方生成器）。

新增 / 删除 XHSSaver/ 里的源文件后运行一次：python tools/gen_project.py
- XHSSaver/*.swift、*.m 自动加入编译
- XHSSaver/<lang>.lproj/InfoPlist.strings 作为本地化资源
- app/（dlcore.py）和 app_packages/（CI 里 pip 安装的 yt-dlp、certifi）作为文件夹资源
- Python.xcframework（CI 里下载）链接并嵌入，另有一个脚本阶段安装 Python 标准库
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "XHSSaver")
NAME = "XHSSaver"

_n = [0]


def oid(prefix):
    _n[0] += 1
    return f"{prefix}{_n[0]:0{24 - len(prefix)}X}"


def q(s):
    """pbxproj 字符串：只含安全字符时不加引号，否则用 JSON 转义（兼容 pbxproj 的 C 风格转义）"""
    if re.fullmatch(r"[A-Za-z0-9_$/.\-]+", s):
        return s
    return json.dumps(s, ensure_ascii=False)


sources = sorted(f for f in os.listdir(SRC) if f.endswith((".swift", ".m")))
headers = sorted(f for f in os.listdir(SRC) if f.endswith(".h"))
lprojs = sorted(d[:-6] for d in os.listdir(SRC) if d.endswith(".lproj")
                and os.path.exists(os.path.join(SRC, d, "InfoPlist.strings")))

INSTALL_PYTHON = r"""set -e
# Unsigned CI build has no signing identity: ad-hoc sign the Python modules; AltServer re-signs everything on install
if [ -z "$EXPANDED_CODE_SIGN_IDENTITY" ]; then export EXPANDED_CODE_SIGN_IDENTITY="-"; fi
export CODESIGNING_FOLDER_PATH="${CODESIGNING_FOLDER_PATH:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"
source "$PROJECT_DIR/Python.xcframework/build/utils.sh"
install_python Python.xcframework app app_packages
STD="$CODESIGNING_FOLDER_PATH/python/lib/python3.13"
rm -rf "$STD/test" "$STD/idlelib" "$STD/tkinter" "$STD/turtledemo" "$STD/ensurepip" "$STD/pydoc_data" "$STD/lib2to3"
"""

objs = {}  # section -> list of (id, comment, body)


def add(section, id_, comment, body):
    objs.setdefault(section, []).append((id_, comment, body))


def fmt_body(d, indent):
    pad = "\t" * indent
    out = "{\n"
    for k, v in d.items():
        if isinstance(v, list):
            items = "".join(f"{pad}\t\t{x},\n" for x in v)
            out += f"{pad}\t{k} = (\n{items}{pad}\t);\n"
        elif isinstance(v, dict):
            out += f"{pad}\t{k} = {fmt_body(v, indent + 1)};\n"
        else:
            out += f"{pad}\t{k} = {v};\n"
    return out + pad + "}"


def ref(id_, comment):
    return f"{id_} /* {comment} */"


# --- 文件引用 ---
file_refs = {}
for f in sources + headers:
    t = {"swift": "sourcecode.swift", "m": "sourcecode.c.objc", "h": "sourcecode.c.h"}[f.rsplit(".", 1)[1]]
    i = oid("A1")
    file_refs[f] = i
    add("PBXFileReference", i, f, {"isa": "PBXFileReference", "lastKnownFileType": t, "path": q(f), "sourceTree": '"<group>"'})
info_ref = oid("A1")
add("PBXFileReference", info_ref, "Info.plist",
    {"isa": "PBXFileReference", "lastKnownFileType": "text.plist.xml", "path": "Info.plist", "sourceTree": '"<group>"'})
app_ref = oid("A1")
add("PBXFileReference", app_ref, f"{NAME}.app",
    {"isa": "PBXFileReference", "explicitFileType": "wrapper.application", "includeInIndex": "0",
     "path": f"{NAME}.app", "sourceTree": "BUILT_PRODUCTS_DIR"})
py_ref = oid("A1")
add("PBXFileReference", py_ref, "Python.xcframework",
    {"isa": "PBXFileReference", "lastKnownFileType": "wrapper.xcframework", "path": "Python.xcframework", "sourceTree": '"<group>"'})
folder_refs = {}
for d in ("app", "app_packages"):
    i = oid("A1")
    folder_refs[d] = i
    add("PBXFileReference", i, d, {"isa": "PBXFileReference", "lastKnownFileType": "folder", "path": d, "sourceTree": '"<group>"'})
lproj_refs = []
for lang in lprojs:
    i = oid("A1")
    lproj_refs.append((i, lang))
    add("PBXFileReference", i, lang, {"isa": "PBXFileReference", "lastKnownFileType": "text.plist.strings",
                                       "name": q(lang), "path": q(f"{lang}.lproj/InfoPlist.strings"), "sourceTree": '"<group>"'})
strings_group = oid("C1")
if lproj_refs:
    add("PBXVariantGroup", strings_group, "InfoPlist.strings",
        {"isa": "PBXVariantGroup", "children": [ref(i, l) for i, l in lproj_refs], "name": "InfoPlist.strings",
         "sourceTree": '"<group>"'})

# --- 编译文件 ---
src_build = []
for f in sources:
    i = oid("B1")
    src_build.append(ref(i, f"{f} in Sources"))
    add("PBXBuildFile", i, f"{f} in Sources", {"isa": "PBXBuildFile", "fileRef": ref(file_refs[f], f)})
res_build = []
if lproj_refs:
    i = oid("B1")
    res_build.append(ref(i, "InfoPlist.strings in Resources"))
    add("PBXBuildFile", i, "InfoPlist.strings in Resources",
        {"isa": "PBXBuildFile", "fileRef": ref(strings_group, "InfoPlist.strings")})
for d, fr in folder_refs.items():
    i = oid("B1")
    res_build.append(ref(i, f"{d} in Resources"))
    add("PBXBuildFile", i, f"{d} in Resources", {"isa": "PBXBuildFile", "fileRef": ref(fr, d)})
link_py = oid("B1")
add("PBXBuildFile", link_py, "Python.xcframework in Frameworks",
    {"isa": "PBXBuildFile", "fileRef": ref(py_ref, "Python.xcframework")})
embed_py = oid("B1")
add("PBXBuildFile", embed_py, "Python.xcframework in Embed Frameworks",
    {"isa": "PBXBuildFile", "fileRef": ref(py_ref, "Python.xcframework"),
     "settings": {"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]}})

# --- 分组 ---
g_main, g_src, g_prod = oid("C1"), oid("C1"), oid("C1")
src_children = [ref(file_refs[f], f) for f in sources + headers] + [ref(info_ref, "Info.plist")]
if lproj_refs:
    src_children.append(ref(strings_group, "InfoPlist.strings"))
add("PBXGroup", g_main, "", {"isa": "PBXGroup", "children": [
    ref(g_src, NAME), ref(folder_refs["app"], "app"), ref(folder_refs["app_packages"], "app_packages"),
    ref(py_ref, "Python.xcframework"), ref(g_prod, "Products")], "sourceTree": '"<group>"'})
add("PBXGroup", g_src, NAME, {"isa": "PBXGroup", "children": src_children, "path": NAME, "sourceTree": '"<group>"'})
add("PBXGroup", g_prod, "Products", {"isa": "PBXGroup", "children": [ref(app_ref, f"{NAME}.app")],
                                      "name": "Products", "sourceTree": '"<group>"'})

# --- 编译阶段 ---
p_src, p_fw, p_res, p_py, p_embed = oid("E1"), oid("E1"), oid("E1"), oid("E1"), oid("E1")
add("PBXSourcesBuildPhase", p_src, "Sources", {"isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647",
                                                "files": src_build, "runOnlyForDeploymentPostprocessing": "0"})
add("PBXFrameworksBuildPhase", p_fw, "Frameworks", {"isa": "PBXFrameworksBuildPhase", "buildActionMask": "2147483647",
                                                     "files": [ref(link_py, "Python.xcframework in Frameworks")],
                                                     "runOnlyForDeploymentPostprocessing": "0"})
add("PBXResourcesBuildPhase", p_res, "Resources", {"isa": "PBXResourcesBuildPhase", "buildActionMask": "2147483647",
                                                    "files": res_build, "runOnlyForDeploymentPostprocessing": "0"})
add("PBXShellScriptBuildPhase", p_py, "Install Python", {
    "isa": "PBXShellScriptBuildPhase", "alwaysOutOfDate": "1", "buildActionMask": "2147483647", "files": [],
    "inputFileListPaths": [], "inputPaths": [], "name": q("Install Python"), "outputFileListPaths": [],
    "outputPaths": [], "runOnlyForDeploymentPostprocessing": "0", "shellPath": "/bin/bash",
    "shellScript": json.dumps(INSTALL_PYTHON)})
add("PBXCopyFilesBuildPhase", p_embed, "Embed Frameworks", {
    "isa": "PBXCopyFilesBuildPhase", "buildActionMask": "2147483647", "dstPath": '""', "dstSubfolderSpec": "10",
    "files": [ref(embed_py, "Python.xcframework in Embed Frameworks")], "name": q("Embed Frameworks"),
    "runOnlyForDeploymentPostprocessing": "0"})

# --- 目标与工程 ---
tgt, proj = oid("D1"), oid("F1")
cl_p, cl_t = oid("91"), oid("91")
c_pd, c_pr, c_td, c_tr = oid("81"), oid("81"), oid("81"), oid("81")
add("PBXNativeTarget", tgt, NAME, {
    "isa": "PBXNativeTarget", "buildConfigurationList": ref(cl_t, f'Build configuration list for PBXNativeTarget "{NAME}"'),
    "buildPhases": [ref(p_src, "Sources"), ref(p_fw, "Frameworks"), ref(p_res, "Resources"),
                    ref(p_py, "Install Python"), ref(p_embed, "Embed Frameworks")],
    "buildRules": [], "dependencies": [], "name": NAME, "productName": NAME,
    "productReference": ref(app_ref, f"{NAME}.app"), "productType": '"com.apple.product-type.application"'})
add("PBXProject", proj, "Project object", {
    "isa": "PBXProject",
    "attributes": {"BuildIndependentTargetsInParallel": "1", "LastSwiftUpdateCheck": "1600", "LastUpgradeCheck": "1600",
                   "TargetAttributes": {tgt: {"CreatedOnToolsVersion": "16.0"}}},
    "buildConfigurationList": ref(cl_p, f'Build configuration list for PBXProject "{NAME}"'),
    "compatibilityVersion": '"Xcode 14.0"', "developmentRegion": '"zh-Hans"', "hasScannedForEncodings": "0",
    "knownRegions": ["en", "Base", '"zh-Hans"'], "mainGroup": g_main, "productRefGroup": ref(g_prod, "Products"),
    "projectDirPath": '""', "projectRoot": '""', "targets": [ref(tgt, NAME)]})

common = {"ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
          "ENABLE_USER_SCRIPT_SANDBOXING": "NO", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos",
          "SWIFT_VERSION": "5.0", "GCC_C_LANGUAGE_STANDARD": "gnu17"}
proj_cfg = {
    "Debug": {**common, "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "ONLY_ACTIVE_ARCH": "YES",
              "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"'},
    "Release": {**common, "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "SWIFT_COMPILATION_MODE": "wholemodule",
                "SWIFT_OPTIMIZATION_LEVEL": '"-O"', "VALIDATE_PRODUCT": "YES"},
}
target_cfg = {
    "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "2", "MARKETING_VERSION": "1.1",
    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_FILE": f"{NAME}/Info.plist",
    # 基础名称必须是英文：AltServer 用它向 Apple 注册 App ID；中文名在 zh-Hans.lproj/InfoPlist.strings
    "INFOPLIST_KEY_CFBundleDisplayName": NAME,
    "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription": q("Save note images, videos and Live Photos to your library"),
    # 相册归类要读取已有相册名，需要「完整照片访问」；缺这一项时申请权限会被系统直接结束 App
    "INFOPLIST_KEY_NSPhotoLibraryUsageDescription": q("Find your existing albums by author to file saved items"),
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
    "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"'],
    "PRODUCT_BUNDLE_IDENTIFIER": "com.personal.xhssaver", "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SWIFT_OBJC_BRIDGING_HEADER": q(f"{NAME}/{NAME}-Bridging-Header.h"),
    "SWIFT_EMIT_LOC_STRINGS": "YES", "TARGETED_DEVICE_FAMILY": "1",
}
for cid, name, cfg in [(c_pd, "Debug", proj_cfg["Debug"]), (c_pr, "Release", proj_cfg["Release"]),
                       (c_td, "Debug", target_cfg), (c_tr, "Release", target_cfg)]:
    add("XCBuildConfiguration", cid, name, {"isa": "XCBuildConfiguration", "buildSettings": cfg, "name": name})
for cl, what, d, r in [(cl_p, f'PBXProject "{NAME}"', c_pd, c_pr), (cl_t, f'PBXNativeTarget "{NAME}"', c_td, c_tr)]:
    add("XCConfigurationList", cl, f"Build configuration list for {what}", {
        "isa": "XCConfigurationList", "buildConfigurations": [ref(d, "Debug"), ref(r, "Release")],
        "defaultConfigurationIsVisible": "0", "defaultConfigurationName": "Release"})

# --- 输出 ---
out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {", ""]
for section in sorted(objs):
    out.append(f"/* Begin {section} section */")
    for id_, comment, body in objs[section]:
        c = f" /* {comment} */" if comment else ""
        if section in ("PBXBuildFile", "PBXFileReference"):
            inner = " ".join(f"{k} = {fmt_body(v, 0) if isinstance(v, dict) else v};" for k, v in body.items())
            inner = inner.replace("\n", " ").replace("\t", "")
            out.append(f"\t\t{id_}{c} = {{{inner} }};")
        else:
            out.append(f"\t\t{id_}{c} = {fmt_body(body, 2)};")
    out.append(f"/* End {section} section */")
    out.append("")
out += ["\t};", f"\trootObject = {ref(proj, 'Project object')};", "}", ""]
path = os.path.join(ROOT, f"{NAME}.xcodeproj", "project.pbxproj")
with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(out))
print("写入", path, "：", len(sources), "个源文件，", len(lprojs), "个本地化")
