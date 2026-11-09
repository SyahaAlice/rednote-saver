import CryptoKit
import Foundation

/// 内嵌 Python 上的 yt-dlp 和 gallery-dl（app/dlcore.py）。所有 Python 调用都排在同一个串行队列里。
/// yt-dlp 管视频（选格式、下载）；gallery-dl 管图片和图文混排（只列出内容，由 App 自己下载）。
enum YtDlp {
    private static let queue = DispatchQueue(label: "python", qos: .userInitiated)

    /// App 里更新下来的 yt-dlp（官方发布的单文件版），存在就优先用它
    static var updatedZip: URL {
        CookiePool.documents.appendingPathComponent("ytdlp/yt-dlp.zip")
    }
    static let latestURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp")!

    /// cancelFlag：任务被取消时在这个位置建一个空文件，dlcore 在进度回调和各步骤之间看到它就停下。
    /// Python 调用本身没法从外面打断
    private static func call(_ function: String, _ arg: String?, cancelFlag: URL? = nil) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                queue.async {
                    var err: NSString?
                    guard XHSPythonStart(updatedZip.path, &err) else {
                        c.resume(throwing: XHSError((err as String?) ?? "Python 启动失败"))
                        return
                    }
                    if let r = XHSPythonCall("dlcore", function, arg, &err) {
                        c.resume(returning: r)
                    } else {
                        c.resume(throwing: XHSError("yt-dlp 出错：\((err as String?) ?? "未知错误")"))
                    }
                }
            }
        } onCancel: {
            if let cancelFlag { FileManager.default.createFile(atPath: cancelFlag.path, contents: nil) }
        }
    }

    private static func json(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ s: String) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            throw XHSError("yt-dlp 返回的结果看不懂")
        }
        return o
    }

    struct Version { var ytdlp: String; var python: String; var updated: Bool }

    static func version() async throws -> Version {
        let o = try object(try await call("version", nil))
        return Version(ytdlp: o["yt_dlp"] as? String ?? "?", python: o["python"] as? String ?? "?",
                       updated: (o["source"] as? String ?? "").hasSuffix("yt-dlp.zip"))
    }

    /// 从 yt-dlp 官方 GitHub 下载最新版，替换 App 内置版本，不用重新安装 App
    static func updateToLatest() async throws -> Version {
        var req = URLRequest(url: latestURL, timeoutInterval: 120)
        req.setValue("MediaDownloader", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw XHSError("下载 yt-dlp 失败") }
        let fm = FileManager.default
        try fm.createDirectory(at: updatedZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: updatedZip)
        try fm.moveItem(at: tmp, to: updatedZip)
        return try await reload()
    }

    /// 删除更新版，回到安装包里自带的 yt-dlp
    static func resetToBundled() async throws -> Version {
        try? FileManager.default.removeItem(at: updatedZip)
        return try await reload()
    }

    private static func reload() async throws -> Version {
        _ = try await call("reload", json(["zip": updatedZip.path]))
        return try await version()
    }

    struct Stream { var path: URL; var hasVideo: Bool; var hasAudio: Bool }
    /// 解析结果（还没下载）
    struct Info {
        var id: String
        var title: String
        var extractor: String
        var uploader: String
        var uploaderIDs: [String]
        var handle: String
        var published: Date?
        /// 链接里一共有几项（多图 / 多视频帖子、合集），每一项都会下载
        var entryCount: Int
        /// 项数到了 dlcore 的上限（MAX_ENTRIES），后面可能还有没算进来的
        var more: Bool
        /// 封面图地址（yt-dlp 的 thumbnail）
        var thumbnail: URL?
    }
    /// 下载好的一项：streams 是它的文件（音视频可能分开）；这一项失败时 streams 为空、error 有说明
    struct Fetched { var streams: [Stream]; var error: String? }

    private static func cancelFlag(in dir: URL) -> URL { dir.appendingPathComponent("cancel") }

    /// 把日志文件里从第 shown 行之后的新行交给界面，返回已显示的行数
    private static func drain(_ log: URL, from shown: Int, _ onLog: @MainActor (String) -> Void) async -> Int {
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // dlcore 每行都以换行结尾，所以最后一段要么是空的，要么是还没写完的半行，留到下次
        let complete = lines.count - 1
        guard complete > shown else { return shown }
        for l in lines[shown..<complete] where !l.isEmpty { await onLog(l) }
        return complete
    }

    /// 调一次 dlcore；期间每半秒读一次日志，把新行交给界面，结束后把剩下的行也交出去
    private static func logged(_ function: String, _ args: [String: Any], dir: URL, log: URL,
                               onLog: @escaping @MainActor (String) -> Void) async throws -> [String: Any] {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let watcher = Task { () -> Int in
            var shown = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                shown = await drain(log, from: shown, onLog)
            }
            return shown
        }
        let outcome: Swift.Result<String, Error>
        do {
            outcome = .success(try await call(function, json(args), cancelFlag: cancelFlag(in: dir)))
        } catch {
            outcome = .failure(error)
        }
        watcher.cancel()
        _ = await drain(log, from: await watcher.value, onLog)
        let o = try object(try outcome.get())
        if o["unsupported"] as? Bool == true { return o }  // 不是出错：这个网址这个提取器不管，交还给调用方
        guard o["ok"] as? Bool == true else {
            let message = o["error"] as? String ?? "未知错误"
            if o["cancelled"] as? Bool == true { throw XHSError.cancelled }
            throw XHSError("下载失败：\(message)")
        }
        return o
    }

    /// 第一步：只解析链接（标题、作者、作品 ID），不下载；onLog 会收到 yt-dlp 的进度文字
    /// maxHeight 是清晰度上限（画面高度），0 = 不限
    static func probe(url: URL, into dir: URL, cookies: [URL?], maxHeight: Int = 0,
                      onLog: @escaping @MainActor (String) -> Void) async throws -> Info {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-dlp").path
        // 每次调用用自己的日志文件：同一个作品可能解析两次（换清晰度重试），不能把上一次的日志再显示一遍
        let log = dir.appendingPathComponent("probe-\(UUID().uuidString.prefix(8)).log")
        let o = try await logged("probe", [
            "url": url.absoluteString,
            "out_dir": dir.path,
            "cookies": cookies.map { (c: URL?) -> Any in c.map { $0.path as Any } ?? NSNull() },
            "log": log.path,
            "cache_dir": cache,
            "cancel": cancelFlag(in: dir).path,
            "max_height": maxHeight,
            "max_entries": Prefs.maxEntries,
        ], dir: dir, log: log, onLog: onLog)

        var published = (o["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        if published == nil, let d = o["upload_date"] as? String, d.count == 8 {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            published = f.date(from: d)
        }
        return Info(id: o["id"] as? String ?? UUID().uuidString, title: o["title"] as? String ?? "",
                    extractor: o["extractor"] as? String ?? "", uploader: o["uploader"] as? String ?? "",
                    uploaderIDs: o["uploader_ids"] as? [String] ?? [], handle: o["handle"] as? String ?? "",
                    published: published, entryCount: o["entries"] as? Int ?? 1,
                    more: o["more"] as? Bool ?? false, thumbnail: JSONTree.url(o["thumbnail"]))
    }

    /// 第二步：下载 probe 解析好的内容（dir 要和 probe 时相同），链接里的每一项都下载；
    /// limit 不为 nil 时只下载前几项。返回的数组和链接里的项一一对应，失败的项带 error
    static func fetch(into dir: URL, limit: Int? = nil,
                      onLog: @escaping @MainActor (String) -> Void) async throws -> [Fetched] {
        let log = dir.appendingPathComponent("fetch-\(UUID().uuidString.prefix(8)).log")
        var args: [String: Any] = ["log": log.path, "cancel": cancelFlag(in: dir).path]
        if let limit { args["limit"] = limit }
        let o = try await logged("fetch", args, dir: dir, log: log, onLog: onLog)
        let items = (o["items"] as? [[String: Any]] ?? []).map { item -> Fetched in
            let streams = (item["streams"] as? [[String: Any]] ?? []).compactMap { s -> Stream? in
                guard let p = s["path"] as? String else { return nil }
                return Stream(path: URL(fileURLWithPath: p),
                              hasVideo: (s["vcodec"] as? String ?? "none") != "none",
                              hasAudio: (s["acodec"] as? String ?? "none") != "none")
            }
            let error = item["error"] as? String
            return Fetched(streams: streams, error: streams.isEmpty ? (error ?? "没有得到文件") : nil)
        }
        if items.isEmpty { throw XHSError("下载失败：没有得到文件") }
        return items
    }

    // MARK: - gallery-dl：列出帖子里的全部图片和视频（图文混排）

    /// App 里更新下来的 gallery-dl（PyPI 上的 wheel，本身就是 zip），存在就优先用它
    static var galleryZip: URL {
        CookiePool.documents.appendingPathComponent("ytdlp/gallery-dl.zip")
    }
    static let galleryIndexURL = URL(string: "https://pypi.org/pypi/gallery-dl/json")!

    struct GalleryItem {
        /// image / video / live
        var kind: String
        var url: URL
        /// 实况图的动态视频（kind == live 时有）
        var live: URL?
        /// 备用地址（较小的尺寸），用之前要先问用户
        var fallback: [URL]
        /// gallery-dl 自己不直接下载、要交给 yt-dlp 的分段视频
        var needsYtDlp: Bool
    }
    struct Gallery {
        var info: Info
        var items: [GalleryItem]
        /// 下载这些文件时带的 Referer
        var referer: String
    }

    /// 用 gallery-dl 列出链接里的全部内容（不下载）。返回 nil = 这个网址 gallery-dl 不支持
    static func gallery(url: URL, into dir: URL, cookies: [URL?],
                        onLog: @escaping @MainActor (String) -> Void) async throws -> Gallery? {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gallery-dl")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("gallery-\(UUID().uuidString.prefix(8)).log")
        let o = try await logged("gallery", [
            "url": url.absoluteString,
            "cookies": cookies.map { (c: URL?) -> Any in c.map { $0.path as Any } ?? NSNull() },
            "log": log.path,
            "cache_dir": cache.path,
            "cancel": cancelFlag(in: dir).path,
            "gdl_zip": galleryZip.path,
            "max_entries": Prefs.maxEntries,
        ], dir: dir, log: log, onLog: onLog)
        if o["unsupported"] as? Bool == true { return nil }

        let items = (o["items"] as? [[String: Any]] ?? []).compactMap { d -> GalleryItem? in
            guard let u = JSONTree.url(d["url"]) else { return nil }
            return GalleryItem(kind: d["kind"] as? String ?? "image", url: u, live: JSONTree.url(d["live"]),
                               fallback: (d["fallback"] as? [String] ?? []).compactMap { JSONTree.url($0) },
                               needsYtDlp: d["ytdl"] as? Bool ?? false)
        }
        let info = Info(id: o["id"] as? String ?? url.absoluteString, title: o["title"] as? String ?? "",
                        extractor: o["extractor"] as? String ?? "", uploader: o["uploader"] as? String ?? "",
                        uploaderIDs: o["uploader_ids"] as? [String] ?? [], handle: o["handle"] as? String ?? "",
                        published: (o["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) },
                        entryCount: items.count, more: o["more"] as? Bool ?? false, thumbnail: nil)
        return Gallery(info: info, items: items, referer: o["referer"] as? String ?? "")
    }

    struct GalleryVersion { var version: String; var updated: Bool }

    static func galleryVersion() async throws -> GalleryVersion {
        let o = try object(try await call("gdl_version", json(["gdl_zip": galleryZip.path])))
        return GalleryVersion(version: o["gallery_dl"] as? String ?? "?",
                              updated: (o["source"] as? String ?? "").hasSuffix("gallery-dl.zip"))
    }

    private static func reloadGallery() async throws -> GalleryVersion {
        _ = try await call("gdl_reload", json(["gdl_zip": galleryZip.path]))
        return try await galleryVersion()
    }

    /// 从 PyPI（Python 官方软件源）下载最新版 gallery-dl 替换内置版本，不用重新安装 App。
    /// 下载后按软件源给出的 SHA-256 校验，对不上就不替换
    static func updateGalleryToLatest() async throws -> GalleryVersion {
        var req = URLRequest(url: galleryIndexURL, timeoutInterval: 30)
        req.setValue("MediaDownloader", forHTTPHeaderField: "User-Agent")
        let (indexData, indexResp) = try await URLSession.shared.data(for: req)
        guard (indexResp as? HTTPURLResponse)?.statusCode == 200,
              let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let files = index["urls"] as? [[String: Any]],
              let wheel = files.first(where: { ($0["packagetype"] as? String) == "bdist_wheel" }),
              let wheelURL = JSONTree.url(wheel["url"]),
              let expected = (wheel["digests"] as? [String: Any])?["sha256"] as? String else {
            throw XHSError("读取 gallery-dl 的版本信息失败")
        }
        var download = URLRequest(url: wheelURL, timeoutInterval: 120)
        download.setValue("MediaDownloader", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: download)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw XHSError("下载 gallery-dl 失败") }
        let digest = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else { throw XHSError("下载到的 gallery-dl 校验不通过，没有替换") }
        let fm = FileManager.default
        try fm.createDirectory(at: galleryZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: galleryZip)
        try fm.copyItem(at: tmp, to: galleryZip)
        return try await reloadGallery()
    }

    /// 删除更新版，回到安装包里自带的 gallery-dl
    static func resetGalleryToBundled() async throws -> GalleryVersion {
        try? FileManager.default.removeItem(at: galleryZip)
        return try await reloadGallery()
    }
}
