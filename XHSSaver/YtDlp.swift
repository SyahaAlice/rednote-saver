import Foundation

/// 内嵌 Python 上的 yt-dlp（app/dlcore.py）。所有 Python 调用都排在同一个串行队列里。
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
        guard o["ok"] as? Bool == true else {
            let message = o["error"] as? String ?? "未知错误"
            throw XHSError(message == "已取消" ? message : "下载失败：\(message)")
        }
        return o
    }

    /// 第一步：只解析链接（标题、作者、作品 ID），不下载；onLog 会收到 yt-dlp 的进度文字
    static func probe(url: URL, into dir: URL, cookies: [URL?],
                      onLog: @escaping @MainActor (String) -> Void) async throws -> Info {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-dlp").path
        let o = try await logged("probe", [
            "url": url.absoluteString,
            "out_dir": dir.path,
            "cookies": cookies.map { (c: URL?) -> Any in c.map { $0.path as Any } ?? NSNull() },
            "log": dir.appendingPathComponent("probe.log").path,
            "cache_dir": cache,
            "cancel": cancelFlag(in: dir).path,
        ], dir: dir, log: dir.appendingPathComponent("probe.log"), onLog: onLog)

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
                    more: o["more"] as? Bool ?? false)
    }

    /// 第二步：下载 probe 解析好的内容（dir 要和 probe 时相同），链接里的每一项都下载；
    /// limit 不为 nil 时只下载前几项。返回的数组和链接里的项一一对应，失败的项带 error
    static func fetch(into dir: URL, limit: Int? = nil,
                      onLog: @escaping @MainActor (String) -> Void) async throws -> [Fetched] {
        let log = dir.appendingPathComponent("fetch.log")
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
}
