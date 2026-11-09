import Foundation
import Photos

/// 用 PhotoKit 写入相册（只申请「添加照片」权限，不读取你的相册）
enum PhotoSaver {
    static func ensureAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw XHSError("没有相册写入权限，请到「设置 → 隐私与安全性 → 照片 → 小红书保存」里允许添加照片")
        }
    }

    static func saveImage(_ file: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
        }
    }

    static func saveVideo(_ file: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
        }
    }

    /// 图片和视频作为同一个项目导入，就是一张实况照片
    static func saveLivePhoto(photo: URL, video: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, fileURL: photo, options: nil)
            req.addResource(with: .pairedVideo, fileURL: video, options: nil)
        }
    }
}
