import ImageIO
import SwiftUI
import UIKit

/// 「先提取，预览，然后下载」里的预览：解析完、下载之前，把这个作品里有什么列给用户看，
/// 用户勾选要保存的项后才开始下载。在「设置 → 保存 → 保存前预览」里可以关掉。
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

struct PreviewView: View {
    let request: PreviewRequest
    @ObservedObject private var service = SaveService.shared
    @State private var selection: Set<Int> = []

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
                            .lineLimit(3)
                        if let a = request.author {
                            Label(a.primaryID.isEmpty ? a.name : "\(a.name)（\(a.primaryID)）",
                                  systemImage: "person.crop.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(request.platform) · \(counts)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let last = request.savedBefore {
                            Label("这个作品保存过，上次是 \(last.formatted(date: .abbreviated, time: .shortened))",
                                  systemImage: "clock.arrow.circlepath")
                                .font(.footnote)
                                .foregroundStyle(.orange)
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
                    Text("点一下可以取消或重新勾选某一项。这里显示的是缩略图，保存的是原图 / 最高清晰度。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    service.decidePreview(selection)
                } label: {
                    Label(request.savedBefore == nil ? "保存 \(selection.count) 项" : "再保存一次（\(selection.count) 项）",
                          systemImage: "square.and.arrow.down.fill")
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
