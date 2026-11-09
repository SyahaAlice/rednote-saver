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

/// 解析完后选相册。用户名、用户 ID 是两个可改的变量，按命名格式生成相册名：
/// - 常规：用户A（xhs_idA）    多平台 / 多账号：用户E1（平台1_idE1）/用户E2（平台2_idE2）
/// - 已注销 / 常删作品：用户F【平台_idF】
/// 先按 ID（再按用户名）找已有相册，找到了确认后放入；也可以另建新相册
struct AlbumChoiceView: View {
    let request: AlbumRequest
    @ObservedObject private var service = SaveService.shared

    @State private var name = ""
    @State private var userID = ""
    @State private var prefix = ""
    @State private var style = Albums.Style.normal
    @State private var name2 = ""
    @State private var prefix2 = ""
    @State private var userID2 = ""
    @State private var albumName = ""
    @State private var matches: [Albums.Match] = []
    @State private var confirming: Albums.Match?

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    private var generated: String {
        Albums.compose(style,
                       Albums.Entry(name: trimmed(name), prefix: prefix, id: trimmed(userID)),
                       style == .multi ? Albums.Entry(name: trimmed(name2), prefix: prefix2, id: trimmed(userID2)) : nil)
    }

    private func search() {
        var ids = request.author.ids
        for i in [trimmed(userID), trimmed(userID2)] where !i.isEmpty && !ids.contains(i) { ids.insert(i, at: 0) }
        matches = Albums.matches(for: Author(name: trimmed(name), primaryID: trimmed(userID), ids: ids))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $name)
                    TextField(request.author.idLabel, text: $userID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("按用户名和 ID 重新查找已有相册") { search() }
                } header: {
                    Text("\(request.platform) 作者")
                } footer: {
                    if request.author.primaryID.isEmpty {
                        Text("没拿到\(request.author.idLabel)，请手动填写（作者主页能看到），再点「重新查找」。")
                            .foregroundStyle(.orange)
                    }
                }

                if !matches.isEmpty {
                    Section {
                        ForEach(matches, id: \.album.localIdentifier) { m in
                            Button {
                                confirming = m
                            } label: {
                                HStack {
                                    Text(m.title)
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
                        Text("点一下确认后放入。「仅用户名匹配」可能是同名的其他作者。")
                    }
                }

                Section {
                    Picker("命名格式", selection: $style) {
                        ForEach(Albums.Style.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("ID 前缀（如 xhs_、x_@、ins_@、UID:）", text: $prefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if style == .multi {
                        TextField("第二个账号的用户名", text: $name2)
                        TextField("第二个账号的 ID 前缀", text: $prefix2)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("第二个账号的 ID", text: $userID2)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("相册名", text: $albumName)
                    Button(matches.isEmpty ? "新建相册并放入" : "另建新相册并放入") {
                        service.decideAlbum(.create(trimmed(albumName)))
                    }
                    .disabled(trimmed(albumName).isEmpty)
                } header: {
                    Text(matches.isEmpty ? "没有找到这个作者的相册，新建一个" : "或者另建新相册")
                } footer: {
                    Text("相册名会随上面的内容自动生成，最后也可以直接改。ID 前缀的默认值在「设置 → 相册命名」里改。")
                }

                Section {
                    Button("不放入相册，直接保存") { service.decideAlbum(.none) }
                }
            }
            .navigationTitle("放进哪个相册")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                name = request.author.name
                userID = request.author.primaryID
                prefix = Prefs.idPrefix(for: request.platform)
                prefix2 = prefix
                albumName = generated
                matches = request.matches
            }
            .onChange(of: generated) { albumName = $0 }
            .alert("放入这个相册？", isPresented: Binding(get: { confirming != nil },
                                                    set: { if !$0 { confirming = nil } }),
                   presenting: confirming) { m in
                Button("确认放入") { service.decideAlbum(.existing(m.album)) }
                Button("取消", role: .cancel) { confirming = nil }
            } message: { m in
                Text(m.title)
            }
        }
        .interactiveDismissDisabled()
    }
}
