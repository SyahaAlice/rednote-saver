import Foundation

/// 下载文件到临时目录；按顺序尝试多个地址，第一个成功的就用
enum Downloader {
    static func download(_ urls: [URL], to dir: URL, name: String,
                         referer: String = "https://www.xiaohongshu.com/") async throws -> URL {
        var lastError: Error = XHSError("没有可用的下载地址")
        for url in urls {
            do {
                return try await download(url, to: dir, name: name, referer: referer)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func download(_ url: URL, to dir: URL, name: String,
                         referer: String = "https://www.xiaohongshu.com/") async throws -> URL {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue(NoteParser.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw XHSError("下载失败（HTTP \(code)）：\(url.absoluteString)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw XHSError("下载到的文件是空的：\(url.absoluteString)") }

        let ext = fileExtension(of: tmp, mime: http.mimeType)
        let dest = dir.appendingPathComponent(name).appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// 先看文件头，再看 Content-Type，决定扩展名（PhotoKit 要靠扩展名认格式）
    static func fileExtension(of file: URL, mime: String?) -> String {
        if let h = try? FileHandle(forReadingFrom: file) {
            defer { try? h.close() }
            let head = (try? h.read(upToCount: 16)) ?? Data()
            if head.count >= 12 {
                let brand = String(decoding: head[4..<12], as: UTF8.self)
                if ["ftypheic", "ftypheix", "ftypmif1", "ftypheim", "ftyphevc"].contains(brand) { return "heic" }
                if brand.hasPrefix("ftypqt") { return "mov" }
                if brand.hasPrefix("ftyp") { return "mp4" }
            }
            if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
            if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            if head.count >= 12, head[0..<4] == Data("RIFF".utf8), head[8..<12] == Data("WEBP".utf8) { return "webp" }
        }
        switch mime ?? "" {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "video/quicktime": return "mov"
        case let m where m.hasPrefix("video/"): return "mp4"
        default: return "bin"
        }
    }
}
