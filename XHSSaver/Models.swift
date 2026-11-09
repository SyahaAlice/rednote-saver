import Foundation

/// 出错时给用户看的中文说明。kind 是给程序看的分类：流程按它决定下一步，不用去猜说明文字
struct XHSError: LocalizedError {
    enum Kind {
        /// 普通失败
        case other
        /// 用户取消：不再提问、不算失败
        case cancelled
        /// 需要登录：SaveService 会提示「登录后重试」
        case needsLogin
    }

    let message: String
    let kind: Kind
    init(_ message: String, kind: Kind = .other) {
        self.message = message
        self.kind = kind
    }
    var errorDescription: String? { message }

    static let cancelled = XHSError("已取消", kind: .cancelled)
}

/// 作品里的一个媒体项
struct NoteMedia {
    enum Kind { case image, live, video }
    var kind: Kind
    /// 首选地址（原图 / 原片 / 最高清晰度）
    var original: [URL]
    /// 首选失败时的替代地址，使用前要先征得用户同意
    var fallback: [URL]
    /// 实况图的动态视频地址（只有 kind == .live 时有）
    var liveVideoURLs: [URL] = []
    /// 已经下载好的本地文件（yt-dlp 下载的内容走这里，不再联网）
    var localFile: URL?
    /// 这一项在解析 / 下载阶段就已经失败（yt-dlp 多项帖子里的某一项）：保存时直接算作失败并显示这句说明
    var error: String?
}

/// 作者信息：昵称可能重复，ID 通常唯一。ids 里放这个平台上所有能用来识别作者的 ID
struct Author {
    var name: String
    /// 起相册名时用的 ID（用户在平台上看得到的那个）
    var primaryID: String
    /// 匹配已有相册时用的所有 ID
    var ids: [String]
    /// 起相册名时 ID 的叫法，例如「小红书号」「抖音号」
    var idLabel: String = "作者 ID"
}

/// 任何网站解析出来的统一结果
struct ParsedNote {
    var platform: String          // 显示用的平台名，例如「小红书」「抖音」
    var id: String
    var title: String
    var items: [NoteMedia]
    var author: Author?
    var published: Date?
    /// 下载时带的 Referer
    var referer: String = "https://www.xiaohongshu.com/"
    /// 解析器自己建的临时目录（yt-dlp 下载的文件在这里），保存完删除
    var workDir: URL?
    /// 还没下载的作品（yt-dlp）：解析时只拿到标题、作者等信息，
    /// 查重和选相册之后才调用它真正下载，返回的媒体项替换 items
    var fetch: (@MainActor () async throws -> [NoteMedia])?

    var historyKey: String { "\(platform):\(id)" }
}

/// 用户设置（UserDefaults）
enum Prefs {
    enum ImageFormat: String, CaseIterable, Identifiable {
        case heic, jpeg, png
        var id: String { rawValue }
        var title: String {
            switch self {
            case .heic: return "HEIC 原图（体积最小）"
            case .jpeg: return "JPEG（全尺寸）"
            case .png: return "PNG（无损，体积大）"
            }
        }
    }

    static let imageFormatKey = "imageFormat"
    static let usePublishDateKey = "usePublishDate"
    static let askAlbumKey = "askAlbum"
    static let albumPrefixesKey = "albumPrefixes"

    /// 相册名里 ID 前面的写法（按用户习惯：小红书 xhs_、X x_@、Instagram ins_@、B 站 UID:）
    static let defaultPrefixes: [String: String] = [
        "小红书": "xhs_", "抖音": "dy_", "微博": "wb_", "快手": "ks_",
        "X": "x_@", "Instagram": "ins_@", "哔哩哔哩": "UID:",
    ]
    /// 设置页里列出来可以改前缀的平台（另外加上用户自己添加过的）
    static let builtinPlatforms = ["小红书", "抖音", "快手", "微博", "哔哩哔哩", "X", "Instagram"]
    static var prefixPlatforms: [String] {
        builtinPlatforms + albumPrefixes.keys.filter { !builtinPlatforms.contains($0) }.sorted()
    }

    // 相册命名模板：{用户名} {前缀} {ID}
    static let templateNormalKey = "albumTemplateNormal"
    static let templateDeletedKey = "albumTemplateDeleted"
    static let multiSeparatorKey = "albumMultiSeparator"
    static let defaultTemplateNormal = "{用户名}（{前缀}{ID}）"
    static let defaultTemplateDeleted = "{用户名}【{前缀}{ID}】"
    static let defaultMultiSeparator = "/"
    static var templateNormal: String { nonEmpty(templateNormalKey) ?? defaultTemplateNormal }
    static var templateDeleted: String { nonEmpty(templateDeletedKey) ?? defaultTemplateDeleted }
    static var multiSeparator: String { nonEmpty(multiSeparatorKey) ?? defaultMultiSeparator }
    private static func nonEmpty(_ key: String) -> String? {
        guard let s = UserDefaults.standard.string(forKey: key), !s.isEmpty else { return nil }
        return s
    }

    /// 没设置过的平台：中文名取小写拼音首字母（西瓜视频 → xgsp_），英文名取小写全名
    static func autoPrefix(for platform: String) -> String {
        if platform.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return platform.lowercased().replacingOccurrences(of: " ", with: "") + "_"
        }
        let m = NSMutableString(string: platform) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let initials = (m as String).split(separator: " ").compactMap { $0.first.map { String($0).lowercased() } }
        return initials.joined() + "_"
    }

    static var albumPrefixes: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: albumPrefixesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: albumPrefixesKey) }
    }

    /// 没设置过的平台用「平台名_」
    static func idPrefix(for platform: String) -> String {
        albumPrefixes[platform] ?? defaultPrefixes[platform] ?? autoPrefix(for: platform)
    }

    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: UserDefaults.standard.string(forKey: imageFormatKey) ?? "") ?? .heic
    }
    static var usePublishDate: Bool { UserDefaults.standard.bool(forKey: usePublishDateKey) }

    /// B 站视频的封面怎么处理
    enum BiliCover: String, CaseIterable, Identifiable {
        case withVideo, only, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .withVideo: return "和视频一起保存"
            case .only: return "只保存封面"
            case .off: return "不保存"
            }
        }
    }
    static let biliCoverKey = "biliCover"
    /// 默认和视频一起保存
    static var biliCover: BiliCover {
        BiliCover(rawValue: UserDefaults.standard.string(forKey: biliCoverKey) ?? "") ?? .withVideo
    }

    /// yt-dlp 下载视频的清晰度上限（画面高度）；0 = 不限，取网站给的最高清晰度（默认）
    static let maxVideoHeightKey = "maxVideoHeight"
    struct HeightChoice: Identifiable {
        let height: Int
        let title: String
        var id: Int { height }
    }
    static let maxVideoHeightChoices = [
        HeightChoice(height: 0, title: "不限（最高清晰度）"), HeightChoice(height: 2160, title: "最高 4K（2160p）"),
        HeightChoice(height: 1440, title: "最高 2K（1440p）"), HeightChoice(height: 1080, title: "最高 1080p"),
        HeightChoice(height: 720, title: "最高 720p"),
    ]
    static var maxVideoHeight: Int { max(0, UserDefaults.standard.integer(forKey: maxVideoHeightKey)) }
    /// 默认开启
    static var askAlbum: Bool { UserDefaults.standard.object(forKey: askAlbumKey) as? Bool ?? true }
}

/// 下载记录：只记「平台:作品ID → 保存时间」，一万条也不到 1 MB；放在 App 内部数据里，不出现在「文件」App
enum History {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private static func load() -> [String: Double] {
        guard let data = try? Data(contentsOf: file),
              let d = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return d
    }

    static func savedDate(_ key: String) -> Date? {
        load()[key].map { Date(timeIntervalSince1970: $0) }
    }

    static func record(_ key: String) {
        var d = load()
        d[key] = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: file, options: .atomic) }
    }

    static var count: Int { load().count }

    static func clear() { try? FileManager.default.removeItem(at: file) }
}
