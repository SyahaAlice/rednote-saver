import Foundation
import Photos

/// 弹窗提问：options 是按钮文字，返回点了第几个；点「取消/跳过」返回 nil
struct ChoicePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let options: [String]
    let cancelLabel: String
}

/// 相册归类：解析完后让用户选放进哪个相册
struct AlbumRequest: Identifiable {
    let id = UUID()
    let platform: String
    let author: Author
    let suggestedName: String
    let matches: [Albums.Match]
}

enum AlbumDecision {
    case existing(PHAssetCollection)
    case create(String)
    case none
}

/// 保存流程走到哪一步。以前这些状态散在 isRunning、几个弹窗变量和日志文字里，现在集中写在这里，
/// 界面（进度卡片）和自动化操作（辅助功能标识 phase）都读它。完整的状态说明见 docs/architecture.md
enum SavePhase: Equatable {
    /// 空闲：还没保存过，或上一次的结果已经被新的一次覆盖
    case idle
    /// 解析链接（跟随短链、读取作品信息）
    case parsing
    /// 等用户回答：弹窗、选相册、内置浏览器登录 / 读取
    case waitingUser
    /// 下载（yt-dlp 的作品在保存前先整个下载）
    case downloading
    /// 逐项下载并存进相册：正在处理第 index 项，共 total 项
    case saving(index: Int, total: Int)
    case finished
    case failed
    case cancelled

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .parsing: return "正在解析"
        case .waitingUser: return "等你确认"
        case .downloading: return "正在下载"
        case .saving(let index, let total): return total > 1 ? "正在保存 \(index) / \(total)" : "正在保存"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    /// 给自动化操作读的固定英文名（不随界面文字变化）
    var code: String {
        switch self {
        case .idle: return "idle"
        case .parsing: return "parsing"
        case .waitingUser: return "waiting-user"
        case .downloading: return "downloading"
        case .saving(let index, let total): return "saving-\(index)-of-\(total)"
        case .finished: return "finished"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// 整个保存流程：选解析器 → 解析 → 查重 → 日期/相册 → 下载保存 → 记录
@MainActor
final class SaveService: ObservableObject {
    static let shared = SaveService()

    @Published private(set) var isRunning = false
    @Published private(set) var phase = SavePhase.idle
    @Published private(set) var log: [String] = []
    @Published var prompt: ChoicePrompt?
    @Published var albumRequest: AlbumRequest?
    /// 抖音读取作品时弹出的内置浏览器
    @Published var capture: DouyinCapture?
    /// Instagram、X、微博读取帖子时弹出的内置浏览器（通用，见 WebCapture.swift）
    @Published var webCapture: WebCapture?
    /// 补登：弹出某个账号的内置浏览器登录页
    @Published var loginAccount: WebAccount?
    private var loginContinuation: CheckedContinuation<Void, Never>?

    private var promptContinuation: CheckedContinuation<Int?, Never>?
    private var albumContinuation: CheckedContinuation<AlbumDecision, Never>?
    private var useFallbackForAll = false
    /// 正在跑的保存任务，「取消」时用
    private var current: Task<String, Error>?
    private var referer = ""
    private var target = SaveTarget()

    func say(_ line: String) {
        log.append(line)
    }

    // MARK: - 提问

    /// 等用户回答期间把阶段标成 waitingUser，回答完恢复成之前的阶段
    private func waiting<T>(_ body: () async throws -> T) async rethrows -> T {
        let before = phase
        phase = .waitingUser
        defer { if phase == .waitingUser { phase = before } }
        return try await body()
    }

    func ask(_ title: String, _ message: String, options: [String], cancel: String = "跳过") async -> Int? {
        if Task.isCancelled { return nil }  // 已经点了取消，不再弹窗
        return await waiting {
            await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
                promptContinuation = c
                prompt = ChoicePrompt(title: title, message: message, options: options, cancelLabel: cancel)
            }
        }
    }

    func answer(_ index: Int?) {
        prompt = nil
        promptContinuation?.resume(returning: index)
        promptContinuation = nil
    }

    func decideAlbum(_ decision: AlbumDecision) {
        albumRequest = nil
        albumContinuation?.resume(returning: decision)
        albumContinuation = nil
    }

    /// 弹出内置浏览器让用户登录（补登），关掉后 cookie 已写进号池
    func runLogin(_ account: WebAccount) async {
        await waiting {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                loginContinuation = c
                loginAccount = account
            }
        }
    }

    func loginFinished() {
        loginAccount = nil
        loginContinuation?.resume()
        loginContinuation = nil
    }

    /// 下载页的「补登」按钮：登录输入框里那个链接所属的网站
    func quickLogin(text: String) async {
        guard let url = NoteParser.extractURL(text) else { return }
        let account = WebAccounts.shared.accountForLogin(url: url)
        await runLogin(account)
        let n = await WebAccounts.shared.exportCookies(account)
        say("已更新「\(account.name)」的 cookie（\(n) 条）")
    }

    /// 这次失败是不是需要登录 / cookie 失效。
    /// 自己代码里抛的错误直接看分类（XHSError.kind）；yt-dlp 和网络层来的错误没有分类，只能看说明文字
    private func looksLikeAuth(_ error: Error) -> Bool {
        if let e = error as? XHSError {
            if e.kind == .needsLogin { return true }
            if e.kind == .cancelled { return false }
        }
        let s = error.localizedDescription.lowercased()
        return ["login", "log in", "sign in", "cookie", "403", "401", "登录", "验证", "需要登录", "logged in"]
            .contains { s.contains($0) }
    }

    /// 弹出抖音内置浏览器并等它读到作品数据
    func runCapture(_ cap: DouyinCapture) async throws -> [String: Any] {
        try checkCancelled()
        capture = cap
        defer { capture = nil }
        return try await waiting { try await cap.run() }
    }

    /// 弹出通用的内置浏览器（Instagram、X、微博）并等它读到帖子数据
    func runCapture(_ cap: WebCapture) async throws -> [String: Any] {
        try checkCancelled()
        webCapture = cap
        defer { webCapture = nil }
        return try await waiting { try await cap.run() }
    }

    // MARK: - 入口

    /// 返回一句结果摘要，例如「已保存 6 张实况照片」
    func save(text: String) async throws -> String {
        guard !isRunning else { throw XHSError("上一个还在保存，请稍等") }
        isRunning = true
        phase = .parsing
        log = []
        useFallbackForAll = false
        let task = Task { @MainActor in try await self.run(text: text) }
        current = task
        defer {
            current = nil
            isRunning = false
        }
        // 调用方（比如快捷指令）被取消时，也一起取消
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 「取消」按钮：停掉正在进行的保存。
    /// 除了取消任务，还要把所有正在等用户回答的弹窗 / 页面都收掉，否则流程会一直卡在等待上
    func cancel() {
        guard isRunning, let task = current else { return }
        if !task.isCancelled {
            say("正在取消…")
            task.cancel()
        }
        if prompt != nil { answer(nil) }
        if albumRequest != nil { decideAlbum(.none) }
        if loginAccount != nil { loginFinished() }
        capture?.cancel()
        webCapture?.cancel()
    }

    /// 用户点了取消就在这里停下（各个步骤之间调用）
    private func checkCancelled() throws {
        if Task.isCancelled { throw XHSError.cancelled }
    }

    private func run(text: String) async throws -> String {
        do {
            guard let url = NoteParser.extractURL(text) else { throw XHSError("没找到链接") }
            try await PhotoSaver.ensureAccess()
            let summary: String
            do {
                summary = try await attempt(url)
            } catch {
                try checkCancelled()
                // 失败时可以直接在内置浏览器里补登这个网站，登录后自动重试一次
                let site = CookiePool.site(of: url.host ?? "")
                say("失败：" + error.localizedDescription)
                // 只有「看起来是登录问题」或「这个网站的号池账号已失效 / 未激活」时才提示补登；
                // 地区限制、作品被删之类的失败直接报错
                let auth = looksLikeAuth(error)
                let badPool = CookiePool.hasProblem(for: url)
                guard auth || badPool else { throw error }
                let reason = badPool ? "号池里\(site)的 cookie 已失效或未激活。" : "看起来需要登录。"
                guard await ask("\(site) 没有保存成功", reason + "要用内置浏览器登录（补登）后重试吗？",
                                options: ["登录后重试"], cancel: "不用了") != nil else { throw error }
                try checkCancelled()
                let account = WebAccounts.shared.accountForLogin(url: url)
                await runLogin(account)
                try checkCancelled()
                let n = await WebAccounts.shared.exportCookies(account)  // 等 cookie 写进号池再重试
                say("已更新「\(account.name)」的 cookie（\(n) 条），重试…")
                phase = .parsing
                summary = try await attempt(url)
            }
            phase = .finished
            say("✅ " + summary)
            return summary
        } catch {
            // 取消时底层报的是各种各样的错（网络请求被取消等），统一说成「已取消」
            let cancelled = Task.isCancelled || (error as? XHSError)?.kind == .cancelled
            let shown: Error = cancelled ? XHSError.cancelled : error
            phase = cancelled ? .cancelled : .failed
            say("❌ " + shown.localizedDescription)
            throw shown
        }
    }

    private func attempt(_ url: URL) async throws -> String {
        let note = try await Extractors.pick(for: url).extract(url, service: self)
        defer { if let d = note.workDir { try? FileManager.default.removeItem(at: d) } }
        try checkCancelled()
        return try await save(note)
    }

    private func save(_ parsed: ParsedNote) async throws -> String {
        var note = parsed
        let title = note.title.isEmpty ? note.id : String(note.title.prefix(40))
        say("\(note.platform)：\(title)（\(note.items.count) 项）")
        if let a = note.author { say("作者：\(a.name)（\(a.primaryID)）") }

        // 下载记录：保存过的先问一句
        if let last = History.savedDate(note.historyKey) {
            let when = last.formatted(date: .abbreviated, time: .shortened)
            if await ask("这个作品已经保存过", "上次保存于 \(when)。要再保存一次吗？",
                         options: ["再保存一次"], cancel: "不用了") == nil {
                try checkCancelled()
                return "已跳过（之前保存过）"
            }
        }

        target = SaveTarget()
        if Prefs.usePublishDate, let p = note.published {
            target.creationDate = p
            say("照片日期设为发布时间：\(p.formatted(date: .abbreviated, time: .shortened))")
        }
        if Prefs.askAlbum {
            target.album = try await chooseAlbum(for: note)
        }
        try checkCancelled()

        // yt-dlp 的作品到这里才真正下载（查重、选相册都在下载之前）
        if let fetch = note.fetch {
            phase = .downloading
            note.items = try await fetch()
            note.fetch = nil
            try checkCancelled()
        }

        let result = try await saveItems(note)
        // 有失败项时不记：下次再存不会被当成「已经保存过」
        if result.complete { History.record(note.historyKey) }
        return result.summary
    }

    // MARK: - 相册归类

    private func chooseAlbum(for note: ParsedNote) async throws -> PHAssetCollection? {
        guard let author = note.author, !author.name.isEmpty || !author.ids.isEmpty else {
            say("拿不到作者信息，不做相册归类")
            return nil
        }
        guard await PhotoSaver.hasFullAccess() else {
            say("没有「完整照片访问」权限，读不到已有相册，这次不做相册归类（可在系统设置里改）")
            return nil
        }
        try checkCancelled()
        let request = AlbumRequest(platform: note.platform, author: author,
                                   suggestedName: Albums.ruleName(platform: note.platform, author: author),
                                   matches: Albums.matches(for: author))
        let decision = await waiting {
            await withCheckedContinuation { (c: CheckedContinuation<AlbumDecision, Never>) in
                albumContinuation = c
                albumRequest = request
            }
        }
        switch decision {
        case .existing(let album):
            say("放入相册：\(album.localizedTitle ?? "")")
            return album
        case .create(let name):
            let album = try await Albums.create(name)
            say("新建相册：\(name)")
            return album
        case .none:
            return nil
        }
    }

    // MARK: - 下载并存进相册

    /// complete = 存了东西而且没有失败项（用户自己选择跳过的不算失败）
    private func saveItems(_ note: ParsedNote) async throws -> (summary: String, complete: Bool) {
        referer = note.referer
        let dir = try LiveTools.workDir("note-\(note.id)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var images = 0, lives = 0, videos = 0, skipped = 0, failures = 0
        for (i, item) in note.items.enumerated() {
            try checkCancelled()
            phase = .saving(index: i + 1, total: note.items.count)
            let n = String(format: "%02d", i + 1)
            do {
                switch item.kind {
                case .video:
                    say("第 \(n) 项：\(item.localFile == nil ? "下载视频…" : "保存视频…")")
                    if let file = try await fileFor(item, dir: dir, name: n, what: "原片") {
                        try await saveVideoOrKeepFile(file, title: note.title.isEmpty ? note.id : note.title,
                                                      platform: note.platform)
                        videos += 1
                    } else {
                        skipped += 1
                    }
                case .image:
                    say("第 \(n) 项：\(item.localFile == nil ? "下载图片…" : "保存图片…")")
                    if let file = try await fileFor(item, dir: dir, name: n, what: "原图") {
                        try await PhotoSaver.saveImage(file, target: target)
                        images += 1
                    } else {
                        skipped += 1
                    }
                case .live:
                    say("第 \(n) 项：下载实况图…")
                    switch try await saveLive(item, dir: dir, name: n) {
                    case .live: lives += 1
                    case .still: images += 1
                    case .skipped: skipped += 1
                    }
                }
            } catch {
                try checkCancelled()
                failures += 1
                say("第 \(n) 项失败：\(error.localizedDescription)")
            }
        }

        var parts: [String] = []
        if lives > 0 { parts.append("\(lives) 张实况照片") }
        if images > 0 { parts.append("\(images) 张图片") }
        if videos > 0 { parts.append("\(videos) 个视频") }
        if parts.isEmpty && failures > 0 { throw XHSError("一项都没保存成功") }
        var summary = parts.isEmpty ? "没有保存任何内容" : "已保存 " + parts.joined(separator: "、")
        if let album = target.album?.localizedTitle { summary += "（相册：\(album)）" }
        if skipped > 0 { summary += "，跳过 \(skipped) 项" }
        if failures > 0 { summary += "，\(failures) 项失败" }
        return (summary, !parts.isEmpty && failures == 0)
    }

    /// 已下载好的文件直接用；否则先下首选地址，失败时问用户是否改用替代版本。返回 nil 表示跳过
    private func fileFor(_ item: NoteMedia, dir: URL, name: String, what: String) async throws -> URL? {
        if let e = item.error { throw XHSError(e) }
        if let f = item.localFile { return f }
        var firstError: Error?
        if !item.original.isEmpty {
            do {
                return try await Downloader.download(item.original, to: dir, name: name, referer: referer)
            } catch {
                try checkCancelled()
                firstError = error
                say("第 \(name) 项\(what)下载失败：\(error.localizedDescription)")
            }
        }
        guard !item.fallback.isEmpty else { throw firstError ?? XHSError("没有可用的下载地址") }
        if !useFallbackForAll {
            let replacement = what == "原片" ? "较低清晰度的视频" : "替代版本（服务器转码的全尺寸 JPEG，不行再用网页压缩图）"
            switch await ask("第 \(name) 项拿不到\(what)", "要改存\(replacement)吗？",
                             options: ["改存这一项", "本次全部改存替代版本"]) {
            case nil:
                try checkCancelled()
                say("第 \(name) 项已跳过")
                return nil
            case 1?:
                useFallbackForAll = true
            default:
                break
            }
        }
        say("第 \(name) 项改存替代版本")
        return try await Downloader.download(item.fallback, to: dir, name: "\(name)-fallback", referer: referer)
    }

    private enum LiveOutcome { case live, still, skipped }

    /// 存成实况照片；任何一步失败都先问用户要不要只存静态图；存完回读确认确实是实况
    private func saveLive(_ item: NoteMedia, dir: URL, name: String) async throws -> LiveOutcome {
        guard let still = try await fileFor(item, dir: dir, name: name, what: "原图") else { return .skipped }
        do {
            let clip = try await Downloader.download(item.liveVideoURLs, to: dir, name: "\(name)-clip", referer: referer)
            let id = UUID().uuidString
            let photo = try LivePhotoMaker.makeImage(from: still, in: dir, name: "\(name)-live", identifier: id)
            let video = try await LivePhotoMaker.makeVideo(from: clip, in: dir, name: "\(name)-live", identifier: id)
            let saved = try await PhotoSaver.saveLivePhoto(photo: photo, video: video, target: target)
            if let saved, PhotoSaver.isLivePhoto(saved) == false {
                say("⚠️ 第 \(name) 项存进去了，但相册没有把它识别成实况照片")
            }
            return .live
        } catch {
            try checkCancelled()
            say("第 \(name) 项实况合成失败：\(error.localizedDescription)")
            if await ask("第 \(name) 项实况合成失败", "要只存这张的静态图吗？", options: ["只存静态图"]) == nil {
                try checkCancelled()
                return .skipped
            }
            try await PhotoSaver.saveImage(still, target: target)
            return .still
        }
    }

    /// 文件夹名 / 文件名里不能用的字符换成下划线
    private func safeName(_ s: String, max: Int) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(max))
    }

    /// 存进相册；相册不收的格式（比如 webm）改存到 App 的「下载」文件夹，
    /// 按归类分子文件夹：选了相册就用相册名，没选就用平台名
    private func saveVideoOrKeepFile(_ file: URL, title: String, platform: String) async throws {
        do {
            try await PhotoSaver.saveVideo(file, target: target)
        } catch {
            let group = safeName(target.album?.localizedTitle ?? platform, max: 80)
            var out = CookiePool.documents.appendingPathComponent("下载", isDirectory: true)
            if !group.isEmpty { out = out.appendingPathComponent(group, isDirectory: true) }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let safe = safeName(title, max: 60)
            let dst = out.appendingPathComponent("\(DateFormatter.fileStamp.string(from: Date()))_\(safe).\(file.pathExtension)")
            try FileManager.default.copyItem(at: file, to: dst)
            let folder = group.isEmpty ? "下载" : "下载 → \(group)"
            say("相册没有接收（\(error.localizedDescription)），已存到「文件 → 多功能媒体下载器 → \(folder)」：\(dst.lastPathComponent)")
        }
    }
}
