import SwiftUI
import WebKit

private func hidden(_ webView: WKWebView) -> some View {
    WebViewBox(webView: webView)
        .opacity(0.02)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
}

/// 根界面：下载 / 实况工具 / 设置。替代版本的确认弹窗挂在最外层，任何页面都能弹出
struct ContentView: View {
    @ObservedObject private var service = SaveService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $service.selectedTab) {
            DownloadView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(0)
            LiveToolsView()
                .tabItem { Label("实况工具", systemImage: "livephoto") }
                .tag(1)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(SaveService.settingsTab)
        }
        .alert(service.prompt?.title ?? "", isPresented: Binding(
            get: { service.prompt != nil },
            set: { if !$0, service.prompt != nil { service.answer(nil) } }
        ), presenting: service.prompt) { p in
            ForEach(Array(p.options.enumerated()), id: \.offset) { i, label in
                Button(label) { service.answer(i) }
            }
            Button(p.cancelLabel, role: .cancel) { service.answer(nil) }
        } message: { p in
            Text(p.message)
        }
        .sheet(item: $service.albumRequest) { req in
            AlbumChoiceView(request: req)
        }
        // 内置浏览器读取平时不显示；只有读不到、用户选了「打开页面」才弹出来
        .sheet(item: Binding(get: { service.captureShown ? service.capture : nil }, set: { _ in })) { cap in
            DouyinCaptureView(capture: cap)
        }
        .sheet(item: Binding(get: { service.captureShown ? service.webCapture : nil }, set: { _ in })) { cap in
            WebCaptureView(capture: cap)
        }
        .background {
            // 后台读取时，网页放在主界面底下：看不见、点不到，但页面会像正常打开一样运行
            if !service.captureShown {
                if let cap = service.capture { hidden(cap.webView) }
                if let cap = service.webCapture { hidden(cap.webView) }
            }
        }
        .sheet(item: $service.previewRequest) { req in
            PreviewView(request: req)
        }
        .onAppear { CookiePool.prepareFolder() }
        // 打开 App、从后台回来时，给到时间的账号续一次登录（每个账号每天最多一次）
        .task { await WebAccounts.shared.renewDue() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await WebAccounts.shared.renewDue() } }
        }
    }
}

struct DownloadView: View {
    @ObservedObject private var service = SaveService.shared
    @ObservedObject private var web = WebAccounts.shared
    @State private var text = ""
    @State private var showDetails = false
    @FocusState private var editing: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if !web.offline.isEmpty { offlineCard }
                    inputCard
                    actionButtons
                    if service.isRunning { cancelButton }
                    if !service.log.isEmpty { progressCard }
                    if !service.links.isEmpty {
                        Card { LinksSection(links: service.links) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .animation(.easeInOut(duration: 0.2), value: service.log.count)
        }
    }

    // 顶部：品牌图形 + 名称
    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.gradient)
                    .frame(width: 56, height: 56)
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.violet.opacity(0.35), radius: 10, y: 5)
            Text("多功能媒体下载器")
                .font(.title2.weight(.bold))
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    // 自动续期时发现掉线的账号：提示一下，可以直接去设置重新登录
    private var offlineCard: some View {
        Card {
            Label("账号已掉线", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(web.offline.map { "\($0.name)（\($0.site)）" }.joined(separator: "、"))
                .font(.callout)
                .accessibilityIdentifier("offline-accounts")
            HStack(spacing: 10) {
                Spacer()
                Button("知道了") { web.offline = [] }
                    .buttonStyle(ChipButtonStyle())
                Button("去重新登录") {
                    web.offline = []
                    service.selectedTab = SaveService.settingsTab
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
    }

    // 输入框 + 粘贴 / 清空（两个按钮挨在一起，靠右，右手拇指好按）
    private var inputCard: some View {
        Card {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("粘贴链接或分享文案")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: $text)
                    .focused($editing)
                    .frame(minHeight: 88, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("input")
            }
            HStack(spacing: 10) {
                Spacer()
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { text = s }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(.accentColor)
                Button {
                    text = ""
                } label: {
                    Label("清空", systemImage: "xmark")
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(text.isEmpty)
                .accessibilityIdentifier("clear")
            }
        }
    }

    private func start(_ mode: SaveMode) {
        editing = false
        let input = text
        Task { _ = try? await service.save(text: input, mode: mode) }
    }

    // 两个入口：「解析」先预览、勾选、选相册；「快速保存」直接把链接里的内容全部存下来
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                start(.organize)
            } label: {
                HStack(spacing: 8) {
                    if service.isRunning {
                        ProgressView().tint(.white)
                        Text("正在处理…")
                    } else {
                        Image(systemName: "sparkle.magnifyingglass")
                        Text("解析")
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("parse")
            if !service.isRunning {
                Button {
                    start(.quick)
                } label: {
                    Label("快速保存", systemImage: "bolt.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("quick-save")
            }
        }
        .disabled(service.isRunning || empty)
    }

    // 保存过程中随时可以停下（大视频下错了、弹窗卡住时用）
    private var cancelButton: some View {
        Button(role: .cancel) {
            service.cancel()
        } label: {
            Label("取消", systemImage: "xmark.circle")
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityIdentifier("cancel")
    }

    /// 步骤右边那一小段字：进行中的显示进度（3 / 9、37%…），结束的不显示（用时只记在「过程」里）
    private func note(for stage: SaveStage) -> String {
        guard stage.running else { return "" }
        switch service.phase {
        case .saving(let index, let total):
            let count = total > 1 ? "\(index) / \(total)" : ""
            if service.transfer.isEmpty { return count }
            return count.isEmpty ? service.transfer : count + " · " + service.transfer
        case .downloading:
            return service.transfer
        default:
            return ""
        }
    }

    /// 进度条走到哪了（0…1）；现在这一步没有可算的进度时是 nil
    private var fraction: Double? {
        // 「37%（12 / 30 MB）」开头的数字
        let percent = Double(service.transfer.prefix { $0.isNumber }).map { min(1, $0 / 100) }
        switch service.phase {
        case .saving(let index, let total):
            if total > 1 { return (Double(index - 1) + (percent ?? 0)) / Double(total) }
            return percent
        case .downloading:
            return percent
        default:
            return nil
        }
    }

    /// 给人看的一行里不放长网址：只留到域名
    private func brief(_ line: String) -> String {
        line.replacingOccurrences(of: #"(https?://[^/\s）)]+)[^\s）)]*"#, with: "$1/…", options: .regularExpression)
    }

    // 进度：走过的每一步（带进度和用时）+ 最近一条关键信息，其余收在「过程」里
    private var progressCard: some View {
        Card {
            // 给人看的是中文，给自动化操作读的是固定的英文代号（辅助功能的值）
            Text(service.phase.label)
                .font(.headline)
                .accessibilityIdentifier("phase")
                .accessibilityValue(service.phase.code)
            if !service.stages.isEmpty {
                let stopped = service.phase == .failed || service.phase == .cancelled
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(service.stages) { stage in
                        StageRow(stage: stage, note: note(for: stage),
                                 broken: stopped && stage.id == service.stages.last?.id)
                    }
                }
                .accessibilityIdentifier("stages")
            }
            if let value = fraction {
                ProgressView(value: value)
                    .tint(Theme.violet)
            }
            if let last = service.log.last {
                LogRow(line: brief(last), latest: true)
            }
            if service.isRunning, !service.latest.isEmpty, service.latest != service.log.last,
               !service.latest.hasPrefix("下载中") {
                // 现在在干什么：只占一行，不断被最新的一条替换（下载进度已经在上面的步骤里了）
                Text(brief(service.latest))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("latest")
            }
            if service.details.count > 1 {
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(service.details.suffix(200).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("过程")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("details")
            }
        }
    }
}

/// 步骤列表里的一行：状态图标 + 名称 + 右边的进度或用时
private struct StageRow: View {
    let stage: SaveStage
    let note: String
    /// 流程在这一步失败或被取消
    let broken: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if stage.running {
                    ProgressView().controlSize(.small)
                } else if broken {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .frame(width: 18)
            Text(stage.name)
                .font(.callout)
                .foregroundStyle(stage.running ? .primary : .secondary)
            Spacer(minLength: 8)
            Text(note)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 进度里的一行：按内容配图标和颜色
private struct LogRow: View {
    let line: String
    let latest: Bool

    private var style: (icon: String, color: Color, text: String) {
        if line.hasPrefix("✅") { return ("checkmark.circle.fill", .green, String(line.dropFirst(2))) }
        if line.hasPrefix("❌") { return ("xmark.octagon.fill", .red, String(line.dropFirst(2))) }
        if line.hasPrefix("⚠️") { return ("exclamationmark.triangle.fill", .orange, String(line.dropFirst(2))) }
        if line.hasPrefix("失败") || line.contains("失败：") { return ("exclamationmark.circle", .orange, line) }
        if line.hasPrefix("下载中") { return ("arrow.down.circle", .accentColor, line) }
        return ("circle.fill", Color(.tertiaryLabel), line)
    }

    var body: some View {
        let s = style
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: s.icon)
                .font(.system(size: s.icon == "circle.fill" ? 6 : 13))
                .foregroundStyle(s.color)
                .frame(width: 16)
            Text(s.text)
                .font(latest ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(latest ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 解析完后选相册。
/// - 每个账号一组：平台 / 用户名 / ID；可以继续添加其它平台或小号，没填的字段沿用上一组
/// - 相册名自动生成：同一平台的账号排在一起，账号之间用分隔符（默认 /）
/// - 任何一个账号的 ID 出现在已有相册名里就算匹配；确认后放入，能读懂旧名字时可以合并信息并重命名
struct AlbumChoiceView: View {
    let request: AlbumRequest
    @ObservedObject private var service = SaveService.shared

    @State private var entries: [Albums.Entry] = []
    @State private var style = Albums.Style.normal
    @State private var albumName = ""
    @State private var matches: [Albums.Match] = []
    @State private var confirming: Albums.Match?
    @State private var working = false
    /// 点过「重新查找」：没有结果时也要告诉用户查过了、查的是什么
    @State private var searched = false
    @State private var searchedTerms: [String] = []

    private var resolved: [Albums.Entry] { Albums.resolve(entries) }
    private var generated: String { Albums.compose(style, entries) }

    private func search() {
        let r = resolved
        matches = Albums.matches(ids: r.map(\.id) + request.author.ids, names: r.map(\.name))
        searchedTerms = (r.map(\.cleanID) + r.map(\.name)).filter { !$0.isEmpty }
        searched = true
    }

    /// 某个字段没填时，显示它会沿用的值
    private func inherited(_ index: Int, _ key: KeyPath<Albums.Entry, String>) -> String {
        guard index > 0 else { return "" }
        for e in entries[..<index].reversed() {
            let v = e[keyPath: key].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return ""
    }

    private func placeholder(_ label: String, _ index: Int, _ key: KeyPath<Albums.Entry, String>) -> String {
        let v = inherited(index, key)
        return v.isEmpty ? label : "\(label)（不填则同上：\(v)）"
    }

    var body: some View {
        NavigationStack {
            Form {
                // 每个账号一组，组与组之间分开
                ForEach($entries, id: \.uid) { $e in
                    let i = entries.firstIndex { $0.uid == e.uid } ?? 0
                    Section {
                        TextField(placeholder("平台", i, \.platform), text: $e.platform)
                        TextField(placeholder("用户名", i, \.name), text: $e.name)
                        TextField(i == 0 ? request.author.idLabel : "ID", text: $e.id)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        HStack {
                            Text(i == 0 ? "账号 1" : "账号 \(i + 1)")
                            Spacer()
                            if i > 0 {
                                Button(role: .destructive) {
                                    let uid = e.uid
                                    entries.removeAll { $0.uid == uid }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } footer: {
                        if i == 0, request.author.primaryID.isEmpty {
                            Text("没拿到\(request.author.idLabel)，请手动填写（作者主页能看到）。")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button {
                        entries.append(Albums.Entry(platform: "", name: "", id: ""))
                    } label: {
                        Label("添加平台或小号", systemImage: "plus.circle.fill")
                    }
                    Button {
                        search()
                    } label: {
                        Label("重新查找已有相册", systemImage: "magnifyingglass")
                    }
                }

                if !matches.isEmpty {
                    Section {
                        ForEach(matches, id: \.album.localIdentifier) { m in
                            Button {
                                confirming = m
                            } label: {
                                HStack {
                                    Text(m.title).foregroundStyle(.primary)
                                    Spacer()
                                    Text(m.byID ? "ID 匹配" : "仅用户名匹配")
                                        .font(.caption)
                                        .foregroundStyle(m.byID ? .green : .orange)
                                }
                            }
                        }
                    } header: {
                        Text("已有相册")
                    }
                } else if searched {
                    Section {
                        Label("没有找到匹配的相册", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("已有相册")
                    } footer: {
                        Text(searchedTerms.isEmpty ? "先在上面填 ID 或用户名。"
                             : "查找了：\(searchedTerms.joined(separator: "、"))")
                    }
                }

                Section {
                    Picker("格式", selection: $style) {
                        ForEach(Albums.Style.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("相册名", text: $albumName, axis: .vertical)
                    Button(matches.isEmpty ? "新建相册并放入" : "另建新相册并放入") {
                        service.decideAlbum(.create(albumName.trimmingCharacters(in: .whitespaces)))
                    }
                    .disabled(albumName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text(matches.isEmpty ? "新建相册" : "或者另建新相册")
                }

                Section {
                    Button("不放入相册") { service.decideAlbum(.none) }
                }
            }
            .navigationTitle("整理到相册")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(working)
            .onAppear {
                entries = [Albums.Entry(platform: request.platform, name: request.author.name,
                                        id: request.author.primaryID)]
                albumName = generated
                matches = request.matches
            }
            .onChange(of: generated) { albumName = $0 }
            .alert("放入这个相册？", isPresented: Binding(get: { confirming != nil },
                                                    set: { if !$0 { confirming = nil } }),
                   presenting: confirming) { m in
                Button("确认放入") { service.decideAlbum(.existing(m.album)) }
                if m.byID, let merged = Albums.mergedName(existing: m.title, adding: resolved) {
                    Button("合并信息后放入") {
                        working = true
                        Task {
                            try? await Albums.rename(m.album, to: merged)
                            service.decideAlbum(.existing(m.album))
                        }
                    }
                }
                Button("取消", role: .cancel) { confirming = nil }
            } message: { m in
                if m.byID, let merged = Albums.mergedName(existing: m.title, adding: resolved) {
                    Text("\(m.title)\n\n也可以把这次的账号信息合并进相册名，重命名为：\n\(merged)")
                } else {
                    Text(m.title)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
