import SwiftUI

struct SettingsView: View {
    @ObservedObject private var web = WebAccounts.shared
    @State private var loginAccount: WebAccount?
    @State private var showAdd = false
    @State private var accounts: [CookiePool.Summary] = []
    @AppStorage(Prefs.imageFormatKey) private var imageFormat = Prefs.ImageFormat.heic.rawValue
    @AppStorage(Prefs.usePublishDateKey) private var usePublishDate = false
    @AppStorage(Prefs.askAlbumKey) private var askAlbum = true
    @State private var historyCount = History.count
    @State private var prefixes = Prefs.albumPrefixes
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
                        Button("清空", role: .destructive) {
                            History.clear()
                            historyCount = History.count
                        }
                        .disabled(historyCount == 0)
                    }
                } header: {
                    Text("保存")
                } footer: {
                    Text("""
                    图片格式：HEIC 是小红书原图本身，体积最小；JPEG / PNG 由小红书服务器从原图转换，分辨率不变。
                    选择相册需要「完整照片访问」权限（要读取已有相册名）：会按作者 ID 找已有相册，找不到就按「作者名字（平台名_作者ID）」新建。
                    下载记录只存平台和作品 ID，保存过的作品再存时会先问你。
                    """)
                }

                Section {
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
                } header: {
                    Text("相册命名：ID 前缀")
                } footer: {
                    Text("常规格式：用户名（前缀ID），例如 用户A（xhs_idA）、用户B（x_@idB）、用户D（UID:idD）。没列出来的平台用「平台名_」。")
                }

                Section {
                    if web.accounts.isEmpty {
                        Text("还没有账号。抖音必须登录才能保存；其它网站登录后能拿到更多内容。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(web.accounts) { a in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(a.name)
                                Spacer()
                                Text(a.site).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(a.lastExport.map { "cookie 更新于 " + $0.formatted(date: .abbreviated, time: .shortened) }
                                 ?? "还没有登录")
                                .font(.caption)
                                .foregroundStyle(a.lastExport == nil ? .orange : .secondary)
                            HStack {
                                Button(a.lastExport == nil ? "登录" : "重新登录") { loginAccount = a }
                                Spacer()
                                Button("刷新 cookie") {
                                    Task {
                                        await web.exportCookies(a)
                                        accounts = CookiePool.summaries()
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                Task {
                                    await web.remove(a)
                                    accounts = CookiePool.summaries()
                                }
                            }
                        }
                    }
                    Button("添加账号") { showAdd = true }
                } header: {
                    Text("账号（在 App 内登录）")
                } footer: {
                    Text("每个账号有独立的登录状态，登录后 cookie 会自动写进号池。cookie 失效时点「重新登录」。左滑可删除账号。")
                }

                Section {
                    if accounts.isEmpty {
                        Text("号池是空的：所有网站都以游客身份下载。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(accounts) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(a.name)
                                Spacer()
                                Text(a.loggedIn ? "含登录凭证" : "未登录")
                                    .foregroundStyle(a.loggedIn ? .green : .orange)
                            }
                            Text(a.sites.joined(separator: "、"))
                                .font(.caption).foregroundStyle(.secondary)
                            if a.expired > 0 {
                                Text("有 \(a.expired) 条 cookie 已过期").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    Button("重新读取") { accounts = CookiePool.summaries() }
                } header: {
                    Text("号池（cookies 文件夹，含电脑导入的文件）")
                } footer: {
                    Text("""
                    在电脑上用 merge_cookies.py 整理好 Netscape 格式的 .txt，推到 App 的 cookies 文件夹：
                    opendevice afc push --app \(bundleID) --documents 本地文件 /cookies/
                    也可以在「文件 → 我的 iPhone → 小红书保存 → cookies」里直接放进去。只显示文件名和网站，不显示 cookie 内容。
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
                    Text("下载器")
                } footer: {
                    Text("其它网站用内置的 yt-dlp 下载。网站改版导致下载失败时，先点「更新」，会从 yt-dlp 官方 GitHub 下载最新版。")
                }

                Section("关于") {
                    LabeledContent("Bundle ID", value: bundleID)
                        .textSelection(.enabled)
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                }
            }
            .navigationTitle("设置")
            .sheet(item: $loginAccount, onDismiss: { accounts = CookiePool.summaries() }) { a in
                WebLoginView(account: a)
            }
            .sheet(isPresented: $showAdd) {
                AddAccountView { account in
                    showAdd = false
                    loginAccount = account
                }
            }
            .task {
                accounts = CookiePool.summaries()
                historyCount = History.count
                if version == nil { await run { try await YtDlp.version() } }
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
