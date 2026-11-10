import Foundation

/// 统一的解析器结构（借鉴 cobalt / gallery-dl）：每个网站一个模块，都返回 ParsedNote，
/// 之后的下载、去重、日期、相册归类、实况合成全部共用同一套流程。
/// 新增网站：写一个遵守 SiteExtractor 的类型，加进 all 列表（GenericExtractor 兜底，放最后）。
@MainActor
protocol SiteExtractor {
    var name: String { get }
    func canHandle(_ url: URL) -> Bool
    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote
}

@MainActor
enum Extractors {
    static let all: [SiteExtractor] = [XHSExtractor(), DouyinExtractor(), InstagramExtractor(),
                                       XExtractor(), WeiboExtractor(), KuaishouExtractor(), GenericExtractor()]

    static func pick(for url: URL) -> SiteExtractor {
        all.first { $0.canHandle(url) } ?? GenericExtractor()
    }
}

// MARK: - 小红书：App 自己解析（支持实况图），号池按 dl.py 规则轮换、游客优先

struct XHSExtractor: SiteExtractor {
    let name = "小红书"
    func canHandle(_ url: URL) -> Bool { NoteParser.isXHS(url) }

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        service.say("解析小红书链接…")
        var lastError: Error = XHSError("解析失败")
        for ck in CookiePool.candidates(for: url) {
            service.say("使用账号：\(ck?.lastPathComponent ?? "无（游客）")", detail: true)
            do {
                return try await NoteParser.parse(url: url, cookieFile: ck)
            } catch {
                lastError = error
                service.say("失败：\(error.localizedDescription)", detail: true)
            }
        }
        throw lastError
    }
}

// MARK: - 抖音：内置浏览器 + 登录账号

struct DouyinExtractor: SiteExtractor {
    let name = "抖音"
    func canHandle(_ url: URL) -> Bool { Douyin.isDouyin(url) }

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        service.say("解析抖音链接…")
        let ref = try await Douyin.resolve(url)
        guard let account = WebAccounts.shared.accounts(for: "douyin.com").first else {
            // 失败后 SaveService 会提示「登录后重试」，直接带到抖音登录页
            throw XHSError("抖音需要登录：还没有抖音账号", kind: .needsLogin)
        }
        service.say("用账号「\(account.name)」在内置浏览器里读取作品…", detail: true)
        let detail = try await service.runCapture(DouyinCapture(account: account, target: ref))
        await WebAccounts.shared.exportCookies(account)  // 顺便刷新号池里的抖音 cookie
        return try Douyin.parse(detail: detail)
    }
}

// MARK: - Instagram 帖子：内置浏览器 + 登录账号（图片、视频、多图都能存）

struct InstagramExtractor: SiteExtractor {
    let name = "Instagram"
    func canHandle(_ url: URL) -> Bool { Instagram.isPost(url) }

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        guard let account = WebAccounts.shared.accounts(for: "instagram.com").first else {
            // 还没在 App 里登录 Instagram：照旧用 yt-dlp（号池 cookie 或游客），它只能存视频。
            // 失败时报「需要登录」，SaveService 会提示「登录后重试」，登录后就走下面的内置浏览器
            service.say("还没有在 App 里登录 Instagram，先用 yt-dlp 试（只能保存视频）…", detail: true)
            do {
                return try await YtDlpExtractor().extract(url, service: service)
            } catch {
                if Task.isCancelled { throw error }
                throw XHSError("Instagram 需要登录才能保存图片帖子（yt-dlp：\(error.localizedDescription)）",
                               kind: .needsLogin)
            }
        }
        service.say("解析 Instagram 链接…")
        service.say("用账号「\(account.name)」在内置浏览器里读取帖子…", detail: true)
        let item = try await service.runCapture(Instagram.capture(account: account, start: url))
        await WebAccounts.shared.exportCookies(account)  // 顺便刷新号池里的 Instagram cookie
        return try Instagram.parse(item: item)
    }
}

// MARK: - gallery-dl：一个帖子里的图片和视频一起列出来（图文混排）

/// 用 gallery-dl 列出链接里的全部内容，整理成 ParsedNote（文件由 SaveService 逐项下载）。
/// 返回 nil 表示这条路走不通，调用方接着用原来的办法：
/// 这个网址它不支持、它没找到内容、出错了，或者它给的全是要交给 yt-dlp 的分段视频
@MainActor
func galleryNote(_ url: URL, service: SaveService) async throws -> ParsedNote? {
    let dir = try LiveTools.workDir("gallery")
    defer { try? FileManager.default.removeItem(at: dir) }
    let found: YtDlp.Gallery?
    do {
        found = try await YtDlp.gallery(url: url, into: dir, cookies: CookiePool.candidates(for: url)) { line in
            SaveService.shared.say(line, detail: true)
        }
    } catch {
        if Task.isCancelled || (error as? XHSError)?.kind == .cancelled { throw error }
        service.say("gallery-dl 没有拿到内容（\(error.localizedDescription)）", detail: true)
        return nil
    }
    // 这个网址 gallery-dl 不管（比如视频网站）：不出声，交给后面的 yt-dlp
    guard let g = found else { return nil }
    var items: [NoteMedia] = []
    var deferred = 0
    for i in g.items {
        if i.needsYtDlp {
            deferred += 1
            continue
        }
        var m = NoteMedia(kind: i.kind == "video" ? .video : .image, original: [i.url], fallback: i.fallback)
        m.preview = i.fallback.last  // 预览用小一号的图；没有就用原图
        if i.kind == "live", let clip = i.live {
            m.kind = .live
            m.liveVideoURLs = [clip]
        }
        items.append(m)
    }
    // 全是分段视频：整条链接交给 yt-dlp，它能下载并合并
    if items.isEmpty { return nil }
    if deferred > 0 {
        // 图片和分段视频混在一起的少见情况：图片照存，视频如实记成失败，不悄悄丢掉
        var missing = NoteMedia(kind: .video, original: [], fallback: [])
        missing.error = "这一项是分段视频，目前没法和图片一起保存"
        items += Array(repeating: missing, count: deferred)
    }

    let r = g.info
    let platform = YtDlpExtractor.platformName(r.extractor, host: url.host ?? "")
    let ids = ([r.handle] + r.uploaderIDs).filter { !$0.isEmpty }
    let author: Author? = ids.isEmpty && r.uploader.isEmpty ? nil
        : Author(name: r.uploader.isEmpty ? (ids.first ?? "") : r.uploader, primaryID: ids.first ?? "", ids: ids,
                 idLabel: r.handle.isEmpty ? "用户 ID" : "用户名")
    var note = ParsedNote(platform: platform, id: r.id, title: r.title, items: items, author: author,
                          published: r.published, referer: g.referer)
    let count = items.count
    if count > YtDlpExtractor.askAbove {
        // 单个帖子不会有这么多项：多半是主页或合集，先问一句（查重和选相册之后才问）
        let all = items
        let more = r.more
        note.fetch = { selection, _ in
            // 预览页里已经看到数量并勾选过了，不用再问
            if let selection {
                return all.enumerated().filter { selection.contains($0.offset) }.map { $0.element }
            }
            return try await service.askSaveAll(count: count, what: "主页或合集", more: more) ? all : Array(all.prefix(1))
        }
    }
    return note
}

// MARK: - X、微博：先 gallery-dl（图片和视频都拿），不行再 yt-dlp（视频），再不行用内置浏览器 + 登录账号

/// 先用 yt-dlp；失败时，如果在 App 里登录过这个网站，就用内置浏览器读取帖子数据（图片、实况图、视频都能存）。
/// 没登录过就报「需要登录」，SaveService 会提示「登录后重试」。
/// 已知的不足：图片和视频混排的帖子，yt-dlp 能拿到视频就不会走内置浏览器，图片会漏掉
@MainActor
private func ytDlpThenWeb(_ url: URL, service: SaveService, site: String, siteName: String,
                          capture: (WebAccount) -> WebCapture,
                          parse: ([String: Any]) throws -> ParsedNote) async throws -> ParsedNote {
    do {
        return try await YtDlpExtractor().extract(url, service: service)
    } catch {
        if Task.isCancelled { throw error }
        service.say("yt-dlp 没有拿到视频（\(error.localizedDescription)），可能是图片帖子", detail: true)
        guard let account = WebAccounts.shared.accounts(for: site).first else {
            throw XHSError("\(siteName)的图片帖子需要先登录\(siteName)账号才能保存", kind: .needsLogin)
        }
        service.say("用账号「\(account.name)」在内置浏览器里读取…", detail: true)
        let data = try await service.runCapture(capture(account))
        await WebAccounts.shared.exportCookies(account)  // 顺便刷新号池里的 cookie
        return try parse(data)
    }
}

struct XExtractor: SiteExtractor {
    let name = "X"
    func canHandle(_ url: URL) -> Bool { XPost.isPost(url) }

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        if let note = try await galleryNote(url, service: service) { return note }
        return try await ytDlpThenWeb(url, service: service, site: "x.com", siteName: "X",
                               capture: { XPost.capture(account: $0, start: url) },
                               parse: { try XPost.parse(tweet: $0) })
    }
}

struct WeiboExtractor: SiteExtractor {
    let name = "微博"
    func canHandle(_ url: URL) -> Bool { Weibo.isPost(url) }

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        if let note = try await galleryNote(url, service: service) { return note }
        return try await ytDlpThenWeb(url, service: service, site: "weibo.com", siteName: "微博",
                               capture: { Weibo.capture(account: $0, start: url) },
                               parse: { try Weibo.parse(status: $0) })
    }
}

// MARK: - 快手：App 自己读网页（图集、单图、视频），游客优先；不行再用内置浏览器 + 登录账号

struct KuaishouExtractor: SiteExtractor {
    let name = "快手"
    func canHandle(_ url: URL) -> Bool { Kuaishou.isPost(url) }

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        service.say("解析快手链接…")
        var lastError: Error = XHSError("快手网页里没有作品数据")
        // 1. 直接请求网页：先游客，再号池里的快手账号
        for ck in CookiePool.candidates(for: url) {
            service.say("使用账号：\(ck?.lastPathComponent ?? "无（游客）")", detail: true)
            do {
                let page = try await Kuaishou.fetchPage(url, cookieFile: ck)
                if let state = Kuaishou.pageState(page.html) {
                    return try Kuaishou.parse(state, pageURL: page.url)
                }
                lastError = XHSError("快手网页里没有作品数据（可能需要验证）")
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
            }
            service.say("失败：\(lastError.localizedDescription)", detail: true)
        }
        // 2. 用登录过的快手账号在内置浏览器里打开，需要验证时由用户在页面里完成
        if let account = WebAccounts.shared.accounts(for: "kuaishou.com").first {
            service.say("用账号「\(account.name)」在内置浏览器里读取…", detail: true)
            let capture = Kuaishou.capture(account: account, start: url)
            let state = try await service.runCapture(capture)
            let pageURL = capture.webView.url ?? url
            await WebAccounts.shared.exportCookies(account)
            return try Kuaishou.parse(state, pageURL: pageURL)
        }
        // 3. 最后试 yt-dlp（只有视频）；还不行就提示登录
        do {
            return try await YtDlpExtractor().extract(url, service: service)
        } catch {
            if Task.isCancelled { throw error }
            throw XHSError("快手没有读到作品数据（\(lastError.localizedDescription)）。登录快手账号后可以在内置浏览器里读取",
                           kind: .needsLogin)
        }
    }
}

// MARK: - 其它网站：先问 gallery-dl（图片、图文混排），它不管的再交给 yt-dlp（视频）

struct GenericExtractor: SiteExtractor {
    let name = "其它网站"
    func canHandle(_ url: URL) -> Bool { true }

    /// 这些网站不走 gallery-dl：Instagram 用它容易触发验证，这里到的是帖子以外的链接（主页、快拍），交给 yt-dlp
    static let skipGallery: Set<String> = ["instagram.com"]

    /// 跟着跳转走到底，返回最后的网址（短链用；失败返回 nil）
    private static func followRedirects(_ url: URL) async -> URL? {
        for method in ["HEAD", "GET"] {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = method
            req.setValue(NoteParser.mobileUA, forHTTPHeaderField: "User-Agent")
            if let (_, resp) = try? await URLSession.shared.data(for: req), let final = resp.url, final != url {
                return final
            }
        }
        return nil
    }

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        // 先验证：只有 yt-dlp 或 gallery-dl 里有专门提取器的网站才去解析，其它的直接报错
        var target = url
        var known = await YtDlp.supports(target)
        if !known.any {
            // 可能是短链（比如 b23.tv）：跟过去看最后落在哪个网站
            service.say("不认识这个网址，看看它跳转到哪里…", detail: true)
            if let final = await Self.followRedirects(url) {
                try Task.checkCancellation()
                service.say("跳转到：\(final.host ?? final.absoluteString)", detail: true)
                let picked = Extractors.pick(for: final)
                if !(picked is GenericExtractor) { return try await picked.extract(final, service: service) }
                target = final
                known = await YtDlp.supports(final)
            }
        }
        guard known.any else {
            throw XHSError("不支持这个网站：\(target.host ?? target.absoluteString)")
        }
        if known.gallery, !Self.skipGallery.contains(CookiePool.site(of: target.host ?? "")),
           let note = try await galleryNote(target, service: service) {
            return note
        }
        guard known.ytdlp else {
            throw XHSError("没有解析到可以保存的图片或视频（细节在「过程」里）")
        }
        return try await YtDlpExtractor().extract(target, service: service)
    }
}

// MARK: - yt-dlp：视频

struct YtDlpExtractor: SiteExtractor {
    let name = "yt-dlp"
    func canHandle(_ url: URL) -> Bool { true }

    /// 一个链接里超过这么多项就先问用户（多图 / 多视频帖子最多 20 项左右，更多的是合集、播放列表）
    static let askAbove = 20

    /// yt-dlp 的网站标识 → 相册名里用的平台名
    static func platformName(_ extractor: String, host: String) -> String {
        let key = extractor.lowercased()
        let table: [(String, String)] = [
            ("bilibili", "哔哩哔哩"), ("weibo", "微博"), ("douyin", "抖音"), ("xiaohongshu", "小红书"),
            ("twitter", "X"), ("youtube", "YouTube"), ("instagram", "Instagram"), ("tiktok", "TikTok"),
            ("kuaishou", "快手"), ("ixigua", "西瓜视频"), ("zhihu", "知乎"), ("facebook", "Facebook"),
        ]
        if let hit = table.first(where: { key.contains($0.0) }) { return hit.1 }
        if !extractor.isEmpty, key != "generic" { return extractor }
        return CookiePool.site(of: host)
    }

    /// 下载 probe 解析好的内容并整理成媒体项（音视频分开的在这里合并）。
    /// mergeFailed = 有的项合并失败，多半是 iPhone 处理不了的编码
    private static func collect(dir: URL, limit: Int?, only: [Int]?, maxHeight: Int?, service: SaveService,
                                onLog: @escaping @MainActor (String) -> Void) async throws
        -> (items: [NoteMedia], mergeFailed: Bool) {
        let fetched = try await YtDlp.fetch(into: dir, limit: limit, only: only, maxHeight: maxHeight, onLog: onLog)
        var items: [NoteMedia] = []
        var mergeFailed = false
        for f in fetched {
            var item = NoteMedia(kind: .video, original: [], fallback: [])
            if let e = f.error {
                item.error = e  // 这一项没下载下来：保存时算作失败，其它项照常保存
            } else if f.streams.count >= 2,
                      let v = f.streams.first(where: { $0.hasVideo }),
                      let a = f.streams.first(where: { $0.hasAudio && !$0.hasVideo }) {
                service.say("合并视频和音频…", detail: true)
                let merged = v.path.deletingLastPathComponent().appendingPathComponent("merged.mp4")
                do {
                    try await MediaMerger.merge(video: v.path, audio: a.path, to: merged)
                    item.localFile = merged
                } catch {
                    item.error = error.localizedDescription
                    mergeFailed = true
                }
            } else {
                item.localFile = f.streams[0].path
            }
            if let file = item.localFile,
               ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(file.pathExtension.lowercased()) {
                item.kind = .image
            }
            items.append(item)
        }
        return (items, mergeFailed)
    }

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        // 这里只解析（标题、作者、作品 ID），不下载：查重和选相册之后，SaveService 才调用 note.fetch 下载
        service.say("解析链接：\(url.host ?? url.absoluteString)")
        service.say("用 yt-dlp 解析", detail: true)
        let dir = try LiveTools.workDir("ytdlp")
        do {
            let onLog: @MainActor (String) -> Void = { SaveService.shared.say($0, detail: true) }
            let cookies = CookiePool.candidates(for: url)
            // 解析时按最高清晰度；预览页里可以改，fetch 的第二个参数就是选的清晰度
            let r = try await YtDlp.probe(url: url, into: dir, cookies: cookies, maxHeight: 0, onLog: onLog)
            let count = max(1, r.entryCount)
            if count > 1 {
                service.say("这个链接里有 \(count) 项\(r.more ? "（已到单次上限，后面可能还有）" : "")")
            }
            let platform = Self.platformName(r.extractor, host: url.host ?? "")
            // B 站封面：yt-dlp 给的封面地址就是原始尺寸的封面图
            let coverMode = platform == "哔哩哔哩" && r.thumbnail != nil ? Prefs.biliCover : .off
            let cover = r.thumbnail.map { NoteMedia(kind: .image, original: [$0], fallback: []) }
            if coverMode == .only { service.say("按设置只保存封面，不下载视频") }
            let fetch: @MainActor (Set<Int>?, Int) async throws -> [NoteMedia] = { selection, maxHeight in
                // selection：用户在预览页选中的项。占位的顺序是「视频 0..<count，然后是封面」
                if coverMode == .only, let cover { return [cover] }
                var limit: Int?
                var only: [Int]?
                if let selection {
                    only = selection.filter { $0 < count }.sorted().map { $0 + 1 }  // dlcore 里从 1 数起
                } else if count > YtDlpExtractor.askAbove {
                    // 没有预览时：多图 / 多视频帖子不会超过 20 项，再多就是合集或播放列表，先问一句
                    let all = try await service.askSaveAll(count: count, what: "合集或播放列表")
                    if !all { limit = 1 }
                }
                var items: [NoteMedia] = []
                if only?.isEmpty != true {
                    service.say("开始下载…")
                    var got = try await YtDlpExtractor.collect(dir: dir, limit: limit, only: only,
                                                               maxHeight: maxHeight, service: service, onLog: onLog)
                    // 1080p 以上只有 HEVC 等编码，个别网站给的格式 iPhone 合并不了：先问，再改存 1080p（H.264）
                    if got.mergeFailed, maxHeight == 0 || maxHeight > 1080 {
                        if await service.ask("最高清晰度的版本处理不了",
                                             "音视频合并失败，多半是 iPhone 不支持这种编码。要改存 1080p 的版本吗？",
                                             options: ["改存 1080p"]) != nil {
                            service.say("改用 1080p 重新下载…")
                            _ = try await YtDlp.probe(url: url, into: dir, cookies: cookies, maxHeight: 1080,
                                                      onLog: onLog)
                            got = try await YtDlpExtractor.collect(dir: dir, limit: limit, only: only,
                                                                   maxHeight: nil, service: service, onLog: onLog)
                        }
                    }
                    items = got.items
                }
                if coverMode == .withVideo, let cover, selection?.contains(count) ?? true { items.append(cover) }
                return items
            }
            // 占位：下载前还不知道每一项是图片还是视频，fetch 之后换成真正的内容。
            // 预览页用得上的信息先填好：视频的封面图；B 站封面本身就是一项真实的图片
            var placeholder = NoteMedia(kind: .video, original: [], fallback: [])
            placeholder.preview = r.thumbnail
            var placeholders = Array(repeating: placeholder, count: count)
            if let cover, coverMode == .only {
                placeholders = [cover]
            } else if let cover, coverMode == .withVideo {
                placeholders.append(cover)
            }
            let ids = ([r.handle] + r.uploaderIDs).filter { !$0.isEmpty }
            let author: Author? = ids.isEmpty && r.uploader.isEmpty ? nil
                : Author(name: r.uploader.isEmpty ? (ids.first ?? "") : r.uploader,
                         primaryID: ids.first ?? "", ids: ids,
                         idLabel: platform == "哔哩哔哩" ? "UID" : "用户 ID")
            var note = ParsedNote(platform: platform, id: r.id, title: r.title, items: placeholders,
                                  author: author, published: r.published,
                                  // 只有 B 站封面要再联网下载，带上 B 站自己的来源页
                                  referer: platform == "哔哩哔哩" ? "https://www.bilibili.com/" : "",
                                  workDir: dir, fetch: fetch)
            if coverMode != .only {
                note.heights = r.heights
                note.linksByHeight = r.links
            }
            return note
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }
}
