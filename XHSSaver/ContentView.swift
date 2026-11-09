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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘贴链接或分享文案（小红书、B 站、抖音、微博等）", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("input")
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            if let s = strings.first { text = s }
                        }
                        Spacer()
                        Button("补登") {
                            let input = text
                            Task { await service.quickLogin(text: input) }
                        }
                        .disabled(NoteParser.extractURL(text) == nil || service.isRunning)
                        Button("清空") { text = "" }
                            .disabled(text.isEmpty)
                    }
                    .buttonStyle(.borderless)
                }

                Section {
                    Button {
                        let input = text
                        Task { _ = try? await service.save(text: input) }
                    } label: {
                        HStack {
                            Text(service.isRunning ? "正在保存…" : "保存到相册")
                            if service.isRunning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(service.isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save")
                }

                if !service.log.isEmpty {
                    Section("进度") {
                        ForEach(Array(service.log.suffix(80).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout)
                        }
                    }
                }

                Section {
                    Text("小红书：原图、原视频，实况图自动存成实况照片。原图拿不到时会先问你，再决定是否改存网页版。")
                    Text("其它网站：用内置的 yt-dlp 下载。也可以在快捷指令里用「保存小红书笔记」操作，配合分享菜单一键保存。")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("小红书保存")
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
