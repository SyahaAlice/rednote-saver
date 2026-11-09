import Foundation

/// X（Twitter）：yt-dlp 只能取视频，图片推文存不了。
/// yt-dlp 拿不到内容时，用「设置 → 账号」里登录过的 X 账号在内置浏览器里打开推文，
/// 复制一份网页自己拿到的推文数据（见 WebCapture.swift）。图片取原图（name=orig），视频取最高码率。
enum XPost {
    static func isPost(_ url: URL) -> Bool {
        // t.co 短链打开后才知道是不是推文，也交给这里（yt-dlp 先试）
        CookiePool.site(of: url.host ?? "") == "x.com"
            && (tweetID(path: url.path) != nil || (url.host ?? "").lowercased().hasSuffix("t.co"))
    }

    /// 网址路径里的推文 ID：/用户名/status/123…、/i/status/123…
    static func tweetID(path: String) -> String? {
        guard let r = path.range(of: #"/status(es)?/[0-9]+"#, options: .regularExpression) else { return nil }
        return path[r].split(separator: "/").last.map(String.init)
    }

    /// 在网页给的数据里找出这条推文：rest_id 对得上，而且带 legacy（推文正文和媒体都在里面）
    static func find(in value: Any, id: String) -> [String: Any]? {
        JSONTree.first(in: value) { d in
            JSONTree.string(d["rest_id"]) == id && d["legacy"] is [String: Any]
        }
    }

    /// 图片原图：https://pbs.twimg.com/media/XXXX.jpg → https://pbs.twimg.com/media/XXXX?format=jpg&name=orig
    static func originalImage(_ s: String) -> URL? {
        guard let u = URL(string: s), var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        let ext = u.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        c.path = (c.path as NSString).deletingPathExtension
        c.queryItems = [URLQueryItem(name: "format", value: ext), URLQueryItem(name: "name", value: "orig")]
        return c.url
    }

    private static func media(_ m: [String: Any]) -> NoteMedia? {
        let type = m["type"] as? String ?? ""
        if type == "video" || type == "animated_gif" {
            // 只要 mp4（m3u8 是分段流，不能直接保存），码率最高的在前
            let variants = ((m["video_info"] as? [String: Any])?["variants"] as? [[String: Any]] ?? [])
                .filter { ($0["content_type"] as? String ?? "") == "video/mp4" }
                .sorted { ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0) }
                .compactMap { JSONTree.url($0["url"]) }
            guard let best = variants.first else { return nil }
            var item = NoteMedia(kind: .video, original: [best], fallback: Array(variants.dropFirst().prefix(2)))
            item.preview = JSONTree.url(m["media_url_https"])  // 视频的封面
            return item
        }
        guard let s = m["media_url_https"] as? String, let plain = URL(string: s) else { return nil }
        if let orig = originalImage(s) {
            var item = NoteMedia(kind: .image, original: [orig], fallback: [plain])
            item.preview = URL(string: s + "?name=small")
            return item
        }
        return NoteMedia(kind: .image, original: [plain], fallback: [])
    }

    static func parse(tweet t: [String: Any]) throws -> ParsedNote {
        let legacy = t["legacy"] as? [String: Any] ?? [:]
        let id = JSONTree.string(t["rest_id"])
        let list = ((legacy["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]])
            ?? ((legacy["entities"] as? [String: Any])?["media"] as? [[String: Any]]) ?? []
        let items = list.compactMap { media($0) }
        if items.isEmpty { throw XHSError("这条推文里没找到图片或视频") }

        var author: Author?
        if let user = ((t["core"] as? [String: Any])?["user_results"] as? [String: Any])?["result"] as? [String: Any] {
            // 用户名和昵称在 legacy 里，较新的数据在 core 里
            let ul = user["legacy"] as? [String: Any] ?? [:]
            let uc = user["core"] as? [String: Any] ?? [:]
            let handle = JSONTree.string(ul["screen_name"]).isEmpty
                ? JSONTree.string(uc["screen_name"]) : JSONTree.string(ul["screen_name"])
            let name = JSONTree.string(ul["name"]).isEmpty ? JSONTree.string(uc["name"]) : JSONTree.string(ul["name"])
            var ids: [String] = []
            for i in [handle, JSONTree.string(user["rest_id"])] where !i.isEmpty && !ids.contains(i) { ids.append(i) }
            if !ids.isEmpty {
                author = Author(name: name.isEmpty ? handle : name, primaryID: handle.isEmpty ? ids[0] : handle,
                                ids: ids, idLabel: "用户名")
            }
        }
        return ParsedNote(platform: "X", id: id, title: legacy["full_text"] as? String ?? "", items: items,
                          author: author, published: JSONTree.postDate(legacy["created_at"]),
                          referer: "https://x.com/")
    }

    @MainActor
    static func capture(account: WebAccount, start: URL) -> WebCapture {
        WebCapture(account: account, start: start, spec: WebCaptureSpec(
            title: "X",
            keywords: ["extended_entities", "media_url_https"],
            apiHints: ["/graphql/"],
            match: { path, value in
                guard let id = tweetID(path: path) else { return nil }
                return find(in: value, id: id)
            }))
    }
}
