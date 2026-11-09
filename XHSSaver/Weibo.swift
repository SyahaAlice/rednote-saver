import Foundation

/// 微博：yt-dlp 只能取视频，图片微博存不了。
/// yt-dlp 拿不到内容时，用「设置 → 账号」里登录过的微博账号在内置浏览器里打开这条微博，
/// 复制一份网页自己拿到的微博数据（见 WebCapture.swift）。图片取最大尺寸，实况图存成实况照片，视频取最高清晰度。
///
/// 微博数据有两种写法，两种都认：
/// 电脑版（weibo.com 的接口）：mblogid / idstr、pic_ids + pic_infos、mix_media_info、page_info.media_info
/// 手机版（m.weibo.cn 写在网页里的 $render_data）：bid / id、pics、page_info.urls
enum Weibo {
    /// 单条微博的链接：weibo.com/用户ID/微博代码、…/status/…、…/detail/…，以及 t.cn 短链
    static func isPost(_ url: URL) -> Bool {
        guard CookiePool.site(of: url.host ?? "") == "weibo.com" else { return false }
        if (url.host ?? "").lowercased().hasSuffix("t.cn") { return true }
        return url.path.range(of: #"^/[0-9]+/[A-Za-z0-9]{6,}|/(status|detail)/[A-Za-z0-9]+"#,
                              options: .regularExpression) != nil
    }

    /// 这条微博所有可以用来对上网址的 ID
    private static func ids(_ s: [String: Any]) -> [String] {
        ["mblogid", "bid", "idstr", "mid", "id"].map { JSONTree.string(s[$0]) }.filter { !$0.isEmpty }
    }

    /// 在网页给的数据里找出网址指向的那条微博：有作者，而且某个 ID 出现在网页路径里
    static func find(in value: Any, path: String) -> [String: Any]? {
        let parts = Set(path.split(separator: "/").map(String.init))
        return JSONTree.first(in: value) { d in
            d["user"] is [String: Any] && ids(d).contains { parts.contains($0) }
        }
    }

    // MARK: - 媒体

    /// 一张图的各个尺寸，最大的在前
    private static func imageURLs(_ info: [String: Any]) -> [URL] {
        var out: [URL] = []
        for key in ["largest", "original", "mw2000", "large", "bmiddle"] {
            if let u = JSONTree.url((info[key] as? [String: Any])?["url"]), !out.contains(u) { out.append(u) }
        }
        if out.isEmpty, let u = JSONTree.url(info["url"]) { out.append(u) }
        return out
    }

    private static func picture(_ info: [String: Any]) -> NoteMedia? {
        let urls = imageURLs(info)
        guard let best = urls.first else { return nil }
        var item = NoteMedia(kind: .image, original: [best], fallback: Array(urls.dropFirst().prefix(1)))
        item.preview = urls.last  // 预览用最小的那一档
        // 实况图：电脑版的动态视频在 video，手机版在 videoSrc
        if let clip = JSONTree.url(info["video"]) ?? JSONTree.url(info["videoSrc"]) {
            item.kind = .live
            item.liveVideoURLs = [clip]
        }
        return item
    }

    /// 视频的各个清晰度，最高的在前
    private static func videoURLs(_ page: [String: Any]) -> [URL] {
        var out: [URL] = []
        func add(_ v: Any?) {
            if let u = JSONTree.url(v), !out.contains(u) { out.append(u) }
        }
        let media = page["media_info"] as? [String: Any] ?? [:]
        // 电脑版：playback_list 里每一档带宽高和码率
        let list = (media["playback_list"] as? [[String: Any]] ?? []).compactMap { $0["play_info"] as? [String: Any] }
        func area(_ d: [String: Any]) -> Int { (d["width"] as? Int ?? 0) * (d["height"] as? Int ?? 0) }
        for p in list.sorted(by: {
            let (a, b) = (area($0), area($1))
            return a != b ? a > b : ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0)
        }) {
            add(p["url"])
        }
        let order = ["mp4_1080p_mp4", "mp4_720p_mp4", "mp4_hd_mp4", "mp4_hd_url", "stream_url_hd",
                     "mp4_sd_url", "mp4_ld_mp4", "stream_url"]
        let urls = page["urls"] as? [String: Any] ?? [:]  // 手机版
        for key in order {
            add(urls[key])
            add(media[key])
        }
        return out
    }

    private static func video(_ page: [String: Any]) -> NoteMedia? {
        let urls = videoURLs(page)
        guard let best = urls.first else { return nil }
        return NoteMedia(kind: .video, original: [best], fallback: Array(urls.dropFirst().prefix(2)))
    }

    private static func items(_ s: [String: Any]) -> [NoteMedia] {
        // 图片和视频混排
        if let mix = (s["mix_media_info"] as? [String: Any])?["items"] as? [[String: Any]], !mix.isEmpty {
            let out = mix.compactMap { m -> NoteMedia? in
                guard let data = m["data"] as? [String: Any] else { return nil }
                return (m["type"] as? String) == "video" ? video(data) : picture(data)
            }
            if !out.isEmpty { return out }
        }
        var out: [NoteMedia] = []
        if let infos = s["pic_infos"] as? [String: Any] {  // 电脑版，pic_ids 是显示顺序
            let order = (s["pic_ids"] as? [String]) ?? infos.keys.sorted()
            out = order.compactMap { (infos[$0] as? [String: Any]).flatMap { picture($0) } }
        } else if let pics = s["pics"] as? [[String: Any]] {  // 手机版
            out = pics.compactMap { picture($0) }
        }
        if out.isEmpty, let page = s["page_info"] as? [String: Any], let v = video(page) { out = [v] }
        return out
    }

    static func parse(status outer: [String: Any]) throws -> ParsedNote {
        var s = outer
        var media = items(s)
        // 转发的微博自己没有图片视频：存被转发的那一条，作者也按原作者算
        if media.isEmpty, let original = outer["retweeted_status"] as? [String: Any] {
            s = original
            media = items(s)
        }
        if media.isEmpty { throw XHSError("这条微博里没找到图片或视频") }

        var author: Author?
        if let u = s["user"] as? [String: Any] {
            let uid = JSONTree.string(u["idstr"]).isEmpty ? JSONTree.string(u["id"]) : JSONTree.string(u["idstr"])
            let name = JSONTree.string(u["screen_name"])
            if !uid.isEmpty || !name.isEmpty {
                author = Author(name: name, primaryID: uid, ids: uid.isEmpty ? [] : [uid], idLabel: "UID")
            }
        }
        var title = s["text_raw"] as? String ?? ""
        if title.isEmpty {  // 手机版的正文带网页标签
            title = (s["text"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "",
                                                                    options: .regularExpression)
        }
        return ParsedNote(platform: "微博", id: ids(s).first ?? "", title: title, items: media, author: author,
                          published: JSONTree.postDate(s["created_at"]), referer: "https://weibo.com/")
    }

    @MainActor
    static func capture(account: WebAccount, start: URL) -> WebCapture {
        WebCapture(account: account, start: start, spec: WebCaptureSpec(
            title: "微博",
            desktop: true,
            keywords: ["mblogid", "pic_ids", "pic_infos", "page_info", "\"bid\""],
            apiHints: ["/statuses/show", "/statuses/extend"],
            inlineMarkers: ["$render_data"],
            unwrap: { text in
                // var $render_data = [{…}][0] || {};  → 取中间那个数组
                guard let marker = text.range(of: "$render_data"),
                      let open = text.range(of: "[", range: marker.upperBound..<text.endIndex),
                      let close = text.range(of: "][0]", options: .backwards),
                      close.lowerBound > open.lowerBound else { return nil }
                return String(text[open.lowerBound...close.lowerBound])
            },
            match: { path, value in find(in: value, path: path) }))
    }
}
