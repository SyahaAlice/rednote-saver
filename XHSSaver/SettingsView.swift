import SwiftUI
import UniformTypeIdentifiers

/// 「导出账号」写出去的文件
struct CookieBundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    @ObservedObject private var web = WebAccounts.shared
    @ObservedObject private var service = SaveService.shared
    @State private var loginAccount: WebAccount?
    @State private var showAdd = false
    /// 号池文件夹里的所有 cookies 文件（App 内登录导出的 + 电脑导入的）
    @State private var pool: [CookiePool.Summary] = []
    @AppStorage(Prefs.imageFormatKey) private var imageFormat = Prefs.ImageFormat.heic.rawValue
    @AppStorage(Prefs.usePublishDateKey) private var usePublishDate = false
    @AppStorage(Prefs.biliCoverKey) private var biliCover = Prefs.BiliCover.withVideo.rawValue
    /// 账号一节的详细说明平时收起
    @State private var showAccountHelp = false
    @AppStorage(WebAccounts.autoRenewKey) private var autoRenew = true
    @AppStorage(Prefs.animationOnKey) private var animationOn = true
    /// 导出 / 导入账号
    @State private var exportDocument: CookieBundleDocument?
    @State private var showExport = false
    @State private var showImport = false
    @State private var transferNote = ""
    @State private var historyCount = History.count
    @State private var confirmClearHistory = false
    /// 相册命名的两组设置平时很少改，默认收起
    @State private var showPrefixes = false
    @State private var showTemplates = false
    @State private var prefixes = Prefs.albumPrefixes
    @State private var newPlatform = ""
    @State private var onlineResults: [String: Bool] = [:]
    @State private var checking = false
    @State private var version: YtDlp.Version?
    @State private var versionError = ""
    @State private var updating = false
    @State private var gallery: YtDlp.GalleryVersion?
    @State private var galleryError = ""
    @State private var updatingGallery = false

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "?" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("小红书图片格式", selection: $imageFormat) {
                        ForEach(Prefs.ImageFormat.allCases) { f in Text(f.title).tag(f.rawValue) }
                    }
                    Picker("B 站封面", selection: $biliCover) {
                        ForEach(Prefs.BiliCover.allCases) { c in Text(c.title).tag(c.rawValue) }
                    }
                    Toggle("照片日期用作品发布时间", isOn: $usePublishDate)
                    HStack {
                        Text("下载记录：\(historyCount) 条")
                        Spacer()
                        Button("清空", role: .destructive) { confirmClearHistory = true }
                            .disabled(historyCount == 0)
                    }
                } header: {
                    Label("保存", systemImage: "square.and.arrow.down")
                } footer: {
                    Text("HEIC 是小红书存的原文件；JPEG / PNG 由小红书服务器转换，分辨率不变。")
                }

                Section {
                    Toggle("下载页顶部动画", isOn: $animationOn)
                        .accessibilityIdentifier("animation-toggle")
                } header: {
                    Label("界面", systemImage: "sparkles")
                }

                Section {
                    DisclosureGroup(isExpanded: $showPrefixes) {
                        ForEach(Prefs.prefixPlatforms, id: \.self) { platform in
                            HStack {
                                Text(platform)
                                Spacer()
                                TextField("前缀", text: Binding(
                                    get: { prefixes[platform] ?? Prefs.idPrefix(for: platform) },
                                    set: { prefixes[platform] = $0; Prefs.albumPrefixes = prefixes }))
                                    .multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .frame(maxWidth: 140)
                            }
                        }
                        HStack {
                            TextField("添加平台（例如 西瓜视频）", text: $newPlatform)
                            Button("添加") {
                                let p = newPlatform.trimmingCharacters(in: .whitespaces)
                                guard !p.isEmpty else { return }
                                prefixes[p] = Prefs.idPrefix(for: p)
                                Prefs.albumPrefixes = prefixes
                                newPlatform = ""
                            }
                            .buttonStyle(.borderless)
                            .disabled(newPlatform.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Text("没列出来的平台自动用小写拼音首字母（西瓜视频 → xgsp_），英文名用小写全名。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("ID 前缀", systemImage: "number")
                    }

                    DisclosureGroup(isExpanded: $showTemplates) {
                        LabeledTemplate(title: "常规", key: Prefs.templateNormalKey,
                                        placeholder: Prefs.defaultTemplateNormal)
                        LabeledTemplate(title: "已注销 / 常删作品", key: Prefs.templateDeletedKey,
                                        placeholder: Prefs.defaultTemplateDeleted)
                        LabeledTemplate(title: "多账号之间的分隔", key: Prefs.multiSeparatorKey,
                                        placeholder: Prefs.defaultMultiSeparator)
                        TemplatePreview()
                        Text("可用的占位符：{用户名} {前缀} {ID}。留空就用默认模板。多个账号时每个账号套一次模板，同一平台的排在一起，中间用分隔符。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("模板", systemImage: "textformat")
                    }
                } header: {
                    Label("相册命名", systemImage: "rectangle.stack.badge.person.crop")
                }

                Section {
                    if rows.isEmpty {
                        Text("还没有账号，以游客身份下载。抖音和 Instagram 必须登录。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        accountRow(row)
                    }
                    Button("添加账号") { showAdd = true }
                    Toggle("自动续期登录", isOn: $autoRenew)
                    HStack {
                        Button("重新读取") {
                            pool = CookiePool.summaries()
                            onlineResults = [:]
                        }
                        Spacer()
                        Button(checking ? "正在验证…" : "在线验证小红书账号") {
                            Task {
                                checking = true
                                for a in pool where a.sites.contains("xiaohongshu.com") {
                                    if let r = await CookiePool.verifyOnline(a.file) { onlineResults[a.name] = r }
                                }
                                checking = false
                            }
                        }
                        .disabled(checking || !pool.contains { $0.sites.contains("xiaohongshu.com") })
                    }
                    .buttonStyle(.borderless)
                    HStack {
                        Button("导出全部账号") {
                            Task {
                                do {
                                    exportDocument = CookieBundleDocument(data: try await web.exportBundle())
                                    showExport = true
                                } catch {
                                    transferNote = "导出失败：" + error.localizedDescription
                                }
                                pool = CookiePool.summaries()
                            }
                        }
                        .accessibilityIdentifier("accounts-export")
                        Spacer()
                        Button("从文件导入") { showImport = true }
                            .accessibilityIdentifier("accounts-import")
                    }
                    .buttonStyle(.borderless)
                    if !transferNote.isEmpty {
                        Text(transferNote).font(.footnote).foregroundStyle(.secondary)
                    }
                    DisclosureGroup(isExpanded: $showAccountHelp) {
                        Text("""
                        点「添加账号」在内置浏览器里登录；cookie 失效时点「重新登录」。
                        「自动续期登录」：打开 App 时，每个账号每天最多一次在内置浏览器里打开网站首页，让网站自己延长登录，再把最新的 cookie 同步到号池；发现掉线会在下载页提示。到期就必须重登的网站续不上。
                        「同步到号池」只是把内置浏览器里现有的 cookie 抄一份过去，不访问网站。
                        也可以从电脑导入 Netscape 格式的 cookies 文件：
                        opendevice afc push --app \(bundleID) 本地文件 /Documents/cookies/
                        或者放进「文件 → 我的 iPhone → 多功能媒体下载器 → cookies」，再点「重新读取」。
                        「导出全部账号」把所有账号的 cookie 存成一个文件，重装或换手机后用「从文件导入」放回来，内置浏览器里的登录状态也一起恢复；同名的账号会被换成文件里的。导出的文件等于登录凭证，不要发给别人。
                        不用的账号左滑删除。这里只显示名称和网站，不显示 cookie 内容。
                        """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    } label: {
                        Text("说明").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Label("账号", systemImage: "person.crop.circle.badge.checkmark")
                }

                Section {
                    if let version {
                        LabeledContent("yt-dlp", value: version.ytdlp + (version.updated ? "（已更新）" : "（内置）"))
                        LabeledContent("Python", value: version.python)
                    } else if !versionError.isEmpty {
                        Text(versionError).foregroundStyle(.red).font(.callout)
                    } else {
                        HStack { Text("正在读取版本…"); Spacer(); ProgressView() }
                    }
                    Button(updating ? "正在更新…" : "更新 yt-dlp 到最新版") {
                        Task { await run { try await YtDlp.updateToLatest() } }
                    }
                    .disabled(updating)
                    if version?.updated == true {
                        Button("恢复内置版本", role: .destructive) {
                            Task { await run { try await YtDlp.resetToBundled() } }
                        }
                        .disabled(updating)
                    }
                    if let gallery {
                        LabeledContent("gallery-dl", value: gallery.version + (gallery.updated ? "（已更新）" : "（内置）"))
                    } else if !galleryError.isEmpty {
                        Text(galleryError).foregroundStyle(.red).font(.callout)
                    }
                    Button(updatingGallery ? "正在更新…" : "更新 gallery-dl 到最新版") {
                        Task { await runGallery { try await YtDlp.updateGalleryToLatest() } }
                    }
                    .disabled(updatingGallery)
                    if gallery?.updated == true {
                        Button("恢复内置的 gallery-dl", role: .destructive) {
                            Task { await runGallery { try await YtDlp.resetGalleryToBundled() } }
                        }
                        .disabled(updatingGallery)
                    }
                } header: {
                    Label("下载器", systemImage: "shippingbox")
                } footer: {
                    Text("保存失败时先试试更新。")
                }

                Section {
                    LabeledContent("Bundle ID", value: bundleID)
                        .textSelection(.enabled)
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                } header: {
                    Label("关于", systemImage: "info.circle")
                }
            }
            .navigationTitle("设置")
            .confirmationDialog("清空下载记录？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("清空 \(historyCount) 条记录", role: .destructive) {
                    History.clear()
                    historyCount = History.count
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清空后，保存过的作品再存时不会再提醒。相册里已经保存的照片和视频不受影响。这一步不能撤销。")
            }
            .sheet(item: $loginAccount, onDismiss: { pool = CookiePool.summaries() }) { a in
                WebLoginView(account: a)
            }
            .sheet(isPresented: $showAdd) {
                AddAccountView { account in
                    showAdd = false
                    loginAccount = account
                }
            }
            .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json,
                          defaultFilename: "下载器账号_" + DateFormatter.fileStamp.string(from: Date())) { result in
                switch result {
                case .success: transferNote = "已导出。这个文件等于登录凭证，请自己保管。"
                case .failure(let error): transferNote = "导出失败：" + error.localizedDescription
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json, .plainText, .text]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    // 「文件」App 里选的文件要先申请访问
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        transferNote = try await web.importCookies(from: url)
                    } catch {
                        transferNote = "导入失败：" + error.localizedDescription
                    }
                    pool = CookiePool.summaries()
                    onlineResults = [:]
                }
            }
            .onAppear { openRequestedLogin() }
            .onChange(of: service.loginRequest) { _ in openRequestedLogin() }
            .task {
                pool = CookiePool.summaries()
                historyCount = History.count
                if version == nil { await run { try await YtDlp.version() } }
                if gallery == nil { await runGallery { try await YtDlp.galleryVersion() } }
            }
        }
    }

    /// 账号列表：先是 App 内登录的账号（连同它导出到号池的文件），再是号池里其余的文件（电脑导入的）
    private var rows: [AccountRow] {
        var out: [AccountRow] = []
        var used = Set<String>()
        for a in web.accounts {
            let file = pool.first { $0.name == a.cookieFileName }
            if file != nil { used.insert(a.cookieFileName) }
            out.append(AccountRow(id: a.id.uuidString, account: a, file: file))
        }
        for f in pool where !used.contains(f.name) {
            out.append(AccountRow(id: "file:" + f.name, account: nil, file: f))
        }
        return out
    }

    @ViewBuilder
    private func accountRow(_ row: AccountRow) -> some View {
        let online: Bool? = row.file.flatMap { onlineResults[$0.name] }
        let health: CookiePool.Health? = row.file?.health
        let neverLoggedIn = row.account != nil && row.account?.lastExport == nil
        let bad = neverLoggedIn || health?.needsLogin == true || online == false
        // 无法判断登录状态（没有内置检查规则的网站）：中性图标，不提示补登
        let unknown = !bad && online == nil && (health == nil || health == CookiePool.Health.unknown)
        let icon = bad ? "exclamationmark.triangle.fill" : unknown ? "questionmark.circle.fill" : "checkmark.seal.fill"
        let tint = bad ? Color.orange : unknown ? Color.secondary : Color.green
        let status: String = online == false ? "在线验证：已失效，需要补登"
            : neverLoggedIn ? "还没有登录"
            : (health?.text ?? "还没有导出 cookie")
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(row.title)
                Spacer()
                Text(row.sites).font(.caption).foregroundStyle(.secondary)
            }
            Text(row.source).font(.caption).foregroundStyle(.secondary)
            Text(status).font(.caption).foregroundStyle(bad ? Color.orange : Color.secondary)
            if online == true {
                Text("在线验证：小红书确认已登录").font(.caption).foregroundStyle(.green)
            }
            if let a = row.account {
                HStack {
                    Button(a.lastExport == nil ? "登录" : "重新登录") { loginAccount = a }
                    Spacer()
                    Button("同步到号池") {
                        Task {
                            await web.exportCookies(a)
                            pool = CookiePool.summaries()
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            } else if bad, let site = row.file?.sites.first {
                Button("用内置浏览器补登") {
                    let url = URL(string: "https://www.\(site)/")!
                    loginAccount = WebAccounts.shared.accountForLogin(url: url)
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
        .swipeActions {
            Button("删除", role: .destructive) {
                if let a = row.account {
                    // App 内登录的账号：登录状态和它在号池里的文件一起删
                    Task {
                        await web.remove(a)
                        pool = CookiePool.summaries()
                    }
                } else if let f = row.file {
                    try? FileManager.default.removeItem(at: f.file)
                    pool = CookiePool.summaries()
                }
            }
        }
    }

    /// 下载页保存失败、需要登录时，会切到这一页并请它打开那个网站的登录页
    private func openRequestedLogin() {
        guard let url = service.loginRequest else { return }
        service.loginRequest = nil
        loginAccount = WebAccounts.shared.accountForLogin(url: url)
    }

    private func runGallery(_ op: @escaping () async throws -> YtDlp.GalleryVersion) async {
        updatingGallery = true
        defer { updatingGallery = false }
        do {
            gallery = try await op()
            galleryError = ""
        } catch {
            galleryError = "gallery-dl：" + error.localizedDescription
        }
    }

    private func run(_ op: @escaping () async throws -> YtDlp.Version) async {
        updating = true
        defer { updating = false }
        do {
            version = try await op()
            versionError = ""
        } catch {
            versionError = error.localizedDescription
        }
    }
}

/// 设置页账号列表的一行：App 内登录的账号（file 是它导出到号池的文件，还没登录时为 nil），
/// 或者号池里一个电脑导入的文件（account 为 nil）
private struct AccountRow: Identifiable {
    let id: String
    let account: WebAccount?
    let file: CookiePool.Summary?

    var title: String { account?.name ?? file?.name ?? "" }
    var sites: String { account?.site ?? (file?.sites.joined(separator: "、") ?? "") }
    var source: String {
        guard let account else { return "电脑导入的文件" }
        guard let t = account.lastExport else { return "App 内登录" }
        return "App 内登录 · cookie 更新于 " + t.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 添加账号：选网站（或填登录网址），然后进入登录页
struct AddAccountView: View {
    var onCreate: (WebAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var custom = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("名称（可选）") {
                    TextField("例如：抖音主号、小红书小号", text: $name)
                }
                Section("选择网站") {
                    ForEach(SitePreset.all) { p in
                        Button(p.title) {
                            onCreate(WebAccounts.shared.add(name: name, preset: p))
                        }
                    }
                }
                Section("其它网站") {
                    TextField("登录页网址，例如 https://x.com/login", text: $custom)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("使用这个网址") {
                        let raw = custom.hasPrefix("http") ? custom : "https://" + custom
                        if let url = URL(string: raw), url.host != nil {
                            onCreate(WebAccounts.shared.add(name: name, url: url))
                        }
                    }
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("添加账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
}

/// 一行可编辑的命名模板（存进 UserDefaults）
struct LabeledTemplate: View {
    let title: String
    let placeholder: String
    @AppStorage private var value: String

    init(title: String, key: String, placeholder: String) {
        self.title = title
        self.placeholder = placeholder
        _value = AppStorage(wrappedValue: "", key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

/// 模板改动后实时预览三种格式
struct TemplatePreview: View {
    @AppStorage(Prefs.templateNormalKey) private var normal = ""
    @AppStorage(Prefs.templateDeletedKey) private var deleted = ""
    @AppStorage(Prefs.multiSeparatorKey) private var separator = ""

    var body: some View {
        // 读一下这三个值，让它们变化时重新渲染
        let _ = (normal, deleted, separator)
        VStack(alignment: .leading, spacing: 2) {
            Text("预览").font(.caption).foregroundStyle(.secondary)
            Text(Albums.compose(.normal, [Albums.Entry(platform: "小红书", name: "用户A", id: "idA")]))
            Text(Albums.compose(.normal, [Albums.Entry(platform: "抖音", name: "用户E1", id: "idE1"),
                                          Albums.Entry(platform: "微博", name: "用户E2", id: "idE2"),
                                          Albums.Entry(platform: "抖音", name: "", id: "idE3")]))
            Text(Albums.compose(.deleted, [Albums.Entry(platform: "快手", name: "用户F", id: "idF")]))
        }
        .font(.callout)
    }
}
