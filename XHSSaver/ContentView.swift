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
                        Button("清空") { text = "" }
                            .disabled(text.isEmpty)
                    }
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

/// 解析完后选相册：
/// - 按作者 ID（小红书号 / 抖音号等）找已有相册，找到了确认后放入；也可以另建新相册
/// - 拿不到 ID 时手动填写，再重新查找
/// - 新相册默认按「作者名字（平台名_作者ID）」命名
struct AlbumChoiceView: View {
    let request: AlbumRequest
    @ObservedObject private var service = SaveService.shared
    @State private var authorID = ""
    @State private var matches: [Albums.Match] = []
    @State private var newName = ""
    @State private var confirming: Albums.Match?

    private var author: Author {
        var a = request.author
        let id = authorID.trimmingCharacters(in: .whitespaces)
        a.primaryID = id
        if !id.isEmpty, !a.ids.contains(id) { a.ids.insert(id, at: 0) }
        return a
    }

    private func refresh() {
        matches = Albums.matches(for: author)
        let id = authorID.trimmingCharacters(in: .whitespaces)
        newName = id.isEmpty ? "" : Albums.ruleName(platform: request.platform, author: author)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("作者", value: request.author.name)
                    TextField(request.author.idLabel, text: $authorID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(refresh)
                    Button("按这个\(request.author.idLabel)重新查找") { refresh() }
                        .disabled(authorID.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("作者")
                } footer: {
                    if request.author.primaryID.isEmpty {
                        Text("没拿到\(request.author.idLabel)，请手动填写（在作者主页能看到），填好后点「重新查找」。")
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
                                    Text(m.byID ? "ID 匹配" : "仅昵称匹配")
                                        .font(.caption)
                                        .foregroundStyle(m.byID ? .green : .orange)
                                }
                            }
                        }
                    } header: {
                        Text("已有相册")
                    } footer: {
                        Text("点一下确认后放入。「仅昵称匹配」可能是同名的其他作者。")
                    }
                }

                Section {
                    TextField("相册名", text: $newName)
                    Button(matches.isEmpty ? "新建并放入" : "另建新相册并放入") {
                        service.decideAlbum(.create(newName.trimmingCharacters(in: .whitespaces)))
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text(matches.isEmpty ? "没有找到这个作者的相册，新建一个" : "或者另建新相册")
                } footer: {
                    Text("默认按「作者名字（\(request.platform)_\(request.author.idLabel)）」命名，可以修改。")
                }

                Section {
                    Button("不放入相册，直接保存") { service.decideAlbum(.none) }
                }
            }
            .navigationTitle("放进哪个相册")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                authorID = request.author.primaryID
                refresh()
                if newName.isEmpty { newName = request.author.name }
            }
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
