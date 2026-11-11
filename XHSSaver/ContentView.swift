import Photos
import SwiftUI
import WebKit

private func hiddenWeb(_ webView: WKWebView) -> some View {
    WebViewBox(webView: webView)
        .opacity(0.02)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
}

/// 根界面：下载 / 相册 / 实况工具 / 设置。提问（底部弹出）挂在最外层，任何页面都能弹出
struct ContentView: View {
    @ObservedObject private var service = SaveService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $service.selectedTab) {
            DownloadView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(0)
            AlbumsView()
                .tabItem { Label("相册", systemImage: "rectangle.stack") }
                .tag(1)
            LiveToolsView()
                .tabItem { Label("实况工具", systemImage: "livephoto") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(SaveService.settingsTab)
        }
        // 提问从底部弹出（不用屏幕中间的弹窗）：按钮在拇指够得到的地方
        .confirmationDialog(service.prompt?.title ?? "", isPresented: Binding(
            get: { service.prompt != nil },
            set: { if !$0, service.prompt != nil { service.answer(nil) } }
        ), titleVisibility: .visible, presenting: service.prompt) { p in
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
    @State private var showAlbum = false
    @FocusState private var editing: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    // 输入框和按钮往下放一段，落在屏幕中间，单手够得到
                    Color.clear.frame(height: 84)
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
            .sheet(isPresented: $showAlbum) {
                if let album = service.savedAlbum {
                    NavigationStack { AlbumDetailView(album: album, showsDone: true) }
                }
            }
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
            if service.phase == .finished, service.savedAlbum != nil {
                Button {
                    showAlbum = true
                } label: {
                    Label("查看相册", systemImage: "rectangle.stack")
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityIdentifier("view-album")
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

/// 解析完后选相册。这一页只回答一个问题：放哪。
/// 上面一行是这次的作者（要改、要加小号点「改作者」）；中间是已有相册（自动找到的按可靠程度列出，
/// 完全匹配的默认选中；底部搜索框里输入文字就换成搜索结果）、新建相册、不放入相册；
/// 底部是搜索框和按钮：主按钮直接放入、不问改名，旁边的「改名…」是单独的入口
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
    /// 选中的已有相册（可能是搜出来的，清空搜索后也要留着）
    @State private var picked: Albums.Match?
    /// 正在给这个相册改名（从「改名…」进来的，不点不会出现）
    @State private var merging: Albums.Match?
    /// 新的相册名：先按规则生成一个，用户可以随便改
    @State private var mergedText = ""
    @State private var working = false
    @State private var editAuthor = false

    private var resolved: [Albums.Entry] { Albums.resolve(entries) }
    private var generated: String { Albums.compose(style, entries) }
    /// 账号信息变了就重新查找（把会影响查找的内容拼成能比较的文字）
    private var searchKey: [String] { resolved.map { $0.platform + "|" + $0.name + "|" + $0.cleanID } }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 列出来的相册：在搜索就是搜索结果；否则是自动找到的，加上之前搜出来选中的那个
    private var listed: [Albums.Match] {
        if searching { return found }
        var list = matches
        if let p = picked, !list.contains(where: { $0.album.localIdentifier == p.album.localIdentifier }) {
            list.append(p)
        }
        return list
    }

    private var chosen: Albums.Match? {
        guard case .existing = choice else { return nil }
        return picked
    }

    private func pick(_ m: Albums.Match) {
        picked = m
        choice = .existing(m.album.localIdentifier)
    }

    /// 按现在的账号重新查找
    private func refresh() {
        // 第一个账号用作者的全部 ID 去找（相册名里用的可能是其中任何一个）
        var all = resolved
        if let first = all.first {
            all += Albums.entries(platform: first.platform, author: request.author)
        }
        matches = Albums.matches(entries: all)
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

    private func radio(_ selected: Bool) -> some View {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
    }

    private var confirmTitle: String {
        switch choice {
        case .existing: return "放入「" + String((chosen?.title ?? "").prefix(10)) + "」"
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
            // 直接放入，不问改名：改名是另一个入口（旁边的「改名…」）
            guard let m = chosen else { return }
            service.decideAlbum(.existing(m.album))
        }
    }

    /// 打开改名页。名字里还没有这次的账号时，先按规则把账号加进去当初稿
    private func startRename(_ m: Albums.Match) {
        mergedText = Albums.mergedName(existing: m.title, adding: resolved) ?? m.title
        merging = m
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            BottomSearchField(placeholder: "搜索全部相册", text: $query)
                .accessibilityIdentifier("album-search")
            HStack(spacing: 10) {
                Button("改名…") {
                    if let m = chosen { startRename(m) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(width: 96)
                .disabled(chosen == nil)
                .accessibilityIdentifier("album-rename")
                Button(confirmTitle) { confirm() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("album-confirm")
            }
        }
        .disabled(working)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            if let first = resolved.first {
                                Text(first.platform + " · " + first.name)
                                Text(request.author.idLabel + "：" + (first.cleanID.isEmpty ? "没有拿到" : first.cleanID)
                                     + (resolved.count > 1 ? "，另外 \(resolved.count - 1) 个账号" : ""))
                                    .font(.footnote)
                                    .foregroundStyle(first.cleanID.isEmpty ? Color.orange : Color.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("改作者") { editAuthor = true }
                            .buttonStyle(ChipButtonStyle())
                    }
                }

                Section {
                    ForEach(listed, id: \.album.localIdentifier) { m in
                        Button {
                            pick(m)
                        } label: {
                            HStack(spacing: 10) {
                                radio(choice == .existing(m.album.localIdentifier))
                                AlbumMatchRow(match: m)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if listed.isEmpty {
                        Text(searching ? "没有找到" : "没有自动找到这个作者的相册，可以在底下搜索")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(searching ? "搜索结果" : "已有相册")
                }

                Section {
                    Button {
                        choice = .create
                    } label: {
                        HStack(spacing: 10) {
                            radio(choice == .create)
                            Text("新建相册")
                        }
                    }
                    .foregroundStyle(.primary)
                    if choice == .create {
                        TextField("相册名", text: $albumName, axis: .vertical)
                        Picker("格式", selection: $style) {
                            ForEach(Albums.Style.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Button {
                        choice = .none
                    } label: {
                        HStack(spacing: 10) {
                            radio(choice == .none)
                            Text("不放入相册")
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("或者")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("放进哪个相册")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(working)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .onAppear {
                entries = [Albums.Entry(platform: request.platform, name: request.author.name,
                                        id: request.author.primaryID)]
                albumName = generated
                matches = request.matches
                if let best = matches.first(where: { $0.level == .exact }) { pick(best) }
            }
            .onChange(of: generated) { albumName = $0 }
            .onChange(of: searchKey) { _ in refresh() }
            .onChange(of: query) { found = Albums.search($0) }
            .sheet(isPresented: $editAuthor) { authorSheet }
            .sheet(isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
                if let m = merging { mergeSheet(m) }
            }
        }
        .interactiveDismissDisabled()
    }

    /// 改这次的作者信息，或添加这个作者的其它账号（小号、别的平台）
    private var authorSheet: some View {
        NavigationStack {
            Form {
                ForEach($entries, id: \.uid) { $e in
                    let i = entries.firstIndex { $0.uid == e.uid } ?? 0
                    Section {
                        TextField(placeholder("平台", i, \.platform), text: $e.platform)
                        TextField(placeholder("用户名", i, \.name), text: $e.name)
                        TextField(i == 0 ? request.author.idLabel : "ID", text: $e.id)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if i > 0 {
                            Button("删除这个账号", role: .destructive) {
                                let uid = e.uid
                                entries.removeAll { $0.uid == uid }
                            }
                        }
                    } header: {
                        Text("账号 \(i + 1)")
                    }
                }
                Section {
                    Button {
                        entries.append(Albums.Entry(platform: "", name: "", id: ""))
                    } label: {
                        Label("添加账号", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("这次的作者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { editAuthor = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 给相册改名（顺便把这次的账号写进去）：规则只负责给一个初稿，名字最后由用户自己定
    /// （昵称的变体太多：加表情、加符号、前后加说明文字，规则判断不了哪些该留）
    private func mergeSheet(_ m: Albums.Match) -> some View {
        let name = mergedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("给相册改名").font(.headline)
                Spacer()
                Button("取消") { merging = nil }
            }
            Text("现在的名字：" + m.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("相册名", text: $mergedText, axis: .vertical)
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("album-merge-name")
            Text("可以随便改。名字里留着这次账号的「前缀 + ID」，以后这个账号就能自动对上这个相册。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("改名并放入") {
                working = true
                Task {
                    try? await Albums.rename(m.album, to: name)
                    service.decideAlbum(.existing(m.album))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(name.isEmpty || name == m.title || working)
            .accessibilityIdentifier("album-merge-confirm")
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }
}

/// 选相册页里的一行：封面、名字、数量，右边是匹配程度
private struct AlbumMatchRow: View {
    let match: Albums.Match
    @State private var count: Int?
    @State private var cover: PHAsset?

    var body: some View {
        AlbumRow(title: match.title, count: count, cover: cover) {
            Text(match.level.label)
                .font(.caption)
                .foregroundStyle(match.level == .exact ? Color.green
                                 : match.level == .manual ? Color.secondary : Color.orange)
        }
        .task(id: match.album.localIdentifier) {
            let assets = PHAsset.fetchAssets(in: match.album, options: nil)
            count = assets.count
            cover = assets.lastObject
        }
    }
}
