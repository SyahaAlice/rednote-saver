import Foundation

/// 原图 / 原片拿不到时，问用户要不要改用替代版本
struct FallbackPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let useLabel: String
}

enum FallbackChoice { case use, useForAll, skip }

/// 整个保存流程：
/// - 小红书：App 自己解析（支持实况照片），号池账号按 dl.py 的规则轮换
/// - 其它网站：内嵌的 yt-dlp 下载，音视频分开的用 AVFoundation 合并
@MainActor
final class SaveService: ObservableObject {
    static let shared = SaveService()

    @Published private(set) var isRunning = false
    @Published private(set) var log: [String] = []
    @Published var prompt: FallbackPrompt?

    private var promptContinuation: CheckedContinuation<FallbackChoice, Never>?
    private var useFallbackForAll = false

    func say(_ line: String) {
        log.append(line)
    }

    // MARK: - 替代版本确认

    private func ask(_ title: String, _ message: String, useLabel: String) async -> FallbackChoice {
        if useFallbackForAll { return .use }
        return await withCheckedContinuation { c in
            promptContinuation = c
            prompt = FallbackPrompt(title: title, message: message, useLabel: useLabel)
        }
    }

    func answer(_ choice: FallbackChoice) {
        if choice == .useForAll { useFallbackForAll = true }
        prompt = nil
        promptContinuation?.resume(returning: choice == .skip ? .skip : .use)
        promptContinuation = nil
    }

    // MARK: - 入口

    /// 返回一句结果摘要，例如「已保存 6 张实况照片」
    func save(text: String) async throws -> String {
        guard !isRunning else { throw XHSError("上一个还在保存，请稍等") }
        isRunning = true
        log = []
        useFallbackForAll = false
        defer { isRunning = false }

        do {
            guard let url = NoteParser.extractURL(text) else { throw XHSError("没找到链接") }
            try await PhotoSaver.ensureAccess()
            let summary: String
            if NoteParser.isXHS(url) {
                summary = try await saveXHS(url)
            } else {
                summary = try await saveWithYtDlp(url)
            }
            say("✅ " + summary)
            return summary
        } catch {
            say("❌ " + error.localizedDescription)
            throw error
        }
    }

    // MARK: - 小红书

    private func saveXHS(_ url: URL) async throws -> String {
        say("解析小红书链接…")
        var note: ParsedNote?
        var lastError: Error = XHSError("解析失败")
        for ck in CookiePool.candidates(for: url) {
            say("使用账号：\(ck?.lastPathComponent ?? "无（游客）")")
            do {
                note = try await NoteParser.parse(url: url, cookieFile: ck)
                break
            } catch {
                lastError = error
                say("失败：\(error.localizedDescription)")
            }
        }
        guard let note else { throw lastError }
        say("笔记：\(note.title.isEmpty ? note.id : note.title)（\(note.items.count) 项）")

        let dir = try LiveTools.workDir("note-\(note.id)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var images = 0, lives = 0, videos = 0, skipped = 0, failures = 0
        for (i, item) in note.items.enumerated() {
            let n = String(format: "%02d", i + 1)
            do {
                switch item.kind {
                case .video:
                    say("第 \(n) 项：下载视频…")
                    if try await saveXHSVideo(item, dir: dir, name: n) { videos += 1 } else { skipped += 1 }
                case .image:
                    say("第 \(n) 项：下载图片…")
                    if let file = try await downloadOriginal(item, dir: dir, name: n, what: "原图") {
                        try await PhotoSaver.saveImage(file)
                        images += 1
                    } else {
                        skipped += 1
                    }
                case .live:
                    say("第 \(n) 项：下载实况图…")
                    switch try await saveLive(item, dir: dir, name: n) {
                    case .live: lives += 1
                    case .still: images += 1
                    case .skipped: skipped += 1
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
        if parts.isEmpty && failures > 0 { throw XHSError("一项都没保存成功") }
        var summary = parts.isEmpty ? "没有保存任何内容" : "已保存 " + parts.joined(separator: "、")
        if skipped > 0 { summary += "，跳过 \(skipped) 项" }
        if failures > 0 { summary += "，\(failures) 项失败" }
        return summary
    }

    /// 先下原图/原片；失败时问用户是否改用网页版。返回 nil 表示用户选择跳过
    private func downloadOriginal(_ item: NoteMedia, dir: URL, name: String, what: String) async throws -> URL? {
        var originalError: Error?
        if !item.original.isEmpty {
            do {
                return try await Downloader.download(item.original, to: dir, name: name)
            } catch {
                originalError = error
                say("第 \(name) 项\(what)下载失败：\(error.localizedDescription)")
            }
        }
        guard !item.fallback.isEmpty else { throw originalError ?? XHSError("没有可用的下载地址") }
        let replacement = what == "原片" ? "网页版视频（压缩过，画质较低）" : "网页大图（压缩过，可能带水印）"
        let choice = await ask("第 \(name) 项拿不到\(what)",
                               "要改存\(replacement)吗？",
                               useLabel: "改存这一项")
        if choice == .skip {
            say("第 \(name) 项已跳过")
            return nil
        }
        say("第 \(name) 项改存替代版本")
        return try await Downloader.download(item.fallback, to: dir, name: "\(name)-fallback")
    }

    private func saveXHSVideo(_ item: NoteMedia, dir: URL, name: String) async throws -> Bool {
        guard let file = try await downloadOriginal(item, dir: dir, name: name, what: "原片") else { return false }
        try await saveVideoOrKeepFile(file, title: name)
        return true
    }

    private enum LiveOutcome { case live, still, skipped }

    /// 存成实况照片；任何一步失败都先问用户要不要只存静态图
    private func saveLive(_ item: NoteMedia, dir: URL, name: String) async throws -> LiveOutcome {
        guard let still = try await downloadOriginal(item, dir: dir, name: "\(name)", what: "原图") else {
            return .skipped
        }
        do {
            let clip = try await Downloader.download(item.liveVideoURLs, to: dir, name: "\(name)-clip")
            let id = UUID().uuidString
            let photo = try LivePhotoMaker.makeImage(from: still, in: dir, name: "\(name)-live", identifier: id)
            let video = try await LivePhotoMaker.makeVideo(from: clip, in: dir, name: "\(name)-live", identifier: id)
            try await PhotoSaver.saveLivePhoto(photo: photo, video: video)
            return .live
        } catch {
            say("第 \(name) 项实况合成失败：\(error.localizedDescription)")
            let choice = await ask("第 \(name) 项实况合成失败", "要只存这张的静态图吗？", useLabel: "只存静态图")
            if choice == .skip { return .skipped }
            try await PhotoSaver.saveImage(still)
            return .still
        }
    }

    // MARK: - 其它网站（yt-dlp）

    private func saveWithYtDlp(_ url: URL) async throws -> String {
        say("用 yt-dlp 下载：\(url.host ?? url.absoluteString)")
        let dir = try LiveTools.workDir("ytdlp")
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try await YtDlp.download(url: url, into: dir, cookies: CookiePool.candidates(for: url)) { line in
            SaveService.shared.say(line)
        }
        let title = result.title.isEmpty ? "视频" : result.title
        let file: URL
        if result.streams.count >= 2,
           let v = result.streams.first(where: { $0.hasVideo }),
           let a = result.streams.first(where: { $0.hasAudio && !$0.hasVideo }) {
            say("合并视频和音频…")
            file = dir.appendingPathComponent("merged.mp4")
            try await MediaMerger.merge(video: v.path, audio: a.path, to: file)
        } else {
            file = result.streams[0].path
        }
        let ext = file.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(ext) {
            try await PhotoSaver.saveImage(file)
            return "已保存图片：\(title)"
        }
        let kept = try await saveVideoOrKeepFile(file, title: title)
        return kept ? "已保存视频：\(title)" : "相册不支持这个格式，已存到「文件 → 小红书保存 → 下载」：\(title)"
    }

    /// 存进相册；相册不收的格式（比如 webm）改存到 App 的「下载」文件夹。返回是否进了相册
    @discardableResult
    private func saveVideoOrKeepFile(_ file: URL, title: String) async throws -> Bool {
        do {
            try await PhotoSaver.saveVideo(file)
            return true
        } catch {
            let out = CookiePool.documents.appendingPathComponent("下载", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let safe = title.replacingOccurrences(of: "/", with: "_").prefix(60)
            let dst = out.appendingPathComponent("\(DateFormatter.fileStamp.string(from: Date()))_\(safe).\(file.pathExtension)")
            try FileManager.default.copyItem(at: file, to: dst)
            say("相册没有接收（\(error.localizedDescription)），已存到「文件」App：\(dst.lastPathComponent)")
            return false
        }
    }
}
