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
    static let all: [SiteExtractor] = [XHSExtractor(), DouyinExtractor(), YtDlpExtractor()]

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
            throw XHSError("抖音需要登录：请先到「设置 → 账号」添加一个抖音账号并登录")
        }
        service.say("用账号「\(account.name)」在内置浏览器里读取作品…")
        let detail = try await service.runCapture(DouyinCapture(account: account, target: ref))
        await WebAccounts.shared.exportCookies(account)  // 顺便刷新号池里的抖音 cookie
        return try Douyin.parse(detail: detail)
    }
}

// MARK: - 其它网站：内嵌的 yt-dlp

struct YtDlpExtractor: SiteExtractor {
    let name = "yt-dlp"
    func canHandle(_ url: URL) -> Bool { true }

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
        service.say("用 yt-dlp 下载：\(url.host ?? url.absoluteString)")
        let dir = try LiveTools.workDir("ytdlp")
        do {
            let r = try await YtDlp.download(url: url, into: dir, cookies: CookiePool.candidates(for: url)) { line in
                SaveService.shared.say(line)
            }
            let file: URL
            if r.streams.count >= 2,
               let v = r.streams.first(where: { $0.hasVideo }),
               let a = r.streams.first(where: { $0.hasAudio && !$0.hasVideo }) {
                service.say("合并视频和音频…")
                file = dir.appendingPathComponent("merged.mp4")
                try await MediaMerger.merge(video: v.path, audio: a.path, to: file)
            } else {
                file = r.streams[0].path
            }
            let isImage = ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(file.pathExtension.lowercased())
            let item = NoteMedia(kind: isImage ? .image : .video, original: [], fallback: [], localFile: file)
            let platform = Self.platformName(r.extractor, host: url.host ?? "")
            let author: Author? = r.uploaderIDs.isEmpty && r.uploader.isEmpty ? nil
                : Author(name: r.uploader.isEmpty ? (r.uploaderIDs.first ?? "") : r.uploader,
                         primaryID: r.uploaderIDs.first ?? r.uploader, ids: r.uploaderIDs)
            return ParsedNote(platform: platform, id: r.id, title: r.title, items: [item],
                              author: author, published: r.published, referer: "", workDir: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }
}
