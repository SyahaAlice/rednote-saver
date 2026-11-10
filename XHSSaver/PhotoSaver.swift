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

/// 相册：三件分开的事——命名（按模板从账号生成名字）、匹配（已有相册和这次的作者对不对得上，分档）、
/// 存入（放进哪个，由 SaveService 和选相册页决定）。这里只管前两件
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

    /// 相册名里有没有按规则写的这个账号：完整的「前缀 + ID」，后面不能紧跟着别的字母数字
    /// （xhs_12345 不算匹配 xhs_123456）。太短的 ID 不算，容易误中
    static func mentions(_ title: String, _ e: Entry) -> Bool {
        let id = e.cleanID
        guard id.count >= 4, !e.prefix.isEmpty else { return false }
        var from = title.startIndex
        while let r = title.range(of: e.prefix + id, range: from..<title.endIndex) {
            if r.upperBound == title.endIndex { return true }
            let next = title[r.upperBound]
            if !(next.isLetter || next.isNumber || next == "_") { return true }
            from = r.upperBound
        }
        return false
    }

    /// 已有相册 + 这次的账号合并后的新名字；没有新增信息时返回 nil。
    /// 旧名字是按规则写的：把账号并进去重新生成。是手写的名字：原名保留，后面按规则接上这次的账号
    static func mergedName(existing title: String, adding entries: [Entry]) -> String? {
        if let old = parse(title) {
            let merged = resolve(old.entries + entries)
            guard merged.count > resolve(old.entries).count else { return nil }
            let name = compose(old.style, merged)
            return name == title ? nil : name
        }
        let add = resolve(entries).filter { !$0.cleanID.isEmpty && !mentions(title, $0) }
        guard !add.isEmpty else { return nil }
        return title + Prefs.multiSeparator + compose(.normal, add)
    }

    static func rename(_ album: PHAssetCollection, to title: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.title = title
        }
    }

    /// 一个已有相册和这次的作者对得上到什么程度
    struct Match {
        enum Level: Int {
            /// 相册名里有按规则写的这个账号（前缀 + ID）：确定就是它，快速保存会直接放入
            case exact
            /// 相册名里出现了这个 ID，但不是按规则写的：多半是，让用户自己定
            case id
            /// 只对上了用户名：昵称可能重名
            case name
            /// 用户自己搜出来的
            case manual

            var label: String {
                switch self {
                case .exact: return "完全匹配"
                case .id: return "含有这个 ID"
                case .name: return "仅用户名相同"
                case .manual: return "搜索到的"
                }
            }
        }

        var album: PHAssetCollection
        var title: String
        var level: Level
    }

    /// 这个作者的所有 ID 各算一个账号（相册名里用的可能是其中任何一个）
    static func entries(platform: String, author: Author) -> [Entry] {
        var ids: [String] = []
        for id in [author.primaryID] + author.ids where !id.isEmpty && !ids.contains(id) { ids.append(id) }
        if ids.isEmpty { return [Entry(platform: platform, name: author.name, id: "")] }
        return ids.map { Entry(platform: platform, name: author.name, id: $0) }
    }

    static func matches(platform: String, author: Author) -> [Match] {
        matches(entries: entries(platform: platform, author: author))
    }

    /// 在用户自己建的相册里找这些账号，按可靠程度排：完全匹配、含有 ID、仅用户名
    static func matches(entries: [Entry]) -> [Match] {
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        // 太短的 ID 容易误匹配
        let ids = Set(entries.map(\.cleanID).filter { $0.count >= 4 })
        let names = Set(entries.map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 })
        var found: [Match] = []
        all.enumerateObjects { c, _, _ in
            let t = c.localizedTitle ?? ""
            if entries.contains(where: { mentions(t, $0) }) {
                found.append(Match(album: c, title: t, level: .exact))
            } else if ids.contains(where: { t.contains($0) }) {
                found.append(Match(album: c, title: t, level: .id))
            } else if names.contains(where: { t.contains($0) }) {
                found.append(Match(album: c, title: t, level: .name))
            }
        }
        return found.sorted { $0.level.rawValue < $1.level.rawValue }
    }

    /// 用户自己输入文字搜相册名（不分大小写）
    static func search(_ text: String) -> [Match] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var found: [Match] = []
        all.enumerateObjects { c, _, _ in
            let t = c.localizedTitle ?? ""
            if t.localizedCaseInsensitiveContains(q) { found.append(Match(album: c, title: t, level: .manual)) }
        }
        return found
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
