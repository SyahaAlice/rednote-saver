import Foundation
import Photos

/// 存进相册时的附加选项
struct SaveTarget {
    /// 照片日期（开关打开时用作品发布时间）
    var creationDate: Date?
    /// 要放入的相册
    var album: PHAssetCollection?
}

/// 用 PhotoKit 写入相册。默认只需要「添加照片」权限；相册归类需要「完整访问」（要读取已有相册名）
enum PhotoSaver {
    static func ensureAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw XHSError("没有相册写入权限，请到「设置 → 隐私与安全性 → 照片 → 小红书保存」里允许添加照片")
        }
    }

    /// 相册归类要能读到相册列表，需要「完整访问」
    static func hasFullAccess() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return status == .authorized
    }

    /// 返回新照片的 localIdentifier（有完整访问权限时可以回读检查）
    @discardableResult
    static func saveImage(_ file: URL, target: SaveTarget = SaveTarget()) async throws -> String? {
        try await create(target) { $0.addResource(with: .photo, fileURL: file, options: nil) }
    }

    @discardableResult
    static func saveVideo(_ file: URL, target: SaveTarget = SaveTarget()) async throws -> String? {
        try await create(target) { $0.addResource(with: .video, fileURL: file, options: nil) }
    }

    /// 图片和视频作为同一个项目导入，就是一张实况照片
    @discardableResult
    static func saveLivePhoto(photo: URL, video: URL, target: SaveTarget = SaveTarget()) async throws -> String? {
        try await create(target) {
            $0.addResource(with: .photo, fileURL: photo, options: nil)
            $0.addResource(with: .pairedVideo, fileURL: video, options: nil)
        }
    }

    private static func create(_ target: SaveTarget,
                               _ fill: @escaping (PHAssetCreationRequest) -> Void) async throws -> String? {
        let identifier = Box<String>()
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            fill(req)
            if let d = target.creationDate { req.creationDate = d }
            if let album = target.album, let placeholder = req.placeholderForCreatedAsset,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets([placeholder] as NSArray)
            }
            identifier.value = req.placeholderForCreatedAsset?.localIdentifier
        }
        return identifier.value
    }

    /// 回读确认存进去的确实是实况照片（需要完整访问权限，没有就返回 nil 表示无法检查）
    static func isLivePhoto(_ identifier: String) -> Bool? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        return asset.mediaSubtypes.contains(.photoLive)
    }
}

/// 相册：按作者匹配已有相册，或按规则新建「作者名字（平台名_作者ID）」
enum Albums {
    /// 相册命名格式
    enum Style: String, CaseIterable, Identifiable {
        case normal, multi, deleted
        var id: String { rawValue }
        var title: String {
            switch self {
            case .normal: return "常规"
            case .multi: return "多平台 / 多账号"
            case .deleted: return "已注销 / 常删作品"
            }
        }
    }

    /// 一个账号在相册名里的样子：用户名 + 前缀 + ID
    struct Entry {
        var name: String
        var prefix: String
        var id: String

        /// 「x_@」这类前缀自带 @，ID 里再有 @ 就去掉一个
        var tag: String {
            var i = id.trimmingCharacters(in: .whitespaces)
            if prefix.hasSuffix("@"), i.hasPrefix("@") { i.removeFirst() }
            return prefix + i
        }
    }

    /// 按模板填空：{用户名} {前缀} {ID}（模板在「设置 → 相册命名」里可改）
    static func fill(_ template: String, _ e: Entry) -> String {
        var id = e.id.trimmingCharacters(in: .whitespaces)
        if e.prefix.hasSuffix("@"), id.hasPrefix("@") { id.removeFirst() }
        return template.replacingOccurrences(of: "{用户名}", with: e.name)
            .replacingOccurrences(of: "{前缀}", with: e.prefix)
            .replacingOccurrences(of: "{ID}", with: id)
    }

    /// 常规：用户A（xhs_idA）；多平台：用户E1（平台1_idE1）/用户E2（平台2_idE2）；已注销：用户F【平台_idF】
    static func compose(_ style: Style, _ first: Entry, _ second: Entry?) -> String {
        switch style {
        case .normal:
            return fill(Prefs.templateNormal, first)
        case .deleted:
            return fill(Prefs.templateDeleted, first)
        case .multi:
            let a = fill(Prefs.templateNormal, first)
            guard let second, !(second.name.isEmpty && second.id.isEmpty) else { return a }
            return a + Prefs.multiSeparator + fill(Prefs.templateNormal, second)
        }
    }

    static func ruleName(platform: String, author: Author) -> String {
        compose(.normal, Entry(name: author.name, prefix: Prefs.idPrefix(for: platform), id: author.primaryID), nil)
    }

    struct Match {
        var album: PHAssetCollection
        var title: String
        /// true = 相册名里有作者 ID（可靠）；false = 只匹配到昵称（昵称可能重名）
        var byID: Bool
    }

    /// 在用户自己建的相册里找名字包含作者 ID（优先）或昵称的
    static func matches(for author: Author) -> [Match] {
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        // 太短的 ID 容易误匹配；@ 开头的去掉 @ 再找（相册里可能写成 x_@id）
        let ids = author.ids.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }.filter { $0.count >= 4 }
        let name = author.name.trimmingCharacters(in: .whitespaces)
        var byID: [Match] = [], byName: [Match] = []
        all.enumerateObjects { c, _, _ in
            let t = c.localizedTitle ?? ""
            if ids.contains(where: { t.contains($0) }) {
                byID.append(Match(album: c, title: t, byID: true))
            } else if name.count >= 2, t.contains(name) {
                byName.append(Match(album: c, title: t, byID: false))
            }
        }
        return byID + byName
    }

    static func create(_ title: String) async throws -> PHAssetCollection {
        let box = Box<String>()
        try await PHPhotoLibrary.shared().performChanges {
            box.value = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id = box.value, let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw XHSError("新建相册失败") }
        return album
    }
}

/// performChanges 的闭包里不能改外面的变量，用一个小盒子把结果带出来
final class Box<T>: @unchecked Sendable {
    var value: T?
}
