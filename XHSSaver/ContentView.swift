import SwiftUI
import WebKit

private func hiddenWeb(_ webView: WKWebView) -> some View {
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
                if let cap = service.capture { hiddenWeb(cap.webView) }
                if let cap = service.webCapture { hiddenWeb(cap.webView) }
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

/// 解析完后选相册。这一页从上到下只回答一个问题：放哪。
/// 1. 这次的作者（一行摘要；要改、要加小号再点开）
/// 2. 放进已有相册：自动找到的按可靠程度列出（完全匹配的默认选中），也可以自己输入文字搜
/// 3. 或者新建相册 / 不放入相册
/// 底下一个主按钮，文字跟着当前的选择变。
/// 放进一个名字里还没有这个账号的相册时，会问要不要把账号并进相册名（按小号规则）
struct AlbumChoiceView: View {
    let request: AlbumRequest
    @ObservedObject private var service = SaveService.shared

    private enum Choice: Equatable {
        case existing(String)  // 相册的 localIdentifier
        case create
        case none
    }

    @State private var entries: [Albums.Entry] = []
    @State private var style = Albums.Style.normal
    @State private var albumName = ""
    /// 按账号自动找到的相册
    @State private var matches: [Albums.Match] = []
    /// 用户自己搜出来的相册
    @State private var found: [Albums.Match] = []
    @State private var query = ""
    @State private var choice = Choice.create
    /// 正在问「要不要把账号并进相册名」
    @State private var merging: Albums.Match?
    /// 合并后的相册名：先按规则生成一个，用户可以随便改
    @State private var mergedText = ""
    @State private var working = false
    @State private var editAuthor = false

    private var resolved: [Albums.Entry] { Albums.resolve(entries) }
    private var generated: String { Albums.compose(style, entries) }
    /// 账号信息变了就重新查找（把会影响查找的内容拼成能比较的文字）
    private var searchKey: [String] { resolved.map { $0.platform + "|" + $0.name + "|" + $0.cleanID } }

    /// 列出来的相册：自动找到的在前，搜出来的在后（去掉重复的）
    private var listed: [Albums.Match] {
        matches + found.filter { f in !matches.contains { $0.album.localIdentifier == f.album.localIdentifier } }
    }

    private var chosen: Albums.Match? {
        guard case .existing(let id) = choice else { return nil }
        return listed.first { $0.album.localIdentifier == id }
    }

    /// 按现在的账号重新查找；有完全匹配的就默认选它
    private func refresh(selectBest: Bool) {
        // 第一个账号用作者的全部 ID 去找（相册名里用的可能是其中任何一个）
        var all = resolved
        if let first = all.first {
            all += Albums.entries(platform: first.platform, author: request.author)
        }
        matches = Albums.matches(entries: all)
        if selectBest, let best = matches.first(where: { $0.level == .exact }) {
            choice = .existing(best.album.localIdentifier)
        } else if case .existing = choice, chosen == nil {
            choice = .create
        }
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

    /// 一个可以点选的选项：左边是单选圆点，右边可以带一个小标签
    private func option(_ selected: Bool, _ title: String, badge: String = "", tint: Color = .secondary,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if !badge.isEmpty {
                    Text(badge).font(.caption).foregroundStyle(tint)
                }
            }
        }
    }

    private var confirmTitle: String {
        switch choice {
        case .existing: return "放入「" + String((chosen?.title ?? "").prefix(14)) + "」"
        case .create: return "新建相册并放入"
        case .none: return "不放相册，直接保存"
        }
    }

    private var canConfirm: Bool {
        switch choice {
        case .existing: return chosen != nil
        case .create: return !albumName.trimmingCharacters(in: .whitespaces).isEmpty
        case .none: return true
        }
    }

    private func confirm() {
        switch choice {
        case .none:
            service.decideAlbum(.none)
        case .create:
            service.decideAlbum(.create(albumName.trimmingCharacters(in: .whitespaces)))
        case .existing:
            guard let m = chosen else { return }
            // 相册名里还没有这次的账号：问要不要并进去；已经有了就直接放入
            if let suggestion = Albums.mergedName(existing: m.title, adding: resolved) {
                mergedText = suggestion
                merging = m
            } else {
                service.decideAlbum(.existing(m.album))
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let first = resolved.first {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(first.platform + " · " + first.name)
                            Text(request.author.idLabel + "：" + (first.cleanID.isEmpty ? "没有拿到" : first.cleanID))
                                .font(.footnote)
                                .foregroundStyle(first.cleanID.isEmpty ? Color.orange : Color.secondary)
                            if resolved.count > 1 {
                                Text("另外 \(resolved.count - 1) 个账号")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    DisclosureGroup("修改，或添加这个作者的其它账号", isExpanded: $editAuthor) {
                        ForEach($entries, id: \.uid) { $e in
                            let i = entries.firstIndex { $0.uid == e.uid } ?? 0
                            HStack {
                                Text("账号 \(i + 1)").font(.footnote).foregroundStyle(.secondary)
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
                            TextField(placeholder("平台", i, \.platform), text: $e.platform)
                            TextField(placeholder("用户名", i, \.name), text: $e.name)
                            TextField(i == 0 ? request.author.idLabel : "ID", text: $e.id)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            entries.append(Albums.Entry(platform: "", name: "", id: ""))
                        } label: {
                            Label("添加账号", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("这次的作者")
                }

                Section {
                    ForEach(listed, id: \.album.localIdentifier) { m in
                        option(choice == .existing(m.album.localIdentifier), m.title, badge: m.level.label,
                               tint: m.level == .exact ? .green : m.level == .manual ? .secondary : .orange) {
                            choice = .existing(m.album.localIdentifier)
                        }
                    }
                    if matches.isEmpty {
                        Text("没有自动找到这个作者的相册").foregroundStyle(.secondary)
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索相册名", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("album-search")
                    }
                } header: {
                    Text("放进已有相册")
                } footer: {
                    Text("知道是同一个作者、但名字对不上的相册，可以搜出来选它。")
                }

                Section {
                    option(choice == .create, "新建相册") { choice = .create }
                    if choice == .create {
                        TextField("相册名", text: $albumName, axis: .vertical)
                        Picker("格式", selection: $style) {
                            ForEach(Albums.Style.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    option(choice == .none, "不放入相册") { choice = .none }
                } header: {
                    Text("或者")
                }
            }
            .navigationTitle("整理到相册")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(working)
            .safeAreaInset(edge: .bottom) {
                Button(confirmTitle) { confirm() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canConfirm || working)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                    .accessibilityIdentifier("album-confirm")
            }
            .onAppear {
                entries = [Albums.Entry(platform: request.platform, name: request.author.name,
                                        id: request.author.primaryID)]
                albumName = generated
                matches = request.matches
                if let best = matches.first(where: { $0.level == .exact }) {
                    choice = .existing(best.album.localIdentifier)
                }
            }
            .onChange(of: generated) { albumName = $0 }
            .onChange(of: searchKey) { _ in refresh(selectBest: false) }
            .onChange(of: query) { found = Albums.search($0) }
            .sheet(isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
                if let m = merging { mergeSheet(m) }
            }
        }
        .interactiveDismissDisabled()
    }

    /// 把账号并进相册名：规则只负责给一个初稿，名字最后由用户自己定
    /// （昵称的变体太多：加表情、加符号、前后加说明文字，规则判断不了哪些该留）
    private func mergeSheet(_ m: Albums.Match) -> some View {
        let name = mergedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return NavigationStack {
            Form {
                Section {
                    Text(m.title)
                } header: {
                    Text("相册现在的名字")
                }
                Section {
                    TextField("相册名", text: $mergedText, axis: .vertical)
                        .accessibilityIdentifier("album-merge-name")
                    Button("恢复成现在的名字") { mergedText = m.title }
                        .font(.footnote)
                } header: {
                    Text("改成")
                } footer: {
                    Text("已经把这次的账号加进去了，可以随便改。只要名字里留着「前缀 + ID」这一段，以后这个账号就能自动对上这个相册。")
                }
                Section {
                    Button(name == m.title ? "放入（名字不变）" : "改名并放入") {
                        working = true
                        Task {
                            if name != m.title { try? await Albums.rename(m.album, to: name) }
                            service.decideAlbum(.existing(m.album))
                        }
                    }
                    .disabled(name.isEmpty || working)
                    .accessibilityIdentifier("album-merge-confirm")
                    Button("不改名，直接放入") { service.decideAlbum(.existing(m.album)) }
                        .disabled(working)
                }
            }
            .navigationTitle("把账号并进相册名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { merging = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
