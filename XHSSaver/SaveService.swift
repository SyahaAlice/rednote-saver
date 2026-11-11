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

    /// 这个阶段在下载页步骤列表里叫什么；nil = 不算一步（空闲和三种结束状态）
    var stage: String? {
        switch self {
        case .parsing: return "解析"
        case .waitingUser: return "等你确认"
        case .downloading: return "下载"
        case .saving: return "下载并存入相册"
        default: return nil
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

/// 流程里的一步，下载页按出现的先后列出来。同一步可能进出好几次（比如保存中途弹窗问一句），时间累加
struct SaveStage: Identifiable {
    let name: String
    /// 已经结束的那几段一共用了多久（秒）
    var total: Double = 0
    /// 正在进行的这一段从什么时候开始；nil = 现在不在这一步
    var since: Date?
    var id: String { name }
    var running: Bool { since != nil }

    static func duration(_ s: Double) -> String {
        s < 60 ? String(format: "%.1f 秒", s) : "\(Int(s) / 60) 分 \(Int(s) % 60) 秒"
    }
}

/// 整个保存流程：选解析器 → 解析 → 查重 → 日期/相册 → 下载保存 → 记录
@MainActor
final class SaveService: ObservableObject {
    static let shared = SaveService()

    @Published private(set) var isRunning = false
    @Published private(set) var phase = SavePhase.idle { didSet { trackStage() } }
    /// 这次保存走过的步骤和各自用的时间（下载页直接列出来）
    @Published private(set) var stages: [SaveStage] = []
    /// 当前这个文件下到多少了，例如「37%（12 / 30 MB）」；没有在下大文件时是空的
    @Published private(set) var transfer = ""

    /// 阶段变了：结束上一步、开始（或回到）下一步
    private func trackStage() {
        let name = phase.stage
        if let i = stages.firstIndex(where: { $0.running }) {
            if stages[i].name == name { return }
            if let since = stages[i].since { stages[i].total += Date().timeIntervalSince(since) }
            stages[i].since = nil
        }
        if let name {
            if let i = stages.firstIndex(where: { $0.name == name }) {
                stages[i].since = Date()
            } else {
                stages.append(SaveStage(name: name, since: Date()))
            }
        } else if phase != .idle, !stages.isEmpty {
            transfer = ""
            details.append("用时：" + stages.map { "\($0.name) \(SaveStage.duration($0.total))" }.joined(separator: "，"))
        }
    }

    /// 直接下载的文件（不经过 yt-dlp）报告进度；小文件不显示，免得一闪而过
    func transferred(_ done: Int64, of total: Int64) {
        guard isRunning, total >= 1_048_576 else { return }
        transfer = "\(done * 100 / total)%（\(done / 1_048_576) / \(total / 1_048_576) MB）"
    }
    /// 进度里的关键节点（下载页默认只显示这些）
    @Published private(set) var log: [String] = []
    /// 完整过程：关键节点 + 细节（用哪个账号、yt-dlp 的输出、每一项的下载…），下载页里点开才显示
    @Published private(set) var details: [String] = []
    /// 最新的一行（不管是不是关键节点），保存过程中显示在进度下面，表示「现在在干什么」
    @Published private(set) var latest = ""
    @Published var prompt: ChoicePrompt?
    @Published var albumRequest: AlbumRequest?
    /// 预览：解析完、下载之前，让用户看一眼有什么、勾选要保存的项
    @Published var previewRequest: PreviewRequest?
    /// 当前在哪一页（0 下载、1 相册、2 实况工具、3 设置）
    @Published var selectedTab = 0
    static let settingsTab = 3
    /// 这次保存放进了哪个相册（没放相册是 nil）。下载页的「查看相册」用
    @Published private(set) var savedAlbum: PHAssetCollection?
    /// 请设置页打开这个网址所属网站的登录页（登录、cookie 相关的界面都在设置里）
    @Published var loginRequest: URL?
    /// 抖音读取作品时弹出的内置浏览器
    @Published var capture: DouyinCapture?
    /// Instagram、X、微博读取帖子时弹出的内置浏览器（通用，见 WebCapture.swift）
    @Published var webCapture: WebCapture?

    private var promptContinuation: CheckedContinuation<Int?, Never>?
    private var albumContinuation: CheckedContinuation<AlbumDecision, Never>?
    private var previewContinuation: CheckedContinuation<PreviewChoice?, Never>?
    /// 这次要下载的直链（解析完就有；预览页里改了勾选或清晰度后会更新）
    @Published private(set) var links: [String] = []
    private var useFallbackForAll = false
    /// 内置浏览器读取页现在是不是摆在用户面前（平时在后台读，不显示）
    @Published private(set) var captureShown = false
    /// 正在问「要不要打开页面自己处理」
    private var stuckAsking = false
    /// 这次保存没有界面（快捷指令在后台运行）
    private var headless = false
    /// 后台运行时没能问出口的最后一个问题
    private var unanswered: String?
    /// 正在跑的保存任务，「取消」时用
    private var current: Task<String, Error>?
    private var referer = ""
    private var target = SaveTarget()

    /// 记一行进度。detail = true 的是细节，只进完整过程，不出现在关键节点里
    func say(_ line: String, detail: Bool = false) {
        details.append(line)
        latest = line
        // yt-dlp 的下载进度是「下载中 37%（12 / 30 MB）」这样的一行：取后半段给步骤列表显示
        if line.hasPrefix("下载中 ") { transfer = String(line.dropFirst(4)) } else if line == "一条流下载完成" { transfer = "" }
        if !detail { log.append(line) }
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
        if headless {
            // 后台运行时没有界面可以弹窗：一律按「没有同意」处理（不改存替代版本、不重复保存、不存整个合集）
            unanswered = title
            say("后台运行，问不了「\(title)」，按\(cancel)处理")
            return nil
        }
        return await waiting {
            await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
                promptContinuation = c
                prompt = ChoicePrompt(title: title, message: message, options: options, cancelLabel: cancel)
            }
        }
    }

    /// 一个链接里项数太多（what：「主页或合集」「合集或播放列表」）时先问一句。
    /// 返回 true = 全部保存，false = 只存第 1 项；选「不存了」就取消这次保存并抛错
    func askSaveAll(count: Int, what: String, more: Bool = false) async throws -> Bool {
        switch await ask("这个链接里有 \(count) 项\(more ? "以上（已到单次上限）" : "")",
                         "看起来是\(what)。要全部保存吗？",
                         options: ["全部保存（\(count) 项）", "只存第 1 项"], cancel: "不存了") {
        case 0?: return true
        case 1?: return false
        default:
            cancel()  // 当作用户取消：不再弹后续的提问
            throw XHSError.cancelled
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

    /// 弹出预览页，等用户勾选、选清晰度。nil = 用户点了取消
    private func choosePreview(_ note: ParsedNote) async -> PreviewChoice? {
        if Task.isCancelled { return nil }
        let request = PreviewRequest(platform: note.platform, title: note.title, author: note.author,
                                     items: note.items, referer: note.referer,
                                     savedBefore: History.savedDate(note.historyKey),
                                     heights: note.heights,
                                     links: { note.links(selection: $0, height: $1) })
        return await waiting {
            await withCheckedContinuation { (c: CheckedContinuation<PreviewChoice?, Never>) in
                previewContinuation = c
                previewRequest = request
            }
        }
    }

    func decidePreview(_ choice: PreviewChoice?) {
        previewRequest = nil
        previewContinuation?.resume(returning: choice)
        previewContinuation = nil
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

    /// 内置浏览器读取页要显示在界面上，后台运行时做不了
    private func checkCanShowBrowser() throws {
        if headless { throw XHSError("这个网站要打开 App 用内置浏览器读取，后台做不了。请改用「下载到相册」操作") }
    }

    /// 用抖音内置浏览器在后台读取作品数据（页面不显示）
    func runCapture(_ cap: DouyinCapture) async throws -> [String: Any] {
        try checkCancelled()
        try checkCanShowBrowser()
        capture = cap
        defer { capture = nil }
        return try await runHidden { try await cap.run() }
    }

    /// 用通用的内置浏览器（Instagram、X、微博、快手）在后台读取帖子数据（页面不显示）
    func runCapture(_ cap: WebCapture) async throws -> [String: Any] {
        try checkCancelled()
        try checkCanShowBrowser()
        webCapture = cap
        defer { webCapture = nil }
        return try await runHidden { try await cap.run() }
    }

    /// 内置浏览器读取：平时在后台进行，页面不摆出来，只在进度里说一句。
    /// 等了一阵还没读到（多半是网站要登录或验证），才问用户要不要打开页面自己处理
    private func runHidden(_ run: () async throws -> [String: Any]) async throws -> [String: Any] {
        captureShown = false
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.stuckAsking = true
            let open = await self.ask("还没读到作品", "网页可能要你登录或完成验证。要打开页面自己处理吗？",
                                      options: ["打开页面"], cancel: "取消这次保存")
            self.stuckAsking = false
            guard !Task.isCancelled else { return }  // 问的这会儿已经读到了
            if open != nil {
                self.captureShown = true
                self.phase = .waitingUser
            } else {
                self.cancel()
            }
        }
        defer {
            watchdog.cancel()
            if stuckAsking, prompt != nil { answer(nil) }  // 已经读到了，那句问话不用再答
            captureShown = false
            if phase == .waitingUser { phase = .parsing }
        }
        return try await run()
    }

    // MARK: - 入口

    /// 返回一句结果摘要，例如「已保存 6 张实况照片」
    /// headless = 没有界面（快捷指令在后台运行）：不弹窗、不开内置浏览器
    func save(text: String, mode: SaveMode = .organize, headless: Bool = false) async throws -> String {
        guard !isRunning else { throw XHSError("上一个还在保存，请稍等") }
        guard !(headless && mode == .organize) else { throw XHSError("先预览再保存要打开 App") }
        isRunning = true
        self.headless = headless
        unanswered = nil
        stages = []
        transfer = ""
        phase = .parsing
        log = []
        details = []
        links = []
        savedAlbum = nil
        latest = ""
        useFallbackForAll = false
        // 保存期间不自动锁屏；切到别的 App 时先向系统多要一点时间（真正的后台继续在开始下载时申请）
        BackgroundRun.shared.begin()
        let task = Task { @MainActor in try await self.run(text: text, mode: mode) }
        current = task
        defer {
            current = nil
            isRunning = false
            self.headless = false
            BackgroundRun.shared.end(success: phase == .finished)
        }
        // 调用方（比如快捷指令）被取消时，也一起取消
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            // 后台运行时因为问不了用户而停下的：把原因说清楚，而不是只报一句「已取消」
            if headless, let q = unanswered {
                throw XHSError("需要你确认「\(q)」，后台问不了。请改用「下载到相册」操作")
            }
            throw error
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
        if previewRequest != nil { decidePreview(nil) }
        capture?.cancel()
        webCapture?.cancel()
    }

    /// 用户点了取消就在这里停下（各个步骤之间调用）
    private func checkCancelled() throws {
        if Task.isCancelled { throw XHSError.cancelled }
    }

    private func run(text: String, mode: SaveMode) async throws -> String {
        do {
            guard let url = NoteParser.extractURL(text) else { throw XHSError("没找到链接") }
            if mode != .links { try await PhotoSaver.ensureAccess() }  // 只拿直链不碰相册
            let summary: String
            do {
                summary = try await attempt(url, mode: mode)
            } catch {
                try checkCancelled()
                // 登录、cookie 相关的界面都在「设置 → 账号」里：这里只问要不要过去，不在下载页弹登录页
                let site = CookiePool.site(of: url.host ?? "")
                // 只有「看起来是登录问题」或「这个网站的号池账号已失效 / 未激活」时才提示去登录；
                // 地区限制、作品被删之类的失败直接报错
                let auth = looksLikeAuth(error)
                let badPool = CookiePool.hasProblem(for: url)
                guard auth || badPool else { throw error }
                say("失败：" + error.localizedDescription)
                let reason = badPool ? "号池里\(site)的 cookie 已失效或未激活。" : "看起来需要登录。"
                guard await ask("\(site) 没有保存成功",
                                reason + "登录在「设置 → 账号」里进行。现在过去登录吗？登录后回到「下载」再保存一次。",
                                options: ["去设置登录"], cancel: "不用了") != nil else { throw error }
                try checkCancelled()
                loginRequest = url
                selectedTab = Self.settingsTab
                throw XHSError("需要登录 \(site)：已打开「设置 → 账号」，登录后回到这里再保存一次", kind: .needsLogin)
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

    private func attempt(_ url: URL, mode: SaveMode) async throws -> String {
        let note = try await Extractors.pick(for: url).extract(url, service: self)
        defer { if let d = note.workDir { try? FileManager.default.removeItem(at: d) } }
        try checkCancelled()
        // 验证：确实解析到了能保存的东西，才进入预览、选相册这些步骤
        let usable = note.fetch != nil || note.items.contains {
            $0.error == nil && (!$0.original.isEmpty || !$0.fallback.isEmpty || $0.localFile != nil)
        }
        guard usable else { throw XHSError("没有解析到可以保存的图片或视频") }
        return try await save(note, mode: mode)
    }

    private func save(_ parsed: ParsedNote, mode: SaveMode) async throws -> String {
        var note = parsed
        let title = note.title.isEmpty ? note.id : String(note.title.prefix(40))
        say("\(note.platform)：\(title)（\(note.items.count) 项）")
        if let a = note.author { say("作者：\(a.name)（\(a.primaryID)）") }

        links = note.links(selection: nil, height: 0)

        // 只要直链（快捷指令「获取下载直链」）：到这里就结束，不下载、不保存、不记下载记录
        if mode == .links {
            guard !links.isEmpty else { throw XHSError("这个作品没有可以直接下载的地址") }
            return "解析到 \(links.count) 个下载直链"
        }

        // 「解析」：下载之前先预览，勾选要保存的项、选视频清晰度。selection 是选中的下标。
        // 「快速保存」：不预览、不选相册，全部保存，视频取最高清晰度
        var selection: Set<Int>?
        var height = 0
        if mode == .organize {
            guard let choice = await choosePreview(note) else {
                cancel()  // 在预览页点了取消 = 取消这次保存
                throw XHSError.cancelled
            }
            try checkCancelled()
            let chosen = choice.selection
            selection = chosen
            height = choice.height
            links = note.links(selection: chosen, height: height)
            if height > 0 { say("视频清晰度：最高 " + String(height) + "p", detail: true) }
            if chosen.count < note.items.count { say("选了 \(chosen.count) / \(note.items.count) 项") }
            // 还没下载的作品（yt-dlp）把选择交给 fetch，只下载选中的；其它的直接筛掉没选的
            if note.fetch == nil {
                note.items = note.items.enumerated().filter { chosen.contains($0.offset) }.map { $0.element }
            }
        }

        // 下载记录：保存过的先问一句（预览页里已经提示过，并且用户点了「再保存一次」，就不再问）
        if selection == nil, let last = History.savedDate(note.historyKey) {
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
            say("照片日期设为发布时间：\(p.formatted(date: .abbreviated, time: .shortened))", detail: true)
        }
        if mode == .organize {
            target.album = try await chooseAlbum(for: note)
        } else if mode == .quick {
            target.album = quickAlbum(for: note)
        }
        savedAlbum = target.album
        try checkCancelled()

        // 从这里开始才是真正的下载：申请后台继续（iOS 26 起），切到别的 App 或锁屏也接着下
        let name = note.title.isEmpty ? note.platform : String(note.title.prefix(30))
        let background = BackgroundRun.shared.startLong(title: "正在保存", subtitle: name)
        say(background ? "已申请后台继续下载" : "没有申请到后台继续下载：切到别的 App 后可能暂停", detail: true)

        // yt-dlp 的作品到这里才真正下载（查重、选相册都在下载之前）
        if let fetch = note.fetch {
            phase = .downloading
            note.items = try await fetch(selection, height)
            note.fetch = nil
            try checkCancelled()
        }

        let result = try await saveItems(note)
        // 有失败项时不记：下次再存不会被当成「已经保存过」
        if result.complete { History.record(note.historyKey) }
        return result.summary
    }

    // MARK: - 相册归类

    /// 快速保存：恰好有一个完全匹配的相册（名字里有按规则写的这个账号）就直接放进去，
    /// 没有或者不止一个就不放相册。不问、不新建、不改名、不弹权限申请
    private func quickAlbum(for note: ParsedNote) -> PHAssetCollection? {
        guard let author = note.author, !(author.primaryID.isEmpty && author.ids.isEmpty) else { return nil }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            say("没有「完整照片访问」权限，读不到已有相册，不放相册", detail: true)
            return nil
        }
        let exact = Albums.matches(platform: note.platform, author: author).filter { $0.level == .exact }
        guard exact.count == 1 else {
            say(exact.isEmpty ? "没有完全匹配的相册，不放相册" : "有 \(exact.count) 个相册都完全匹配，不自动放入", detail: true)
            return nil
        }
        say("放入相册：\(exact[0].title)")
        return exact[0].album
    }

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
                                   matches: Albums.matches(platform: note.platform, author: author))
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
            transfer = ""
            let n = String(format: "%02d", i + 1)
            do {
                switch item.kind {
                case .video:
                    say("第 \(n) 项：\(item.localFile == nil ? "下载视频…" : "保存视频…")", detail: true)
                    if let file = try await fileFor(item, dir: dir, name: n, what: "原片") {
                        try await saveVideoOrKeepFile(file, title: note.title.isEmpty ? note.id : note.title,
                                                      platform: note.platform)
                        videos += 1
                    } else {
                        skipped += 1
                    }
                case .image:
                    say("第 \(n) 项：\(item.localFile == nil ? "下载图片…" : "保存图片…")", detail: true)
                    if let file = try await fileFor(item, dir: dir, name: n, what: "原图") {
                        try await PhotoSaver.saveImage(file, target: target)
                        images += 1
                    } else {
                        skipped += 1
                    }
                case .live:
                    say("第 \(n) 项：下载实况图…", detail: true)
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
        // 存到哪了要说清楚：放进了哪个相册，还是只在图库里
        if !parts.isEmpty {
            if let album = target.album?.localizedTitle {
                summary += "，放进了相册「\(album)」"
            } else {
                summary += "，没有放入相册（在图库里）"
            }
        }
        if skipped > 0 { summary += "，跳过 \(skipped) 项" }
        if failures > 0 { summary += "，\(failures) 项失败" }
        return (summary, !parts.isEmpty && failures == 0)
    }

    /// 交给 Downloader 的进度回调（它在后台线程上调用，这里转回主线程）
    private static let reportTransfer: @Sendable (Int64, Int64) -> Void = { done, total in
        Task { @MainActor in SaveService.shared.transferred(done, of: total) }
    }

    /// 已下载好的文件直接用；否则先下首选地址，失败时问用户是否改用替代版本。返回 nil 表示跳过
    private func fileFor(_ item: NoteMedia, dir: URL, name: String, what: String) async throws -> URL? {
        if let e = item.error { throw XHSError(e) }
        if let f = item.localFile { return f }
        var firstError: Error?
        if !item.original.isEmpty {
            do {
                return try await Downloader.download(item.original, to: dir, name: name, referer: referer,
                                                     progress: Self.reportTransfer)
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
