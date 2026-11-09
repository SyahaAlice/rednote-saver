import Foundation

/// 出错时给用户看的中文说明
struct XHSError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 笔记里的一个媒体项
struct NoteMedia {
    enum Kind { case image, live, video }
    var kind: Kind
    /// 原图 / 原片地址
    var original: [URL]
    /// 原图 / 原片失败时的替代地址（网页压缩版），使用前要先征得用户同意
    var fallback: [URL]
    /// 实况图的动态视频地址（只有 kind == .live 时有）
    var liveVideoURLs: [URL] = []
}

struct ParsedNote {
    var id: String
    var title: String
    var type: String
    var items: [NoteMedia]
    /// 下载图片/视频时带的 Referer
    var referer: String = "https://www.xiaohongshu.com/"
}

/// 解析逻辑与 phone/dl.py、diag.py 以及 tools/parse_proto.py 一一对应
enum NoteParser {
    /// 跟随短链时用的手机 UA（与 dl.py 相同）
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// 请求笔记页时的请求头，与 yt-dlp 默认请求头一致（dl.py 在手机上就是这样拿到笔记数据的）
    static let pageHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-us,en;q=0.5",
        "Sec-Fetch-Mode": "navigate",
    ]

    static let origImageBase = "https://sns-img-bd.xhscdn.com/"
    static let origVideoBase = "https://sns-video-bd.xhscdn.com/"

    // MARK: - 链接处理

    /// 从分享文案里抠出第一个网址
    static func extractURL(_ text: String) -> URL? {
        guard let r = text.range(of: #"https?://[^\s，。！]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }

    /// 从链接（含 rednote 登录页的 redirectPath）里取出笔记 ID 和 xsec_token
    static func noteRef(_ url: URL) -> (id: String, token: String)? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        if let redirect = comps.queryItems?.first(where: { $0.name == "redirectPath" })?.value,
           let inner = URLComponents(string: redirect) {
            comps = inner
        }
        let path = comps.path
        guard let r = path.range(of: #"/(explore|discovery/item)/[0-9a-f]+"#, options: .regularExpression) else {
            return nil
        }
        let id = String(path[r].split(separator: "/").last ?? "")
        let token = comps.queryItems?.first(where: { $0.name == "xsec_token" })?.value ?? ""
        return id.isEmpty ? nil : (id, token)
    }

    /// 手动一跳一跳地跟短链跳转，在被带去 rednote 登录页之前把笔记 ID 截下来
    static func resolve(_ start: URL) async throws -> (id: String, token: String) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let stopper = NoRedirect()
        var url = start
        for _ in 0..<8 {
            if let ref = noteRef(url) { return ref }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
            let (_, resp) = try await session.data(for: req, delegate: stopper)
            guard let http = resp as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                  let loc = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: loc, relativeTo: url)?.absoluteURL else { break }
            url = next
        }
        throw XHSError("链接里找不到笔记 ID：\(url.absoluteString)")
    }

    static func pageURL(id: String, token: String) -> URL {
        var c = URLComponents(string: "https://www.xiaohongshu.com/discovery/item/\(id)")!
        if !token.isEmpty {
            c.queryItems = [URLQueryItem(name: "xsec_token", value: token),
                            URLQueryItem(name: "xsec_source", value: "app_share")]
        }
        return c.url!
    }

    // MARK: - 解析网页

    static func isXHS(_ url: URL) -> Bool {
        CookiePool.site(of: url.host ?? "") == "xiaohongshu.com"
    }

    /// cookieFile 为 nil 表示游客
    static func parse(url: URL, cookieFile: URL?) async throws -> ParsedNote {
        let ref = try await resolve(url)
        let config = URLSessionConfiguration.ephemeral
        if let cookieFile, let jar = config.httpCookieStorage {
            for c in CookiePool.httpCookies(from: cookieFile) { jar.setCookie(c) }
        }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: pageURL(id: ref.id, token: ref.token), timeoutInterval: 20)
        for (k, v) in pageHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await session.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        return try parse(html: html, noteID: ref.id)
    }

    /// 读出 window.__INITIAL_STATE__ 并转成 JSON（替换 undefined、new Set/Map）
    static func initialState(_ html: String) throws -> [String: Any] {
        guard let start = html.range(of: #"window\.__INITIAL_STATE__\s*=\s*"#, options: .regularExpression),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
            throw XHSError("页面里没有笔记数据（可能被跳到了登录页或验证页）")
        }
        var s = String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(";") { s.removeLast() }
        s = s.replacingOccurrences(of: #"\bundefined\b"#, with: "null", options: .regularExpression)
        s = s.replacingOccurrences(of: #"new (Set|Map)\(\)"#, with: "[]", options: .regularExpression)
        s = s.replacingOccurrences(of: #"new (?:Set|Map)\((\[.*?\])\)"#, with: "$1", options: .regularExpression)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            throw XHSError("笔记数据解析失败")
        }
        return obj
    }

    static func https(_ s: String?) -> URL? {
        guard var s, !s.isEmpty else { return nil }
        if s.hasPrefix("http://") { s = "https://" + String(s.dropFirst("http://".count)) }
        return URL(string: s)
    }

    static func parse(html: String, noteID: String) throws -> ParsedNote {
        let state = try initialState(html)
        let map = (state["note"] as? [String: Any])?["noteDetailMap"] as? [String: Any]
        guard let note = (map?[noteID] as? [String: Any])?["note"] as? [String: Any], !note.isEmpty else {
            throw XHSError("页面里没有这篇笔记的数据（笔记可能已删除、设了权限，或者需要登录）")
        }
        let type = note["type"] as? String ?? ""
        var items: [NoteMedia] = []

        if type == "video" {
            let video = note["video"] as? [String: Any] ?? [:]
            var original: [URL] = []
            if let key = (video["consumer"] as? [String: Any])?["originVideoKey"] as? String, !key.isEmpty,
               let u = URL(string: origVideoBase + key) {
                original.append(u)  // 原片（游客能拿到的 H.264 原视频）
            }
            let streams = ((video["media"] as? [String: Any])?["stream"] as? [String: Any]) ?? [:]
            let all = streams.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
            let h264 = all.filter { ($0["videoCodec"] as? String ?? "").hasPrefix("h264") }
            var fallback: [URL] = []
            for s in (h264.isEmpty ? all : h264) {
                if let u = https(s["masterUrl"] as? String) { fallback.append(u) }
                for b in s["backupUrls"] as? [String] ?? [] { if let u = https(b) { fallback.append(u) } }
            }
            if original.isEmpty && fallback.isEmpty { throw XHSError("没找到视频地址") }
            items.append(NoteMedia(kind: .video, original: original, fallback: fallback))
        } else {
            for img in note["imageList"] as? [[String: Any]] ?? [] {
                var original: [URL] = []
                if let fid = img["fileId"] as? String, !fid.isEmpty, let u = URL(string: origImageBase + fid) {
                    original.append(u)  // 原图（通常是 HEIC）
                }
                let fallback = [https(img["urlDefault"] as? String)].compactMap { $0 }
                var item = NoteMedia(kind: .image, original: original, fallback: fallback)
                if img["livePhoto"] as? Bool == true,
                   let h = ((img["stream"] as? [String: Any])?["h264"] as? [[String: Any]])?.first,
                   let master = https(h["masterUrl"] as? String) {
                    item.kind = .live
                    item.liveVideoURLs = [master] + (h["backupUrls"] as? [String] ?? []).compactMap { https($0) }
                }
                if !(original.isEmpty && fallback.isEmpty) { items.append(item) }
            }
            if items.isEmpty { throw XHSError("这篇笔记里没找到图片") }
        }
        return ParsedNote(id: noteID, title: note["title"] as? String ?? "", type: type, items: items)
    }
}

/// 拦下重定向，让 resolve() 自己读 Location
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
