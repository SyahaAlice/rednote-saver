import Foundation

/// 快手：图集（多张图片）、单图和视频。
/// 数据在哪里、叫什么名字，参考的是开源项目 KS-Downloader（JoeanAmier，GPL-3.0）的做法，这里按同样的字段重新实现：
/// - 分享短链打开后有两种网页：手机分享页（…/fw/photo/作品ID）把作品数据写在 window.INIT_STATE 里，
///   电脑版（www.kuaishou.com/short-video/作品ID）写在 window.__APOLLO_STATE__ 里；
/// - 图集的图片地址 = "https://" + ext_params.atlas.cdn[0] + ext_params.atlas.list[i]；
/// - 单图作品（ext_params.single）的图片就是封面 coverUrls[0].url。
/// 和 KS-Downloader 不同的是：这里不伪装浏览器。App 先像游客一样直接请求网页；
/// 拿不到数据（比如要验证）时，改用「设置 → 账号」里的快手账号在内置浏览器里打开，由用户自己完成验证。
enum Kuaishou {
    /// 单个作品的链接：v.kuaishou.com 短链、…/f/… 短链、…/short-video/…、…/fw/photo/…
    static func isPost(_ url: URL) -> Bool {
        guard CookiePool.site(of: url.host ?? "") == "kuaishou.com" else { return false }
        let host = (url.host ?? "").lowercased()
        let path = url.path
        return host.hasPrefix("v.") || path.hasPrefix("/f/")
            || path.contains("/short-video/") || path.contains("/fw/photo/")
    }

    /// 作品 ID：网址参数里的 photoId，或路径最后一段
    static func photoID(_ url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let v = comps?.queryItems?.first(where: { $0.name == "photoId" })?.value, !v.isEmpty { return v }
        if url.path.contains("/short-video/") || url.path.contains("/fw/photo/") { return url.lastPathComponent }
        return ""
    }

    // MARK: - 读网页

    /// 像游客（或带号池里某个账号的 cookie）一样请求作品网页，跟着短链跳转。返回网页内容和最终网址
    static func fetchPage(_ url: URL, cookieFile: URL?) async throws -> (html: String, url: URL) {
        let config = URLSessionConfiguration.ephemeral
        if let cookieFile, let jar = config.httpCookieStorage {
            for c in CookiePool.httpCookies(from: cookieFile) { jar.setCookie(c) }
        }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(NoteParser.mobileUA, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        return (String(decoding: data, as: UTF8.self), resp.url ?? url)
    }

    /// 从一段文字里取出 marker 后面第一个完整的 {…}（按括号配对，跳过字符串里的括号）
    static func firstObject(in text: String, after marker: String) -> String? {
        guard let m = text.range(of: marker) else { return nil }
        let bytes = Array(text[m.upperBound...].utf8)
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<bytes.count {
            let b = bytes[i]
            if inString {
                if escaped {
                    escaped = false
                } else if b == UInt8(ascii: "\\") {
                    escaped = true
                } else if b == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if b == UInt8(ascii: "\"") {
                inString = true
            } else if b == UInt8(ascii: "{") {
                depth += 1
            } else if b == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return String(decoding: bytes[start...i], as: UTF8.self) }
            }
        }
        return nil
    }

    private static func json(_ text: String?) -> Any? {
        guard let text else { return nil }
        if let v = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { return v }
        // 网页里的写法不一定是严格的 JSON：把 undefined 换成 null 再试一次
        let fixed = text.replacingOccurrences(of: #"\bundefined\b"#, with: "null", options: .regularExpression)
        return try? JSONSerialization.jsonObject(with: Data(fixed.utf8))
    }

    /// 网页（或网页里一段脚本）里写着的作品数据；没有就返回 nil
    static func pageState(_ text: String) -> Any? {
        for marker in ["window.INIT_STATE", "window.__APOLLO_STATE__"] {
            if let v = json(firstObject(in: text, after: marker)) { return v }
        }
        // 整块读不出来时，只取作品那一段（KS-Downloader 也是这么做的）
        if text.contains("INIT_STATE"), let v = json(firstObject(in: text, after: "\"photo\":")) { return v }
        return nil
    }

    // MARK: - 解析

    private static func truthy(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return !s.isEmpty }
        return true
    }

    /// 图集：每张图在每个 CDN 上各有一个地址，第一个不行时 Downloader 会接着试后面的
    private static func atlasImages(in value: Any) -> [NoteMedia] {
        guard let atlas = JSONTree.first(in: value, where: { d in
            !((d["cdn"] as? [String]) ?? []).isEmpty && !((d["list"] as? [String]) ?? []).isEmpty
        }) else { return [] }
        let cdns = atlas["cdn"] as? [String] ?? []
        let list = atlas["list"] as? [String] ?? []
        return list.compactMap { path -> NoteMedia? in
            let urls = cdns.compactMap { URL(string: "https://\($0)\(path)") }
            return urls.isEmpty ? nil : NoteMedia(kind: .image, original: urls, fallback: [])
        }
    }

    /// 视频的各个清晰度，最高的在前；同样大小时 H.264 在前（兼容性最好）
    private static func videoURLs(_ photo: [String: Any]) -> [URL] {
        var reps: [(url: URL, area: Int, bitrate: Int, h264: Bool)] = []
        if let resource = photo["videoResource"] as? [String: Any] {
            for (codec, body) in resource {
                let sets = (body as? [String: Any])?["adaptationSet"] as? [[String: Any]] ?? []
                for r in sets.flatMap({ $0["representation"] as? [[String: Any]] ?? [] }) {
                    guard let u = JSONTree.url(r["url"]) else { continue }
                    reps.append((u, (r["width"] as? Int ?? 0) * (r["height"] as? Int ?? 0),
                                 r["maxBitrate"] as? Int ?? r["avgBitrate"] as? Int ?? 0, codec.lowercased() == "h264"))
                }
            }
        }
        reps.sort { a, b in
            if a.area != b.area { return a.area > b.area }
            if a.h264 != b.h264 { return a.h264 }
            return a.bitrate > b.bitrate
        }
        var out = reps.map { $0.url }
        func add(_ v: Any?) {
            if let u = JSONTree.url(v), !out.contains(u) { out.append(u) }
        }
        add(photo["photoUrl"])
        for m in photo["mainMvUrls"] as? [[String: Any]] ?? [] { add(m["url"]) }
        return out
    }

    /// state 是网页里的整块数据，pageURL 是网页的最终网址（用来对上作品 ID）
    static func parse(_ state: Any, pageURL: URL) throws -> ParsedNote {
        let id = photoID(pageURL)
        // 作品本身：先按 ID 找，找不到就找第一个带说明文字的
        var found: [String: Any]?
        if !id.isEmpty {
            found = JSONTree.first(in: state, where: { d in
                d["caption"] != nil && (JSONTree.string(d["id"]) == id || JSONTree.string(d["photoId"]) == id)
            })
        }
        if found == nil {
            found = JSONTree.first(in: state, where: { d in
                let hasMedia = d["userName"] != nil || d["photoUrl"] != nil || d["coverUrls"] != nil
                    || d["coverUrl"] != nil
                return d["caption"] != nil && hasMedia
            })
        }
        let photo = found ?? [:]

        var items = atlasImages(in: photo)
        if items.isEmpty { items = atlasImages(in: state) }
        if items.isEmpty, truthy((photo["ext_params"] as? [String: Any])?["single"]) {
            // 单图作品：图片就是封面
            let covers = (photo["coverUrls"] as? [[String: Any]] ?? []).compactMap { JSONTree.url($0["url"]) }
            if !covers.isEmpty { items = [NoteMedia(kind: .image, original: covers, fallback: [])] }
        }
        if items.isEmpty {
            let videos = videoURLs(photo)
            if let best = videos.first {
                items = [NoteMedia(kind: .video, original: [best], fallback: Array(videos.dropFirst().prefix(2)))]
            }
        }
        if items.isEmpty { throw XHSError("这个快手作品里没找到图片或视频") }

        // 作者：手机分享页写在作品里（userName / userEid / kwaiId），电脑版单独一条（带头像地址）
        var name = JSONTree.string(photo["userName"])
        var candidates = [JSONTree.string(photo["kwaiId"]), JSONTree.string(photo["userEid"]),
                          JSONTree.string(photo["userId"])]
        if name.isEmpty, let a = JSONTree.first(in: state, where: { d in
            d["name"] != nil && d["id"] != nil && d["headerUrl"] != nil
        }) {
            name = JSONTree.string(a["name"])
            candidates.append(JSONTree.string(a["id"]))
        }
        var ids: [String] = []
        for i in candidates where !i.isEmpty && !ids.contains(i) { ids.append(i) }
        let author: Author? = ids.isEmpty && name.isEmpty ? nil
            : Author(name: name, primaryID: ids.first ?? "", ids: ids, idLabel: "快手号")

        let published = (photo["timestamp"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        let noteID = id.isEmpty ? JSONTree.string(photo["photoId"]) : id
        return ParsedNote(platform: "快手", id: noteID.isEmpty ? JSONTree.string(photo["id"]) : noteID,
                          title: photo["caption"] as? String ?? "", items: items, author: author,
                          published: published, referer: "https://www.kuaishou.com/")
    }

    /// 直接请求拿不到数据时，用登录账号在内置浏览器里打开（见 WebCapture.swift）
    @MainActor
    static func capture(account: WebAccount, start: URL) -> WebCapture {
        WebCapture(account: account, start: start, spec: WebCaptureSpec(
            title: "快手",
            keywords: ["INIT_STATE", "__APOLLO_STATE__"],
            apiHints: [],
            inlineMarkers: ["window.INIT_STATE", "window.__APOLLO_STATE__"],
            unwrap: { text in
                firstObject(in: text, after: "window.INIT_STATE") ?? firstObject(in: text, after: "window.__APOLLO_STATE__")
            },
            match: { _, value in
                // 整块交回去，由 parse 按网址里的作品 ID 去找；这里只确认里面确实有作品
                guard let d = value as? [String: Any],
                      JSONTree.first(in: d, where: { $0["caption"] != nil }) != nil else { return nil }
                return d
            }))
    }
}
