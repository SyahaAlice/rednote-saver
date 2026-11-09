import ImageIO
import SwiftUI
import UIKit

/// 「解析」之后的预览：下载之前把这个作品里有什么列给用户看，
/// 勾选要保存的项、选视频清晰度，点「保存到相册」才开始下载（之后是选相册）。
struct PreviewRequest: Identifiable {
    let id = UUID()
    let platform: String
    let title: String
    let author: Author?
    let items: [NoteMedia]
    /// 加载缩略图时带的 Referer（和下载时相同）
    let referer: String
    /// 之前保存过的话，上次保存的时间
    let savedBefore: Date?
    /// 视频可选的清晰度（画面高度，从高到低）；少于两档就不显示选择
    let heights: [Int]
    /// 选中的项和清晰度对应的下载直链
    let links: (Set<Int>, Int) -> [String]
}

/// 用户在预览页的决定
struct PreviewChoice {
    /// 选中的项（items 的下标）
    var selection: Set<Int>
    /// 视频清晰度（画面高度），0 = 最高
    var height: Int
}

/// 预览用的缩略图：下载一张小图（没有小图就用原图），缩到几百像素再显示，不占太多内存
enum Thumbnails {
    static func load(_ url: URL, referer: String) async -> UIImage? {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(NoteParser.mobileUA, forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(result.0 as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 一项内容的小方块：缩略图（有的话）+ 类型角标 + 勾选标记
private struct PreviewTile: View {
    let item: NoteMedia
    let index: Int
    let referer: String
    let selected: Bool
    @State private var image: UIImage?
    @State private var loaded = false

    private var kindIcon: String {
        switch item.kind {
        case .image: return "photo"
        case .live: return "livephoto"
        case .video: return "video.fill"
        }
    }

    /// 缩略图地址：解析器给了小图就用小图；图片没有小图时用原图；视频没有封面就不加载
    private var thumbURL: URL? {
        if let p = item.preview { return p }
        if item.kind == .video { return nil }
        return item.original.first ?? item.fallback.first
    }

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if thumbURL != nil, !loaded {
                ProgressView()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: kindIcon).font(.title2)
                    Text("第 \(index + 1) 项").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            Image(systemName: kindIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.55), in: Circle())
                .padding(5)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.white)
                .background(Circle().fill(selected ? Color.white : Color.black.opacity(0.25)))
                .padding(5)
        }
        .opacity(selected ? 1 : 0.45)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task {
            guard let url = thumbURL, image == nil else {
                loaded = true
                return
            }
            image = await Thumbnails.load(url, referer: referer)
            loaded = true
        }
        .accessibilityLabel("第 \(index + 1) 项，\(selected ? "已选" : "未选")")
    }
}

/// 下载直链：平时收起，点开能看到每一条，点一下复制；「复制全部」一直在
struct LinksSection: View {
    let links: [String]
    @State private var open = false
    @State private var copied = ""

    var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        withAnimation { open.toggle() }
                    } label: {
                        Label("下载直链（\(links.count)）", systemImage: open ? "chevron.down" : "chevron.right")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("links")
                    Spacer()
                    Button(copied == "all" ? "已复制" : "复制全部") {
                        UIPasteboard.general.string = links.joined(separator: "\n")
                        copied = "all"
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("links-copy")
                }
                if open {
                    ForEach(Array(links.enumerated()), id: \.offset) { i, link in
                        Button {
                            UIPasteboard.general.string = link
                            copied = link
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(i + 1)").foregroundStyle(.secondary)
                                Text(link).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: copied == link ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption.monospaced())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct PreviewView: View {
    let request: PreviewRequest
    @ObservedObject private var service = SaveService.shared
    @State private var selection: Set<Int> = []
    /// 视频清晰度（画面高度），0 = 最高
    @State private var height = 0

    private var counts: String {
        var images = 0, lives = 0, videos = 0
        for i in request.items {
            switch i.kind {
            case .image: images += 1
            case .live: lives += 1
            case .video: videos += 1
            }
        }
        var parts: [String] = []
        if images > 0 { parts.append("\(images) 张图片") }
        if lives > 0 { parts.append("\(lives) 张实况") }
        if videos > 0 { parts.append("\(videos) 个视频") }
        return parts.joined(separator: " · ")
    }

    private var allSelected: Bool { selection.count == request.items.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.title.isEmpty ? "（没有标题）" : request.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text([request.author?.name ?? "", request.platform, counts]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let last = request.savedBefore {
                            Label("保存过：\(last.formatted(date: .abbreviated, time: .shortened))",
                                  systemImage: "clock.arrow.circlepath")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    if request.heights.count > 1 {
                        // 一次对这个链接里的所有视频生效；默认最高
                        HStack {
                            Text("视频清晰度").font(.subheadline)
                            Spacer()
                            Picker("视频清晰度", selection: $height) {
                                Text("最高（\(request.heights[0])p）").tag(0)
                                ForEach(Array(request.heights.dropFirst()), id: \.self) { h in
                                    Text("\(h)p").tag(h)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("preview-quality")
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(Array(request.items.enumerated()), id: \.offset) { index, item in
                            PreviewTile(item: item, index: index, referer: request.referer,
                                        selected: selection.contains(index))
                                .onTapGesture {
                                    if selection.contains(index) {
                                        selection.remove(index)
                                    } else {
                                        selection.insert(index)
                                    }
                                }
                        }
                    }
                    LinksSection(links: request.links(selection, height))
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    service.decidePreview(PreviewChoice(selection: selection, height: height))
                } label: {
                    Label(request.savedBefore == nil ? "保存到相册（\(selection.count) 项）"
                                                     : "再保存一次（\(selection.count) 项）",
                          systemImage: "square.and.arrow.down.fill")
                        .font(.title3.weight(.bold))
                        .padding(.vertical, 4)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selection.isEmpty)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
                .accessibilityIdentifier("preview-save")
            }
            .navigationTitle("预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { service.decidePreview(nil) }
                        .accessibilityIdentifier("preview-cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(allSelected ? "全不选" : "全选") {
                        selection = allSelected ? [] : Set(request.items.indices)
                    }
                }
            }
            .onAppear { selection = Set(request.items.indices) }
        }
        .interactiveDismissDisabled()
    }
}
