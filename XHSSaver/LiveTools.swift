import AVFoundation
import Foundation
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 手动实况工具：视频转实况、实况拆分
enum LiveTools {
    static func workDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func duration(of video: URL) async throws -> Double {
        let d = try await AVURLAsset(url: video).load(.duration)
        return d.seconds.isFinite ? d.seconds : 0
    }

    /// 取视频某一时刻的画面（预览封面用，也用来生成实况封面）
    static func frame(of video: URL, at seconds: Double) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return try await gen.image(at: t).image
    }

    /// 视频转实况：截取 [start, start + length] 这一段（会重新编码，保证从任意位置开始都能播放），
    /// 封面取片段里 cover 秒处的画面，最后存成一张实况照片
    static func videoToLive(_ video: URL, start: Double, length: Double, cover: Double) async throws {
        try await PhotoSaver.ensureAccess()
        let dir = try workDir("v2l")
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = dir.appendingPathComponent("clip.mov")
        let asset = AVURLAsset(url: video)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw XHSError("这个视频无法处理")
        }
        export.outputURL = clip
        export.outputFileType = .mov
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            throw XHSError("截取视频失败：\(export.error?.localizedDescription ?? "未知错误")")
        }

        let id = UUID().uuidString
        let coverTime = min(max(0, cover), max(0, length - 0.05))
        let still = try await frame(of: clip, at: coverTime)
        let photo = try LivePhotoMaker.makeImage(from: still, in: dir, name: "live", identifier: id)
        let paired = try await LivePhotoMaker.makeVideo(from: clip, in: dir, name: "live", identifier: id,
                                                        stillTime: CMTime(seconds: coverTime, preferredTimescale: 600))
        try await PhotoSaver.saveLivePhoto(photo: photo, video: paired)
    }

    /// 实况拆分：把一张实况照片拆成静态照片 + 视频，各自存进相册，
    /// 同时在「文件 → 多功能媒体下载器 → 实况拆分」里留一份
    static func split(_ live: PHLivePhoto) async throws -> (photo: String, video: String) {
        try await PhotoSaver.ensureAccess()
        let resources = PHAssetResource.assetResources(for: live)
        guard let p = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first(where: { $0.type == .photo }),
              let v = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo }) else {
            throw XHSError("这张照片里找不到实况视频")
        }
        let out = CookiePool.documents.appendingPathComponent("实况拆分", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stamp = DateFormatter.fileStamp.string(from: Date())
        let photoURL = out.appendingPathComponent("\(stamp)_photo.\(ext(p.originalFilename, "heic"))")
        let videoURL = out.appendingPathComponent("\(stamp)_video.\(ext(v.originalFilename, "mov"))")
        try await write(p, to: photoURL)
        try await write(v, to: videoURL)
        // 存进相册用临时副本（PhotoKit 可能会移动文件）
        let dir = try workDir("split")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tp = dir.appendingPathComponent(photoURL.lastPathComponent)
        let tv = dir.appendingPathComponent(videoURL.lastPathComponent)
        try FileManager.default.copyItem(at: photoURL, to: tp)
        try FileManager.default.copyItem(at: videoURL, to: tv)
        try await PhotoSaver.saveImage(tp)
        try await PhotoSaver.saveVideo(tv)
        return (photoURL.lastPathComponent, videoURL.lastPathComponent)
    }

    private static func ext(_ filename: String, _ fallback: String) -> String {
        let e = (filename as NSString).pathExtension.lowercased()
        return e.isEmpty ? fallback : e
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}

/// 没有 ffmpeg：用 AVFoundation 把分开下载的视频流和音频流合成一个 mp4（不重新编码）
enum MediaMerger {
    static func merge(video: URL, audio: URL, to dst: URL) async throws {
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: video)
        let aa = AVURLAsset(url: audio)
        guard let vt = try await va.loadTracks(withMediaType: .video).first else { throw XHSError("视频流里没有画面") }
        let vDur = try await va.load(.duration)
        let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try cv?.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vt, at: .zero)
        cv?.preferredTransform = try await vt.load(.preferredTransform)
        if let at = try await aa.loadTracks(withMediaType: .audio).first {
            let aDur = try await aa.load(.duration)
            let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try ca?.insertTimeRange(CMTimeRange(start: .zero, duration: min(aDur, vDur)), of: at, at: .zero)
        }
        try? FileManager.default.removeItem(at: dst)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw XHSError("无法合并音视频")
        }
        export.outputURL = dst
        export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            throw XHSError("合并音视频失败：\(export.error?.localizedDescription ?? "未知错误")（可能是 iPhone 不支持的编码）")
        }
    }
}

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}

/// 从相册或「文件」选来的视频，先拷到临时目录再处理
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)").appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}
