import SwiftUI

struct SettingsView: View {
    @ObservedObject private var web = WebAccounts.shared
    @State private var loginAccount: WebAccount?
    @State private var showAdd = false
    /// 号池文件夹里的所有 cookies 文件（App 内登录导出的 + 电脑导入的）
    @State private var pool: [CookiePool.Summary] = []
    @AppStorage(Prefs.imageFormatKey) private var imageFormat = Prefs.ImageFormat.heic.rawValue
    @AppStorage(Prefs.usePublishDateKey) private var usePublishDate = false
    @AppStorage(Prefs.askAlbumKey) private var askAlbum = true
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

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "?" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("小红书图片格式", selection: $imageFormat) {
                        ForEach(Prefs.ImageFormat.allCases) { f in Text(f.title).tag(f.rawValue) }
                    }
                    Toggle("照片日期用作品发布时间", isOn: $usePublishDate)
                    Toggle("保存前选择相册", isOn: $askAlbum)
                    HStack {
                        Text("下载记录：\(historyCount) 条")
                        Spacer()
                        Button("清空", role: .destructive) { confirmClearHistory = true }
                            .disabled(historyCount == 0)
                    }
                } header: {
                    Label("保存", systemImage: "square.and.arrow.down")
                } footer: {
                    Text("""
                    图片格式：HEIC 是小红书原图本身，体积最小；JPEG / PNG 由小红书服务器从原图转换，分辨率不变。
                    选择相册需要「完整照片访问」权限（要读取已有相册名）：会按作者 ID 找已有相册，找不到就按「作者名字（平台名_作者ID）」新建。
                    下载记录只存平台和作品 ID，保存过的作品再存时会先问你。
                    """)
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
                } footer: {
                    Text("点开可以改每个平台的 ID 前缀和相册名模板。")
                }

                Section {
                    if rows.isEmpty {
                        Text("还没有账号：所有网站都以游客身份下载。抖音和 Instagram 帖子必须登录才能保存；其它网站登录后能拿到更多内容。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        accountRow(row)
                    }
                    Button("添加账号") { showAdd = true }
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
                } header: {
                    Label("账号", systemImage: "person.crop.circle.badge.checkmark")
                } footer: {
                    Text("""
                    这里是下载时会用到的所有账号（号池），两种来源放在一起：
                    · App 内登录：点「添加账号」在内置浏览器里登录，每个账号的登录状态互相独立；cookie 失效时点「重新登录」。
                    · 电脑导入：用 merge_cookies.py 整理好 Netscape 格式的 .txt，推到 App 的 cookies 文件夹：
                    opendevice afc push --app \(bundleID) 本地文件 /Documents/cookies/
                    也可以在「文件 → 我的 iPhone → 多功能媒体下载器 → cookies」里直接放进去，然后点「重新读取」。
                    只有失效或未激活的账号会提示补登。电脑导入的文件补登后会多出一个 App 内登录的账号，原来的文件还在，确认不用了可以左滑删除。只显示名称和网站，不显示 cookie 内容。
                    """)
                    .textSelection(.enabled)
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
                } header: {
                    Label("下载器", systemImage: "shippingbox")
                } footer: {
                    Text("其它网站用内置的 yt-dlp 下载。网站改版导致下载失败时，先点「更新」，会从 yt-dlp 官方 GitHub 下载最新版。")
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
            .task {
                pool = CookiePool.summaries()
                historyCount = History.count
                if version == nil { await run { try await YtDlp.version() } }
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
                    Button("刷新 cookie") {
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
