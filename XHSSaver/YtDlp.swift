import Foundation

/// 内嵌 Python 上的 yt-dlp（app/dlcore.py）。所有 Python 调用都排在同一个串行队列里。
enum YtDlp {
    private static let queue = DispatchQueue(label: "python", qos: .userInitiated)

    /// App 里更新下来的 yt-dlp（官方发布的单文件版），存在就优先用它
    static var updatedZip: URL {
        CookiePool.documents.appendingPathComponent("ytdlp/yt-dlp.zip")
    }
    static let latestURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp")!

    private static func call(_ function: String, _ arg: String?) async throws -> String {
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
        req.setValue("XHSSaver", forHTTPHeaderField: "User-Agent")
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
    struct Result {
        var id: String
        var title: String
        var extractor: String
        var uploader: String
        var uploaderIDs: [String]
        var handle: String
        var published: Date?
        var streams: [Stream]
    }

    /// 下载一个链接；onLog 会收到 yt-dlp 的进度文字
    static func download(url: URL, into dir: URL, cookies: [URL?],
                         onLog: @escaping @MainActor (String) -> Void) async throws -> Result {
        let log = dir.appendingPathComponent("ytdlp.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-dlp").path
        let args = json([
            "url": url.absoluteString,
            "out_dir": dir.path,
            "cookies": cookies.map { (c: URL?) -> Any in c.map { $0.path as Any } ?? NSNull() },
            "log": log.path,
            "cache_dir": cache,
        ])

        // 下载期间每半秒读一次日志，把新行交给界面
        let watcher = Task {
            var shown = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                    .split(separator: "\n").map(String.init)
                if lines.count > shown {
                    for l in lines[shown...] where !l.isEmpty { await onLog(l) }
                    shown = lines.count
                }
            }
        }
        defer { watcher.cancel() }

        let o = try object(try await call("download", args))
        guard o["ok"] as? Bool == true else {
            throw XHSError("下载失败：\(o["error"] as? String ?? "未知错误")")
        }
        let streams = (o["streams"] as? [[String: Any]] ?? []).compactMap { s -> Stream? in
            guard let p = s["path"] as? String else { return nil }
            return Stream(path: URL(fileURLWithPath: p),
                          hasVideo: (s["vcodec"] as? String ?? "none") != "none",
                          hasAudio: (s["acodec"] as? String ?? "none") != "none")
        }
        if streams.isEmpty { throw XHSError("下载失败：没有得到文件") }
        var published = (o["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        if published == nil, let d = o["upload_date"] as? String, d.count == 8 {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            published = f.date(from: d)
        }
        return Result(id: o["id"] as? String ?? UUID().uuidString, title: o["title"] as? String ?? "",
                      extractor: o["extractor"] as? String ?? "", uploader: o["uploader"] as? String ?? "",
                      uploaderIDs: o["uploader_ids"] as? [String] ?? [], handle: o["handle"] as? String ?? "",
                      published: published, streams: streams)
    }
}
