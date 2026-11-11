import AVFoundation
import Photos
import SwiftUI
import UIKit

/// 「相册」页用的数据层：列出用户自己建的相册、搜索、找可能重复的，以及合并 / 移动 / 移出 / 删除。
/// 这里的操作都只动「相册」这层关系，不删照片本身；每一个都是用户在界面上点了才做
extension Albums {
    /// 列表里的一行
    struct Info: Identifiable {
        var album: PHAssetCollection
        var title: String
        var count: Int
        /// 名字是按命名规则写的（能读回账号）
        var ruled: Bool
        /// 封面用：相册里最新的一项
        var cover: PHAsset?

        var id: String { album.localIdentifier }
    }

    /// 用户自己建的全部相册，按名字排
    static func infos() -> [Info] {
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var out: [Info] = []
        all.enumerateObjects { c, _, _ in
            let assets = PHAsset.fetchAssets(in: c, options: nil)
            let title = c.localizedTitle ?? ""
            out.append(Info(album: c, title: title, count: assets.count, ruled: parse(title) != nil,
                            cover: assets.lastObject))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 搜索用的比较：不分大小写、全角半角、不管空格；输入里用空格隔开的几段都要出现
    static func title(_ title: String, matches query: String) -> Bool {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        }
        let t = fold(title).filter { !$0.isWhitespace }
        let parts = fold(query).split(whereSeparator: \.isWhitespace)
        return parts.allSatisfy { t.contains($0) }
    }

    /// 可能是同一个作者的相册：按规则写的相册名里读出 ID 和用户名，别的相册名里也出现了就归成一组。
    /// 返回（共同的那段文字，这一组相册），只保留两个及以上的组
    static func duplicateGroups(_ infos: [Info]) -> [(key: String, albums: [Info])] {
        var keys: [String] = []
        for info in infos {
            guard let parsed = parse(info.title) else { continue }
            for e in parsed.entries {
                let id = e.cleanID
                let name = e.name.trimmingCharacters(in: .whitespaces)
                if id.count >= 4, !keys.contains(id) { keys.append(id) }
                if name.count >= 2, !keys.contains(name) { keys.append(name) }
            }
        }
        var groups: [(key: String, albums: [Info])] = []
        var seen: Set<String> = []
        for key in keys {
            let hit = infos.filter { $0.title.contains(key) }
            guard hit.count >= 2 else { continue }
            // 同一批相册只列一次（ID 和用户名常常指向同一组）
            let signature = hit.map(\.id).sorted().joined(separator: "|")
            if seen.insert(signature).inserted { groups.append((key, hit)) }
        }
        return groups
    }

    static func assets(in album: PHAssetCollection) -> [PHAsset] {
        var out: [PHAsset] = []
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    /// 把这些照片也放进另一个相册（原来的相册里还在）
    static func add(_ assets: [PHAsset], to album: PHAssetCollection) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
        }
    }

    /// 把这些照片移出相册（照片本身还在图库里）
    static func remove(_ assets: [PHAsset], from album: PHAssetCollection) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
        }
    }

    /// 删除相册（只删相册，里面的照片还在图库里）
    static func delete(_ albums: [PHAssetCollection]) async throws {
        guard !albums.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray)
        }
    }

    /// 合并：把 sources 里的内容都放进 target，再删掉 sources。先放、放成功了才删，中途失败不会丢归类
    static func merge(_ sources: [PHAssetCollection], into target: PHAssetCollection) async throws {
        let others = sources.filter { $0.localIdentifier != target.localIdentifier }
        for s in others {
            try await add(assets(in: s), to: target)
        }
        try await delete(others)
    }

    /// 缩略图。side 是边长（像素）
    static func thumbnail(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat  // 只回调一次
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let done = Box<Bool>()
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                if done.value == true { return }
                done.value = true
                c.resume(returning: image)
            }
        }
    }

    static func playerItem(_ asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { (c: CheckedContinuation<AVPlayerItem?, Never>) in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            let done = Box<Bool>()
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                if done.value == true { return }
                done.value = true
                c.resume(returning: item)
            }
        }
    }
}

/// 一张缩略图：填满调用方给的框（框的大小、圆角由调用方定）
struct AssetThumb: View {
    let asset: PHAsset?
    var side: CGFloat = 240
    @State private var image: UIImage?

    var body: some View {
        Color(.tertiarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: asset?.localIdentifier) {
                image = nil
                if let asset { image = await Albums.thumbnail(asset, side: side) }
            }
    }
}

/// 相册列表里的一行：封面 + 名字 + 数量。右边放什么由调用方给
struct AlbumRow<Trailing: View>: View {
    let title: String
    let count: Int?
    let cover: PHAsset?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            AssetThumb(asset: cover, side: 132)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                if let count {
                    Text("\(count) 项").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// 底部的搜索框（放在页面底部，单手够得到）
struct BottomSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
