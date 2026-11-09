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

/// 解析完后选相册：已有相册（名字里有作者 ID 的排前面）/ 按规则新建 / 不放入相册
struct AlbumChoiceView: View {
    let request: AlbumRequest
    @ObservedObject private var service = SaveService.shared
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("作者", value: request.author.name)
                    LabeledContent("\(request.platform) ID", value: request.author.primaryID)
                        .textSelection(.enabled)
                }
                if !request.matches.isEmpty {
                    Section {
                        ForEach(request.matches, id: \.album.localIdentifier) { m in
                            Button {
                                service.decideAlbum(.existing(m.album))
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
                        Text("放入已有相册")
                    } footer: {
                        Text("「仅昵称匹配」可能是同名的其他作者，请确认。")
                    }
                }
                Section {
                    TextField("相册名", text: $newName)
                    Button("新建并放入") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        service.decideAlbum(.create(name.isEmpty ? request.suggestedName : name))
                    }
                } header: {
                    Text(request.matches.isEmpty ? "没有找到这个作者的相册，新建一个" : "新建相册")
                } footer: {
                    Text("默认按「作者名字（平台名_作者ID）」命名，可以修改。")
                }
                Section {
                    Button("不放入相册，直接保存") { service.decideAlbum(.none) }
                }
            }
            .navigationTitle("放进哪个相册")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { newName = request.suggestedName }
        }
        .interactiveDismissDisabled()
    }
}
