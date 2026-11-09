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
            throw XHSError("没有相册写入权限，请到「设置 → 隐私与安全性 → 照片 → 多功能媒体下载器」里允许添加照片")
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
    /// 相册命名格式（多个账号时自动按多账号格式拼接）
    enum Style: String, CaseIterable, Identifiable {
        case normal, deleted
        var id: String { rawValue }
        var title: String { self == .normal ? "常规" : "已注销 / 常删作品" }
        var template: String { self == .normal ? Prefs.templateNormal : Prefs.templateDeleted }
    }

    /// 一个账号：平台 + 用户名 + ID（前缀由平台决定，见「设置 → 相册命名」）
    struct Entry {
        /// 界面里区分每一组用（增删时不会错位）
        var uid = UUID()
        var platform: String
        var name: String
        var id: String

        var prefix: String { Prefs.idPrefix(for: platform) }
        /// 去掉首尾空格；「x_@」这类前缀自带 @，ID 里再有 @ 就去掉
        var cleanID: String {
            var i = id.trimmingCharacters(in: .whitespaces)
            if prefix.hasSuffix("@"), i.hasPrefix("@") { i.removeFirst() }
            return i
        }
    }

    /// 没填的字段沿用上一个账号；没有 ID 也没有用户名的组忽略；完全相同的去重
    static func resolve(_ raw: [Entry]) -> [Entry] {
        var out: [Entry] = []
        var last = Entry(platform: "", name: "", id: "")
        for r in raw {
            let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
            let e = Entry(platform: t(r.platform).isEmpty ? last.platform : t(r.platform),
                          name: t(r.name).isEmpty ? last.name : t(r.name),
                          id: t(r.id))
            last = e
            if e.id.isEmpty && e.name.isEmpty { continue }
            if e.id.isEmpty, out.contains(where: { $0.platform == e.platform && $0.name == e.name }) { continue }
            if !out.contains(where: { $0.platform == e.platform && $0.cleanID == e.cleanID && $0.name == e.name }) {
                out.append(e)
            }
        }
        return out
    }

    static func fill(_ template: String, _ e: Entry) -> String {
        template.replacingOccurrences(of: "{用户名}", with: e.name)
            .replacingOccurrences(of: "{前缀}", with: e.prefix)
            .replacingOccurrences(of: "{ID}", with: e.cleanID)
    }

    /// 生成相册名：同一平台的账号排在一起，账号之间用分隔符（默认 /）
    static func compose(_ style: Style, _ entries: [Entry]) -> String {
        let list = resolve(entries)
        var order: [String] = []
        for e in list where !order.contains(e.platform) { order.append(e.platform) }
        let grouped = order.flatMap { p in list.filter { $0.platform == p } }
        return grouped.map { fill(style.template, $0) }.joined(separator: Prefs.multiSeparator)
    }

    static func ruleName(platform: String, author: Author) -> String {
        compose(.normal, [Entry(platform: platform, name: author.name, id: author.primaryID)])
    }

    /// 按当前模板把已有相册名读回成账号列表；读不出来（手写的名字等）返回 nil
    static func parse(_ title: String) -> (style: Style, entries: [Entry])? {
        // 所有已知前缀 → 平台，长的优先（x_@ 要先于 x_）
        var table: [(String, String)] = []
        for p in Prefs.prefixPlatforms { table.append((Prefs.idPrefix(for: p), p)) }
        table.sort { $0.0.count > $1.0.count }

        func pattern(_ template: String) -> NSRegularExpression? {
            var t = NSRegularExpression.escapedPattern(for: template)
            t = t.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{用户名}"), with: "(.+?)")
            t = t.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{前缀}") +
                                       NSRegularExpression.escapedPattern(for: "{ID}"), with: "(.+?)")
            return try? NSRegularExpression(pattern: "^" + t + "$")
        }
        for style in Style.allCases {
            guard let re = pattern(style.template) else { continue }
            var entries: [Entry] = []
            var ok = true
            for part in title.components(separatedBy: Prefs.multiSeparator) {
                let ns = part as NSString
                guard let m = re.firstMatch(in: part, range: NSRange(location: 0, length: ns.length)),
                      m.numberOfRanges >= 3 else { ok = false; break }
                let name = ns.substring(with: m.range(at: 1))
                let tag = ns.substring(with: m.range(at: 2))
                guard let hit = table.first(where: { tag.hasPrefix($0.0) && !$0.0.isEmpty }) else {
                    ok = false; break
                }
                entries.append(Entry(platform: hit.1, name: name, id: String(tag.dropFirst(hit.0.count))))
            }
            if ok, !entries.isEmpty { return (style, entries) }
        }
        return nil
    }

    /// 已有相册 + 这次的账号合并后的新名字；没有新增信息或旧名字读不出来时返回 nil
    static func mergedName(existing title: String, adding entries: [Entry]) -> String? {
        guard let old = parse(title) else { return nil }
        let merged = resolve(old.entries + entries)
        guard merged.count > resolve(old.entries).count else { return nil }
        let name = compose(old.style, merged)
        return name == title ? nil : name
    }

    static func rename(_ album: PHAssetCollection, to title: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.title = title
        }
    }

    struct Match {
        var album: PHAssetCollection
        var title: String
        /// true = 相册名里有作者 ID（可靠）；false = 只匹配到昵称（昵称可能重名）
        var byID: Bool
    }

    static func matches(for author: Author) -> [Match] {
        matches(ids: author.ids + [author.primaryID], names: [author.name])
    }

    /// 在用户自己建的相册里找：名字包含任意一个账号的 ID 算匹配；只对上用户名的单独列出（可能重名）
    static func matches(ids rawIDs: [String], names rawNames: [String]) -> [Match] {
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        // 太短的 ID 容易误匹配；@ 开头的去掉 @ 再找（相册里可能写成 x_@id）
        let ids = Set(rawIDs.map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }.filter { $0.count >= 4 })
        let names = Set(rawNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 })
        var byID: [Match] = [], byName: [Match] = []
        all.enumerateObjects { c, _, _ in
            let t = c.localizedTitle ?? ""
            if ids.contains(where: { t.contains($0) }) {
                byID.append(Match(album: c, title: t, byID: true))
            } else if names.contains(where: { t.contains($0) }) {
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
