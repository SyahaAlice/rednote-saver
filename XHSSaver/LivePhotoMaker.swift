import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 把「一张图 + 一段视频」改造成相册认可的实况照片配对：
/// 图片写入 Apple MakerNote 的 content identifier（键 "17"），
/// 视频写入 QuickTime 的 com.apple.quicktime.content.identifier，并加一条 still-image-time 元数据轨道。
/// 两边的 identifier 相同，PhotoKit 才会把它们合成一张实况照片。
enum LivePhotoMaker {
    // MARK: - 图片

    /// 返回写好标记的新图片（尽量保持原格式，例如 HEIC；不支持写入的格式改存 JPEG）
    static func makeImage(from src: URL, in dir: URL, name: String, identifier: String) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let srcType = CGImageSourceGetType(source) else {
            throw XHSError("实况封面图读不出来")
        }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let outType: UTType
        // PNG 带不了 Apple MakerNote（配对标记），实况封面改存 HEIC
        if (srcType as String) == UTType.png.identifier {
            outType = writable.contains(UTType.heic.identifier) ? .heic : .jpeg
        } else if writable.contains(srcType as String), let t = UTType(srcType as String) {
            outType = t
        } else {
            outType = .jpeg
        }
        let dst = dir.appendingPathComponent(name)
            .appendingPathExtension(outType.preferredFilenameExtension ?? "jpg")
        try? FileManager.default.removeItem(at: dst)
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, outType.identifier as CFString, 1, nil) else {
            throw XHSError("无法创建实况封面图文件")
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var maker = (props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]) ?? [:]
        maker["17"] = identifier
        props[kCGImagePropertyMakerAppleDictionary] = maker
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XHSError("实况封面图写入失败") }
        return dst
    }

    /// 用一帧画面（例如视频截图）生成带配对标记的封面图，优先存 HEIC
    static func makeImage(from image: CGImage, in dir: URL, name: String, identifier: String) throws -> URL {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let type: UTType = writable.contains(UTType.heic.identifier) ? .heic : .jpeg
        let dst = dir.appendingPathComponent(name).appendingPathExtension(type.preferredFilenameExtension ?? "jpg")
        try? FileManager.default.removeItem(at: dst)
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, type.identifier as CFString, 1, nil) else {
            throw XHSError("无法创建实况封面图文件")
        }
        let props: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XHSError("实况封面图写入失败") }
        return dst
    }

    // MARK: - 视频

    /// 原样拷贝视频和音频数据（不重新编码），只加上配对用的元数据，输出 .mov。
    /// stillTime 是封面在视频里的时间点，不传就取中间那一帧
    static func makeVideo(from src: URL, in dir: URL, name: String, identifier: String,
                          stillTime: CMTime? = nil) async throws -> URL {
        let dst = dir.appendingPathComponent(name).appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: dst)

        let asset = AVURLAsset(url: src)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw XHSError("实况视频里没有画面轨道")
        }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)
        let transform = try await vTrack.load(.preferredTransform)
        let vFormat = try await vTrack.load(.formatDescriptions).first
        let fps = try await vTrack.load(.nominalFrameRate)

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        var aFormat: CMFormatDescription?
        if let aTrack {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) {
                reader.add(o)
                aOut = o
                aFormat = try await aTrack.load(.formatDescriptions).first
            }
        }

        let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
        // 除了配对 ID，再补上 iPhone 自己拍的实况视频里都有的两项（借鉴 makelive 等项目），
        // 让「循环播放」「长曝光」等效果更稳定
        writer.metadata = [contentIdentifierItem(identifier),
                           quickTimeItem("com.apple.quicktime.live-photo.auto", 1 as NSNumber,
                                         kCMMetadataBaseDataType_SInt8 as String),
                           quickTimeItem("com.apple.quicktime.live-photo.vitality-score", 1.0 as NSNumber,
                                         kCMMetadataBaseDataType_Float32 as String),
                           quickTimeItem("com.apple.quicktime.live-photo.vitality-scoring-version", 4 as NSNumber,
                                         kCMMetadataBaseDataType_SInt64 as String)]

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: aFormat)
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) {
                writer.add(i)
                aIn = i
            } else {
                aOut = nil
            }
        }

        let mIn = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                     sourceFormatHint: try stillImageTimeFormat())
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: mIn)
        writer.add(mIn)

        guard writer.startWriting() else {
            throw XHSError("实况视频写入失败：\(writer.error?.localizedDescription ?? "未知错误")")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw XHSError("实况视频读取失败：\(reader.error?.localizedDescription ?? "未知错误")")
        }
        writer.startSession(atSourceTime: .zero)

        // 封面对应视频中间那一帧
        let frame = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32((fps > 0 ? fps : 30).rounded()))))
        var still = stillTime ?? CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
        if still >= duration { still = CMTimeMultiplyByFloat64(duration, multiplier: 0.5) }
        adaptor.append(AVTimedMetadataGroup(items: [stillImageTimeItem()],
                                            timeRange: CMTimeRange(start: still, duration: frame)))
        mIn.markAsFinished()

        async let videoDone: Void = pump(vOut, into: vIn, label: "live.video")
        if let aOut, let aIn {
            await pump(aOut, into: aIn, label: "live.audio")
        }
        await videoDone

        if reader.status == .failed {
            writer.cancelWriting()
            throw XHSError("实况视频读取失败：\(reader.error?.localizedDescription ?? "未知错误")")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw XHSError("实况视频写入失败：\(writer.error?.localizedDescription ?? "未知错误")")
        }
        return dst
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        // markAsFinished 之后系统不会再调用这个回调，所以 resume 只会执行一次
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }

    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func quickTimeItem(_ key: String, _ value: NSNumber, _ type: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = value
        item.dataType = type
        return item
    }

    private static func stillImageTimeItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    private static func stillImageTimeFormat() throws -> CMFormatDescription {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String,
        ]
        var desc: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc)
        guard status == noErr, let desc else { throw XHSError("无法创建实况元数据轨道（\(status)）") }
        return desc
    }
}
