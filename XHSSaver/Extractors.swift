import Foundation

/// 统一的解析器结构（借鉴 cobalt / gallery-dl）：每个网站一个模块，都返回 ParsedNote，
/// 之后的下载、去重、日期、相册归类、实况合成全部共用同一套流程。
/// 新增网站：写一个遵守 SiteExtractor 的类型，加进 all 列表（yt-dlp 兜底，放最后）。
@MainActor
protocol SiteExtractor {
    var name: String { get }
    func canHandle(_ url: URL) -> Bool
    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote
}

@MainActor
enum Extractors {
    static let all: [SiteExtractor] = [XHSExtractor(), DouyinExtractor(), InstagramExtractor(), YtDlpExtractor()]

    static func pick(for url: URL) -> SiteExtractor {
        all.first { $0.canHandle(url) } ?? YtDlpExtractor()
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
            service.say("使用账号：\(ck?.lastPathComponent ?? "无（游客）")")
            do {
                return try await NoteParser.parse(url: url, cookieFile: ck)
            } catch {
                lastError = error
                service.say("失败：\(error.localizedDescription)")
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
            throw XHSError("抖音需要登录：还没有抖音账号")
        }
        service.say("用账号「\(account.name)」在内置浏览器里读取作品…")
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
            service.say("还没有在 App 里登录 Instagram，先用 yt-dlp 试（只能保存视频）…")
            do {
                return try await YtDlpExtractor().extract(url, service: service)
            } catch {
                throw XHSError("Instagram 需要登录才能保存图片帖子（yt-dlp：\(error.localizedDescription)）")
            }
        }
        service.say("解析 Instagram 链接…")
        service.say("用账号「\(account.name)」在内置浏览器里读取帖子…")
        let item = try await service.runCapture(InstagramCapture(account: account, start: url))
        await WebAccounts.shared.exportCookies(account)  // 顺便刷新号池里的 Instagram cookie
        return try Instagram.parse(item: item)
    }
}

// MARK: - 其它网站：内嵌的 yt-dlp

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

    func extract(_ url: URL, service: SaveService) async throws -> ParsedNote {
        // 这里只解析（标题、作者、作品 ID），不下载：查重和选相册之后，SaveService 才调用 note.fetch 下载
        service.say("用 yt-dlp 解析：\(url.host ?? url.absoluteString)")
        let dir = try LiveTools.workDir("ytdlp")
        do {
            let onLog: @MainActor (String) -> Void = { SaveService.shared.say($0) }
            let r = try await YtDlp.probe(url: url, into: dir, cookies: CookiePool.candidates(for: url), onLog: onLog)
            let count = max(1, r.entryCount)
            if count > 1 {
                service.say("这个链接里有 \(count) 项\(r.more ? "（已到单次上限，后面可能还有）" : "")，会全部保存")
            }
            let fetch: @MainActor () async throws -> [NoteMedia] = {
                // 多图 / 多视频帖子不会超过 20 项；再多就是合集或播放列表，先问一句
                var limit: Int?
                if count > YtDlpExtractor.askAbove {
                    switch await service.ask("这个链接里有 \(count) 项",
                                             "看起来是合集或播放列表。要全部保存吗？",
                                             options: ["全部保存（\(count) 项）", "只存第 1 项"], cancel: "不存了") {
                    case 0?: break
                    case 1?: limit = 1
                    default:
                        service.cancel()  // 当作用户取消：不再弹「要不要补登」之类的后续提问
                        throw XHSError("已取消")
                    }
                }
                service.say("用 yt-dlp 下载…")
                let fetched = try await YtDlp.fetch(into: dir, limit: limit, onLog: onLog)
                var items: [NoteMedia] = []
                for f in fetched {
                    var item = NoteMedia(kind: .video, original: [], fallback: [])
                    if let e = f.error {
                        item.error = e  // 这一项没下载下来：保存时算作失败，其它项照常保存
                    } else if f.streams.count >= 2,
                              let v = f.streams.first(where: { $0.hasVideo }),
                              let a = f.streams.first(where: { $0.hasAudio && !$0.hasVideo }) {
                        service.say("合并视频和音频…")
                        let merged = v.path.deletingLastPathComponent().appendingPathComponent("merged.mp4")
                        do {
                            try await MediaMerger.merge(video: v.path, audio: a.path, to: merged)
                            item.localFile = merged
                        } catch {
                            item.error = error.localizedDescription
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
                return items
            }
            // 占位：下载前还不知道每一项是图片还是视频，fetch 之后换成真正的内容
            let placeholders = Array(repeating: NoteMedia(kind: .video, original: [], fallback: []), count: count)
            let platform = Self.platformName(r.extractor, host: url.host ?? "")
            // 相册名里的 ID：Instagram 用 @ 后面的用户名，其它用 yt-dlp 的 uploader_id（X 是 @ 后面的那个，B 站是 UID）
            let ids = ([r.handle] + r.uploaderIDs).filter { !$0.isEmpty }
            let author: Author? = ids.isEmpty && r.uploader.isEmpty ? nil
                : Author(name: r.uploader.isEmpty ? (ids.first ?? "") : r.uploader,
                         primaryID: ids.first ?? "", ids: ids,
                         idLabel: platform == "哔哩哔哩" ? "UID" : "用户 ID")
            return ParsedNote(platform: platform, id: r.id, title: r.title, items: placeholders,
                              author: author, published: r.published, referer: "", workDir: dir, fetch: fetch)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }
}
