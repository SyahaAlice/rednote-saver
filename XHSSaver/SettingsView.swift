import SwiftUI

struct SettingsView: View {
    @State private var accounts: [CookiePool.Summary] = []
    @State private var version: YtDlp.Version?
    @State private var versionError = ""
    @State private var updating = false

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "?" }

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("号池（cookies 文件夹）")
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
            .task {
                accounts = CookiePool.summaries()
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
