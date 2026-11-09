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
    static func ruleName(platform: String, author: Author) -> String {
        "\(author.name)（\(platform)_\(author.primaryID)）"
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
        let ids = author.ids.filter { $0.count >= 4 }  // 太短的 ID 容易误匹配
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
