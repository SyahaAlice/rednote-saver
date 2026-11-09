import Photos
import PhotosUI
import SwiftUI
import UIKit

struct LiveToolsView: View {
    var body: some View {
        NavigationStack {
            Form {
                VideoToLiveSection()
                LiveSplitSection()
                Section {
                    Text("小红书笔记里的实况图在「下载」页会自动存成实况照片，不需要在这里处理。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("实况工具")
        }
    }
}

// MARK: - 视频转实况

private struct VideoToLiveSection: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var video: URL?
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var length: Double = 3
    @State private var cover: Double = 1.5
    @State private var preview: UIImage?
    @State private var busy = false
    @State private var status = ""

    private var maxLength: Double { min(5, max(0.5, duration)) }

    var body: some View {
        Section {
            HStack {
                PhotosPicker("从相册选视频", selection: $pickerItem, matching: .videos)
                Spacer()
                Button("从「文件」选") { showFiles = true }
            }
            .buttonStyle(.borderless)

            if video != nil {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .frame(maxWidth: .infinity)
                }
                LabeledSlider(title: "开始", value: $start, range: 0...max(0.01, duration - length), unit: "秒") {
                    refreshPreview()
                }
                LabeledSlider(title: "时长", value: $length, range: 0.5...maxLength, unit: "秒") {
                    start = min(start, max(0, duration - length))
                    cover = min(cover, length)
                    refreshPreview()
                }
                LabeledSlider(title: "封面", value: $cover, range: 0...length, unit: "秒") {
                    refreshPreview()
                }
                Button {
                    Task { await make() }
                } label: {
                    HStack {
                        Text(busy ? "正在生成…" : "生成实况照片并存进相册")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy)
            }
            if !status.isEmpty {
                Text(status).font(.callout)
            }
        } header: {
            Text("视频转实况")
        } footer: {
            Text("截取视频里最长 5 秒的一段做成实况照片，封面可以选片段里的任意一帧。")
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task {
                status = "正在读取视频…"
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        status = "读不到这个视频"
                        return
                    }
                    await load(movie.url)
                } catch {
                    status = "读取失败：\(error.localizedDescription)"
                }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: dst)
                Task { await load(dst) }
            } catch {
                status = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    private func load(_ url: URL) async {
        do {
            let d = try await LiveTools.duration(of: url)
            guard d > 0.3 else { status = "视频太短"; return }
            video = url
            duration = d
            length = min(3, d)
            start = 0
            cover = length / 2
            status = String(format: "视频时长 %.1f 秒", d)
            refreshPreview()
        } catch {
            status = "读取失败：\(error.localizedDescription)"
        }
    }

    private func refreshPreview() {
        guard let video else { return }
        let t = start + cover
        Task {
            if let cg = try? await LiveTools.frame(of: video, at: t) { preview = UIImage(cgImage: cg) }
        }
    }

    private func make() async {
        guard let video else { return }
        busy = true
        defer { busy = false }
        status = "正在生成实况照片…"
        do {
            try await LiveTools.videoToLive(video, start: start, length: length, cover: cover)
            status = "✅ 已存进相册，长按照片就能播放"
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }
}

// MARK: - 实况拆分

private struct LiveSplitSection: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        Section {
            PhotosPicker(selection: $pickerItem, matching: .livePhotos) {
                HStack {
                    Text(busy ? "正在拆分…" : "选择一张实况照片拆分")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy)
            if !status.isEmpty {
                Text(status).font(.callout)
            }
        } header: {
            Text("实况拆分")
        } footer: {
            Text("把实况照片拆成一张静态照片和一段视频，分别存进相册，并在「文件 → 小红书保存 → 实况拆分」里各留一份。")
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task {
                busy = true
                defer { busy = false; pickerItem = nil }
                status = "正在拆分…"
                do {
                    guard let live = try await item.loadTransferable(type: PHLivePhoto.self) else {
                        status = "这张不是实况照片"
                        return
                    }
                    let r = try await LiveTools.split(live)
                    status = "✅ 已存进相册：\(r.photo)、\(r.video)"
                } catch {
                    status = "❌ \(error.localizedDescription)"
                }
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var onEnd: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f %@", value, unit)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if !editing { onEnd() }
            })
        }
    }
}
