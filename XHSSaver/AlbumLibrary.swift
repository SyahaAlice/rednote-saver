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
        /// 系统给的数量（不用把相册内容查一遍）；系统一时给不出时是 nil，那一行就不显示数量
        var count: Int?
        /// 名字是按命名规则写的（能读回账号）
        var ruled: Bool
        /// 搜索用：名字去掉大小写、全角半角、空格的差别之后的样子（见 searchKey）
        var key: String

        var id: String { album.localIdentifier }
    }

    /// 用户自己建的全部相册，按名字排。在后台线程读：相册上千个时在主线程读会卡住界面。
    /// 这里不碰相册里的照片：数量用系统给的，封面由每一行显示出来时自己去取（见 cover(of:)）
    static func infos() async -> [Info] {
        await Task.detached(priority: .userInitiated) {
            covers.removeAllObjects()
            let reader = NameReader()
            let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            var out: [Info] = []
            out.reserveCapacity(all.count)
            all.enumerateObjects { c, _, _ in
                let title = c.localizedTitle ?? ""
                let n = c.estimatedAssetCount
                out.append(Info(album: c, title: title, count: n == NSNotFound ? nil : n,
                                ruled: reader.parse(title) != nil, key: searchKey(title)))
            }
            return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
    }

    /// 取过的封面先记着，列表来回滚动时不用重新查。每次重新读相册列表时清空
    private static let covers = NSCache<NSString, PHAsset>()

    /// 相册的封面：里面最后一项。在后台线程查
    static func cover(of album: PHAssetCollection) async -> PHAsset? {
        let id = album.localIdentifier as NSString
        if let hit = covers.object(forKey: id) { return hit }
        let found = await Task.detached(priority: .utility) {
            PHAsset.fetchAssets(in: album, options: nil).lastObject
        }.value
        if let found { covers.setObject(found, forKey: id) }
        return found
    }

    /// 相册内容变了（合并进了别的相册）：封面下次重新取
    static func forgetCover(of id: String) {
        covers.removeObject(forKey: id as NSString)
    }

    /// 重新问系统这个相册现在有多少项（只查这一个）
    static func count(of id: String) -> Int? {
        guard let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
              c.estimatedAssetCount != NSNotFound else { return nil }
        return c.estimatedAssetCount
    }

    /// 和这个相册名可能是同一个作者的相册：一边的名字按规则读出 ID、用户名，另一边的名字里也出现了。
    /// 「合并到…」「移到…」的列表把它们排在最前面，不用再搜
    static func related(to title: String, in infos: [Info]) async -> [Info] {
        await Task.detached(priority: .userInitiated) {
            let reader = NameReader()
            func keys(_ t: String) -> [String] {
                var out: [String] = []
                for e in reader.parse(t)?.entries ?? [] {
                    let id = e.cleanID, name = e.name.trimmingCharacters(in: .whitespaces)
                    if id.count >= 4 { out.append(id) }
                    if name.count >= 2 { out.append(name) }
                }
                return out
            }
            let mine = keys(title)
            return infos.filter { info in
                if mine.contains(where: { info.title.contains($0) }) { return true }
                return info.ruled && keys(info.title).contains { title.contains($0) }
            }
        }.value
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// 搜索时拿来比的样子：不分大小写、全角半角，去掉空格
    static func searchKey(_ title: String) -> String {
        fold(title).filter { !$0.isWhitespace }
    }

    /// 输入的搜索词：用空格隔开的几段，每一段都要出现
    static func queryParts(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 搜索用的比较：不分大小写、全角半角、不管空格；输入里用空格隔开的几段都要出现
    static func title(_ title: String, matches query: String) -> Bool {
        let t = searchKey(title)
        return queryParts(query).allSatisfy { t.contains($0) }
    }

    /// 可能是同一个作者的相册：按规则写的相册名里读出 ID 和用户名，别的相册名里也出现了就归成一组。
    /// 返回（共同的那段文字，这一组相册），只保留两个及以上的组
    static func duplicateGroups(_ infos: [Info]) async -> [(key: String, albums: [Info])] {
        await Task.detached(priority: .userInitiated) { findDuplicateGroups(infos) }.value
    }

    private static func findDuplicateGroups(_ infos: [Info]) -> [(key: String, albums: [Info])] {
        let reader = NameReader()
        var keys: [String] = []
        var known: Set<String> = []
        for info in infos where info.ruled {
            guard let parsed = reader.parse(info.title) else { continue }
            for e in parsed.entries {
                let id = e.cleanID
                let name = e.name.trimmingCharacters(in: .whitespaces)
                if id.count >= 4, known.insert(id).inserted { keys.append(id) }
                if name.count >= 2, known.insert(name).inserted { keys.append(name) }
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
    /// 没给封面时，这一行显示出来之后自己去取这个相册的封面（长列表用：只取看得见的那几行）
    var album: PHAssetCollection?
    @ViewBuilder var trailing: Trailing
    @State private var fetched: PHAsset?

    var body: some View {
        HStack(spacing: 12) {
            AssetThumb(asset: cover ?? fetched, side: 132)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .task(id: album?.localIdentifier) {
                    fetched = nil
                    if cover == nil, let album { fetched = await Albums.cover(of: album) }
                }
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
