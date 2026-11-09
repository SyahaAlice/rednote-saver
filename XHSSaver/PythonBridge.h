#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动内嵌的 Python（只会真正启动一次）。firstPath 会排在模块搜索路径最前面，
/// 用来优先加载 App 里更新过的 yt-dlp（Documents/ytdlp/yt-dlp.zip）。
BOOL XHSPythonStart(NSString * _Nullable firstPath, NSString * _Nullable * _Nullable error);

/// 调用 module.function(arg)，arg 和返回值都是字符串（通常是 JSON）。失败时返回 nil 并写入 error。
NSString * _Nullable XHSPythonCall(NSString *module, NSString *function, NSString * _Nullable arg,
                                   NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
