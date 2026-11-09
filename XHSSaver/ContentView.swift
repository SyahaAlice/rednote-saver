import SwiftUI

/// 根界面：下载 / 实况工具 / 设置。替代版本的确认弹窗挂在最外层，任何页面都能弹出
struct ContentView: View {
    @ObservedObject private var service = SaveService.shared

    var body: some View {
        TabView {
            DownloadView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            LiveToolsView()
                .tabItem { Label("实况工具", systemImage: "livephoto") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
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
        .sheet(item: $service.capture) { cap in
            DouyinCaptureView(capture: cap)
        }
        .sheet(item: $service.loginAccount, onDismiss: { service.loginFinished() }) { a in
            WebLoginView(account: a)
        }
        .onAppear { CookiePool.prepareFolder() }
    }
}

struct DownloadView: View {
    @ObservedObject private var service = SaveService.shared
    @State private var text = ""
    @FocusState private var editing: Bool

    private var hasURL: Bool { NoteParser.extractURL(text) != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    inputCard
                    saveButton
                    if !service.log.isEmpty { progressCard }
                    featuresCard
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
            VStack(alignment: .leading, spacing: 3) {
                Text("多功能媒体下载器")
                    .font(.title2.weight(.bold))
                Text("小红书 · 抖音 · B 站 · 微博 · X · YouTube …")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    // 输入框 + 粘贴 / 补登 / 清空
    private var inputCard: some View {
        Card {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("粘贴链接或整段分享文案")
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
            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { text = s }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(.accentColor)
                Button {
                    let input = text
                    Task { await service.quickLogin(text: input) }
                } label: {
                    Label("补登", systemImage: "person.badge.key")
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(!hasURL || service.isRunning)
                Spacer()
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(text.isEmpty)
                .accessibilityLabel("清空")
            }
        }
    }

    private var saveButton: some View {
        Button {
            editing = false
            let input = text
            Task { _ = try? await service.save(text: input) }
        } label: {
            HStack(spacing: 8) {
                if service.isRunning {
                    ProgressView().tint(.white)
                    Text("正在保存…")
                } else {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("保存到相册")
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(service.isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("save")
    }

    // 进度：时间线样式，最新一行加粗
    private var progressCard: some View {
        Card {
            HStack {
                CardTitle(icon: "list.bullet.rectangle.portrait", text: "进度")
                Spacer()
                if service.isRunning { ProgressView().controlSize(.small) }
            }
            let lines = Array(service.log.suffix(60))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    LogRow(line: line, latest: i == lines.count - 1)
                }
            }
        }
    }

    private var featuresCard: some View {
        Card {
            CardTitle(icon: "sparkles", text: "能做什么")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    FeatureTag(icon: "photo", text: "原图 / 原片")
                    FeatureTag(icon: "livephoto", text: "实况照片")
                }
                HStack(spacing: 8) {
                    FeatureTag(icon: "rectangle.stack.badge.person.crop", text: "按作者归类相册")
                    FeatureTag(icon: "globe", text: "yt-dlp 千余网站")
                }
            }
            Text("原图拿不到时会先问你再改存替代版本；失败时可以直接在内置浏览器补登。也可以在快捷指令里用「下载到相册」，配合分享菜单一键保存。")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
        if line.hasPrefix("⚠️") { return ("exclamationmark.triangle.fill", .orange, String(line.dropFirst(3))) }
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

    private var resolved: [Albums.Entry] { Albums.resolve(entries) }
    private var generated: String { Albums.compose(style, entries) }

    private func search() {
        let r = resolved
        matches = Albums.matches(ids: r.map(\.id) + request.author.ids, names: r.map(\.name))
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
                        Label("按这些账号重新查找已有相册", systemImage: "magnifyingglass")
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
                    } footer: {
                        Text("任何一个账号的 ID 出现在相册名里就算匹配。点一下确认后放入；「仅用户名匹配」可能是同名的其他作者。")
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
                    Text(matches.isEmpty ? "没有找到这个作者的相册，新建一个" : "或者另建新相册")
                } footer: {
                    Text("相册名随上面的账号自动生成（同一平台的排在一起），也可以直接改。前缀和模板在「设置 → 相册命名」里改。")
                }

                Section {
                    Button("不放入相册，直接保存") { service.decideAlbum(.none) }
                }
            }
            .navigationTitle("放进哪个相册")
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
