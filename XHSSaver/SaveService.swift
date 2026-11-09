import Foundation
import Photos

/// 弹窗提问：options 是按钮文字，返回点了第几个；点「取消/跳过」返回 nil
struct ChoicePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let options: [String]
    let cancelLabel: String
}

/// 相册归类：解析完后让用户选放进哪个相册
struct AlbumRequest: Identifiable {
    let id = UUID()
    let platform: String
    let author: Author
    let suggestedName: String
    let matches: [Albums.Match]
}

enum AlbumDecision {
    case existing(PHAssetCollection)
    case create(String)
    case none
}

/// 整个保存流程：选解析器 → 解析 → 查重 → 日期/相册 → 下载保存 → 记录
@MainActor
final class SaveService: ObservableObject {
    static let shared = SaveService()

    @Published private(set) var isRunning = false
    @Published private(set) var log: [String] = []
    @Published var prompt: ChoicePrompt?
    @Published var albumRequest: AlbumRequest?
    /// 抖音读取作品时弹出的内置浏览器
    @Published var capture: DouyinCapture?

    private var promptContinuation: CheckedContinuation<Int?, Never>?
    private var albumContinuation: CheckedContinuation<AlbumDecision, Never>?
    private var useFallbackForAll = false
    private var referer = ""
    private var target = SaveTarget()

    func say(_ line: String) {
        log.append(line)
    }

    // MARK: - 提问

    func ask(_ title: String, _ message: String, options: [String], cancel: String = "跳过") async -> Int? {
        await withCheckedContinuation { c in
            promptContinuation = c
            prompt = ChoicePrompt(title: title, message: message, options: options, cancelLabel: cancel)
        }
    }

    func answer(_ index: Int?) {
        prompt = nil
        promptContinuation?.resume(returning: index)
        promptContinuation = nil
    }

    func decideAlbum(_ decision: AlbumDecision) {
        albumRequest = nil
        albumContinuation?.resume(returning: decision)
        albumContinuation = nil
    }

    /// 弹出抖音内置浏览器并等它读到作品数据
    func runCapture(_ cap: DouyinCapture) async throws -> [String: Any] {
        capture = cap
        defer { capture = nil }
        return try await cap.run()
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
            let note = try await Extractors.pick(for: url).extract(url, service: self)
            defer { if let d = note.workDir { try? FileManager.default.removeItem(at: d) } }
            let summary = try await save(note)
            say("✅ " + summary)
            return summary
        } catch {
            say("❌ " + error.localizedDescription)
            throw error
        }
    }

    private func save(_ note: ParsedNote) async throws -> String {
        let title = note.title.isEmpty ? note.id : String(note.title.prefix(40))
        say("\(note.platform)：\(title)（\(note.items.count) 项）")
        if let a = note.author { say("作者：\(a.name)（\(a.primaryID)）") }

        // 下载记录：保存过的先问一句
        if let last = History.savedDate(note.historyKey) {
            let when = last.formatted(date: .abbreviated, time: .shortened)
            if await ask("这个作品已经保存过", "上次保存于 \(when)。要再保存一次吗？",
                         options: ["再保存一次"], cancel: "不用了") == nil {
                return "已跳过（之前保存过）"
            }
        }

        target = SaveTarget()
        if Prefs.usePublishDate, let p = note.published {
            target.creationDate = p
            say("照片日期设为发布时间：\(p.formatted(date: .abbreviated, time: .shortened))")
        }
        if Prefs.askAlbum {
            target.album = try await chooseAlbum(for: note)
        }

        let summary = try await saveItems(note)
        History.record(note.historyKey)
        return summary
    }

    // MARK: - 相册归类

    private func chooseAlbum(for note: ParsedNote) async throws -> PHAssetCollection? {
        guard let author = note.author, !author.primaryID.isEmpty || !author.name.isEmpty else {
            say("拿不到作者信息，不做相册归类")
            return nil
        }
        guard await PhotoSaver.hasFullAccess() else {
            say("没有「完整照片访问」权限，读不到已有相册，这次不做相册归类（可在系统设置里改）")
            return nil
        }
        let request = AlbumRequest(platform: note.platform, author: author,
                                   suggestedName: Albums.ruleName(platform: note.platform, author: author),
                                   matches: Albums.matches(for: author))
        let decision = await withCheckedContinuation { (c: CheckedContinuation<AlbumDecision, Never>) in
            albumContinuation = c
            albumRequest = request
        }
        switch decision {
        case .existing(let album):
            say("放入相册：\(album.localizedTitle ?? "")")
            return album
        case .create(let name):
            let album = try await Albums.create(name)
            say("新建相册：\(name)")
            return album
        case .none:
            return nil
        }
    }

    // MARK: - 下载并存进相册

    private func saveItems(_ note: ParsedNote) async throws -> String {
        referer = note.referer
        let dir = try LiveTools.workDir("note-\(note.id)")
        defer { try? FileManager.default.removeItem(at: dir) }

        var images = 0, lives = 0, videos = 0, skipped = 0, failures = 0
        for (i, item) in note.items.enumerated() {
            let n = String(format: "%02d", i + 1)
            do {
                switch item.kind {
                case .video:
                    say("第 \(n) 项：\(item.localFile == nil ? "下载视频…" : "保存视频…")")
                    if let file = try await fileFor(item, dir: dir, name: n, what: "原片") {
                        try await saveVideoOrKeepFile(file, title: note.title.isEmpty ? note.id : note.title)
                        videos += 1
                    } else {
                        skipped += 1
                    }
                case .image:
                    say("第 \(n) 项：\(item.localFile == nil ? "下载图片…" : "保存图片…")")
                    if let file = try await fileFor(item, dir: dir, name: n, what: "原图") {
                        try await PhotoSaver.saveImage(file, target: target)
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
        if let album = target.album?.localizedTitle { summary += "（相册：\(album)）" }
        if skipped > 0 { summary += "，跳过 \(skipped) 项" }
        if failures > 0 { summary += "，\(failures) 项失败" }
        return summary
    }

    /// 已下载好的文件直接用；否则先下首选地址，失败时问用户是否改用替代版本。返回 nil 表示跳过
    private func fileFor(_ item: NoteMedia, dir: URL, name: String, what: String) async throws -> URL? {
        if let f = item.localFile { return f }
        var firstError: Error?
        if !item.original.isEmpty {
            do {
                return try await Downloader.download(item.original, to: dir, name: name, referer: referer)
            } catch {
                firstError = error
                say("第 \(name) 项\(what)下载失败：\(error.localizedDescription)")
            }
        }
        guard !item.fallback.isEmpty else { throw firstError ?? XHSError("没有可用的下载地址") }
        if !useFallbackForAll {
            let replacement = what == "原片" ? "较低清晰度的视频" : "替代版本（服务器转码的全尺寸 JPEG，不行再用网页压缩图）"
            switch await ask("第 \(name) 项拿不到\(what)", "要改存\(replacement)吗？",
                             options: ["改存这一项", "本次全部改存替代版本"]) {
            case nil:
                say("第 \(name) 项已跳过")
                return nil
            case 1?:
                useFallbackForAll = true
            default:
                break
            }
        }
        say("第 \(name) 项改存替代版本")
        return try await Downloader.download(item.fallback, to: dir, name: "\(name)-fallback", referer: referer)
    }

    private enum LiveOutcome { case live, still, skipped }

    /// 存成实况照片；任何一步失败都先问用户要不要只存静态图；存完回读确认确实是实况
    private func saveLive(_ item: NoteMedia, dir: URL, name: String) async throws -> LiveOutcome {
        guard let still = try await fileFor(item, dir: dir, name: name, what: "原图") else { return .skipped }
        do {
            let clip = try await Downloader.download(item.liveVideoURLs, to: dir, name: "\(name)-clip", referer: referer)
            let id = UUID().uuidString
            let photo = try LivePhotoMaker.makeImage(from: still, in: dir, name: "\(name)-live", identifier: id)
            let video = try await LivePhotoMaker.makeVideo(from: clip, in: dir, name: "\(name)-live", identifier: id)
            let saved = try await PhotoSaver.saveLivePhoto(photo: photo, video: video, target: target)
            if let saved, PhotoSaver.isLivePhoto(saved) == false {
                say("⚠️ 第 \(name) 项存进去了，但相册没有把它识别成实况照片")
            }
            return .live
        } catch {
            say("第 \(name) 项实况合成失败：\(error.localizedDescription)")
            if await ask("第 \(name) 项实况合成失败", "要只存这张的静态图吗？", options: ["只存静态图"]) == nil {
                return .skipped
            }
            try await PhotoSaver.saveImage(still, target: target)
            return .still
        }
    }

    /// 存进相册；相册不收的格式（比如 webm）改存到 App 的「下载」文件夹
    private func saveVideoOrKeepFile(_ file: URL, title: String) async throws {
        do {
            try await PhotoSaver.saveVideo(file, target: target)
        } catch {
            let out = CookiePool.documents.appendingPathComponent("下载", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let safe = title.replacingOccurrences(of: "/", with: "_").prefix(60)
            let dst = out.appendingPathComponent("\(DateFormatter.fileStamp.string(from: Date()))_\(safe).\(file.pathExtension)")
            try FileManager.default.copyItem(at: file, to: dst)
            say("相册没有接收（\(error.localizedDescription)），已存到「文件 → 小红书保存 → 下载」：\(dst.lastPathComponent)")
        }
    }
}
