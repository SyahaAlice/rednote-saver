import Foundation

/// 整个保存流程：解析笔记 → 下载 → （实况图）写配对标记 → 存进相册
@MainActor
final class SaveService: ObservableObject {
    static let shared = SaveService()

    @Published private(set) var isRunning = false
    @Published private(set) var log: [String] = []

    private func say(_ line: String) {
        log.append(line)
    }

    /// 返回一句结果摘要，例如「已保存 6 张实况照片」
    func save(text: String) async throws -> String {
        guard !isRunning else { throw XHSError("上一篇还在保存，请稍等") }
        isRunning = true
        log = []
        defer { isRunning = false }

        do {
            let summary = try await run(text: text)
            say("✅ " + summary)
            return summary
        } catch {
            say("❌ " + error.localizedDescription)
            throw error
        }
    }

    private func run(text: String) async throws -> String {
        try await PhotoSaver.ensureAccess()

        say("解析链接…")
        let note = try await NoteParser.parse(text: text)
        let title = note.title.isEmpty ? note.id : note.title
        say("笔记：\(title)（\(note.items.count) 项）")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(note.id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var images = 0, lives = 0, videos = 0, failures = 0
        for (i, item) in note.items.enumerated() {
            let n = String(format: "%02d", i + 1)
            do {
                switch item.kind {
                case .video:
                    say("第 \(n) 项：下载视频…")
                    try await saveVideo(item.urls, dir: dir, name: n)
                    videos += 1
                case .image:
                    say("第 \(n) 项：下载图片…")
                    let file = try await Downloader.download(item.urls, to: dir, name: n)
                    try await PhotoSaver.saveImage(file)
                    images += 1
                case .live:
                    say("第 \(n) 项：下载实况图…")
                    if try await saveLive(item, dir: dir, name: n) {
                        lives += 1
                    } else {
                        images += 1
                    }
                }
            } catch {
                failures += 1
                say("第 \(n) 项失败：\(error.localizedDescription)")
            }
        }

        var parts: [String] = []
        if lives > 0 { parts.append("\(lives) 张实况照片") }
        if images > 0 { parts.append("\(images) 张图片") }
        if videos > 0 { parts.append("\(videos) 个视频") }
        if parts.isEmpty { throw XHSError("一项都没保存成功") }
        return "已保存 " + parts.joined(separator: "、") + (failures > 0 ? "，\(failures) 项失败" : "")
    }

    /// 原片优先；某个地址下载或入库失败就换下一个
    private func saveVideo(_ urls: [URL], dir: URL, name: String) async throws {
        var lastError: Error = XHSError("没有可用的视频地址")
        for (k, url) in urls.enumerated() {
            do {
                let file = try await Downloader.download(url, to: dir, name: "\(name)-\(k)")
                try await PhotoSaver.saveVideo(file)
                if k > 0 { say("（原片不可用，已改存网页版视频）") }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 存成实况照片；配对失败时退回只存静态图（返回 false）
    private func saveLive(_ item: NoteMedia, dir: URL, name: String) async throws -> Bool {
        let still = try await Downloader.download(item.urls, to: dir, name: "\(name)-still")
        do {
            let clip = try await Downloader.download(item.liveVideoURLs, to: dir, name: "\(name)-clip")
            let id = UUID().uuidString
            let photo = try LivePhotoMaker.makeImage(from: still, in: dir, name: "\(name)-live", identifier: id)
            let video = try await LivePhotoMaker.makeVideo(from: clip, in: dir, name: "\(name)-live", identifier: id)
            try await PhotoSaver.saveLivePhoto(photo: photo, video: video)
            return true
        } catch {
            say("第 \(name) 项实况合成失败（\(error.localizedDescription)），改存静态图")
            try await PhotoSaver.saveImage(still)
            return false
        }
    }
}
