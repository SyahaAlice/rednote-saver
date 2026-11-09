import Foundation

/// 号池：Documents/cookies/ 里每个账号一个 Netscape 格式的 .txt（与 phone/dl.py 相同）。
/// 电脑上整理好后，用 opendevice afc push 或「文件」App 放进这个文件夹即可，换 cookie 不用重新安装。
enum CookiePool {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var folder: URL { documents.appendingPathComponent("cookies", isDirectory: true) }
    private static var stateFile: URL { folder.appendingPathComponent(".next") }

    /// 这些网站先用游客试，失败才用号池账号：小红书大陆账号登录后网页只给压缩视频
    /// 快手：分享页游客就能看，账号只在游客拿不到时才用
    static let guestFirst: Set<String> = ["xiaohongshu.com", "kuaishou.com"]

    /// 短链 / 别名域名 → 实际网站（rednote.com 算小红书，国内版、海外版账号可以混在一个号池里）
    static let siteAlias: [(String, String)] = [
        ("b23.tv", "bilibili.com"),
        ("xhslink.com", "xiaohongshu.com"), ("xhslink.cn", "xiaohongshu.com"), ("rednote.com", "xiaohongshu.com"),
        ("v.douyin.com", "douyin.com"), ("iesdouyin.com", "douyin.com"),
        ("twitter.com", "x.com"), ("t.co", "x.com"),
        ("instagr.am", "instagram.com"),
        ("weibo.cn", "weibo.com"), ("t.cn", "weibo.com"),
        // 快手：短链 v.kuaishou.com、分享页 *.chenzhongtech.com / *.gifshow.com 都算快手
        ("kuaishou.com", "kuaishou.com"), ("kuaishou.cn", "kuaishou.com"),
        ("chenzhongtech.com", "kuaishou.com"), ("gifshow.com", "kuaishou.com"),
    ]

    static func site(of host: String) -> String {
        let h = host.lowercased().split(separator: ":").first.map(String.init) ?? ""
        for (k, v) in siteAlias where h == k || h.hasSuffix("." + k) { return v }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    struct Entry {
        var domain: String
        var includeSubdomains: Bool
        var path: String
        var secure: Bool
        var expires: Date?
        var name: String
        var value: String
        var httpOnly: Bool
    }

    /// 读取 Netscape cookies 文件（只解析，不会打印或上传 cookie 的值）
    static func entries(in file: URL) -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                line.removeFirst("#HttpOnly_".count)
                httpOnly = true
            } else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { continue }
            let exp = Double(f[4]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            out.append(Entry(domain: f[0], includeSubdomains: f[1].uppercased() == "TRUE", path: f[2],
                             secure: f[3].uppercased() == "TRUE", expires: exp, name: f[5],
                             value: f[6...].joined(separator: "\t"), httpOnly: httpOnly))
        }
        return out
    }

    static func domains(in file: URL) -> Set<String> {
        Set(entries(in: file).map { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() })
    }

    static func httpCookies(from file: URL) -> [HTTPCookie] {
        entries(in: file).compactMap { e in
            if let exp = e.expires, exp < Date() { return nil }
            var p: [HTTPCookiePropertyKey: Any] = [
                .domain: e.domain, .path: e.path.isEmpty ? "/" : e.path, .name: e.name, .value: e.value,
            ]
            if e.secure { p[.secure] = "TRUE" }
            if let exp = e.expires { p[.expires] = exp }
            return HTTPCookie(properties: p)
        }
    }

    /// 号池里所有账号文件
    static func allFiles() -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".txt") && $0 != "README.txt" }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// 按网站挑出能用的 cookies 文件，从上次轮到的那个开始排；nil 表示游客。
    /// 小红书游客在前，其它网站账号在前、游客垫底（与 dl.py 的 cookie_candidates 相同）
    static func candidates(for url: URL, rotate: Bool = true) -> [URL?] {
        let site = site(of: url.host ?? "")
        func sameSite(_ d: String) -> Bool {
            let sd = self.site(of: d)
            return sd == site || sd.hasSuffix("." + site) || site.hasSuffix("." + sd)
        }
        var files = allFiles().filter { domains(in: $0).contains(where: sameSite) }
        if rotate, !files.isEmpty {
            let saved = (try? String(contentsOf: stateFile, encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            let start = ((saved % files.count) + files.count) % files.count
            files = Array(files[start...] + files[..<start])
            try? String(start + 1).write(to: stateFile, atomically: true, encoding: .utf8)
        }
        let accounts: [URL?] = files.map { Optional($0) }
        return guestFirst.contains(site) ? [nil] + accounts : accounts + [nil]
    }

    /// 第一次启动时建好文件夹和说明
    static func prepareFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let readme = folder.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            号池：每个账号一个 Netscape 格式的 cookies 文件（.txt），文件名随意，比如 au.txt、cn1.txt。
            用电脑上的 Get cookies.txt LOCALLY 导出，再用 merge_cookies.py 合并同一账号的多个域名。
            App 会按网址自动挑出对应网站的账号轮流使用；小红书先用游客（原片），失败才用账号。
            """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// 各网站表示「已登录」的 cookie 名（只看名字，不读值）。没列出的网站没法判断登录状态
    static let loginCookieNames: [String: Set<String>] = [
        "xiaohongshu.com": ["web_session"],                       // 小红书 / rednote
        "douyin.com": ["sessionid", "sessionid_ss", "sid_tt"],
        "bilibili.com": ["SESSDATA"],
        "weibo.com": ["SUB"],
        "x.com": ["auth_token"],
        "instagram.com": ["sessionid"],
    ]

    /// 账号状态：正常 / 已过期 / 未登录（未激活）/ 无法判断
    enum Health: Equatable {
        case ok(expires: Date?)
        case expired
        case notLoggedIn
        /// 这个网站不在 loginCookieNames 里，看不出有没有登录；不算失效，不提示补登
        case unknown

        /// 只有确认失效或未激活的才提示补登
        var needsLogin: Bool { self == .expired || self == .notLoggedIn }
        var text: String {
            switch self {
            case .ok(let d): return d.map { "正常（登录有效期到 " + $0.formatted(date: .abbreviated, time: .omitted) + "）" } ?? "正常"
            case .expired: return "已过期，需要补登"
            case .notLoggedIn: return "未登录（未激活），需要补登"
            case .unknown: return "无法判断登录状态（这个网站没有内置的检查规则）"
            }
        }
    }

    /// site 传网站名（例如 bilibili.com）时只看这个网站的 cookie；
    /// 不传时看文件里所有认识的网站，有一个失效就算失效
    static func health(of file: URL, site: String? = nil) -> Health {
        var bySite: [String: [Entry]] = [:]
        for e in entries(in: file) {
            let s = self.site(of: e.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            bySite[s, default: []].append(e)
        }
        func one(_ s: String) -> Health {
            guard let names = loginCookieNames[s] else { return .unknown }
            let login = (bySite[s] ?? []).filter { names.contains($0.name) }
            guard !login.isEmpty else { return .notLoggedIn }
            let alive = login.filter { ($0.expires ?? .distantFuture) > Date() }
            guard !alive.isEmpty else { return .expired }
            return .ok(expires: alive.compactMap(\.expires).min())
        }
        if let site { return one(site) }
        let known = bySite.keys.filter { loginCookieNames[$0] != nil }.map(one)
        if known.isEmpty { return .unknown }
        if known.contains(.expired) { return .expired }
        if known.contains(.notLoggedIn) { return .notLoggedIn }
        let dates = known.compactMap { h -> Date? in
            if case .ok(let d) = h { return d }
            return nil
        }
        return .ok(expires: dates.min())
    }

    /// 这个网站的号池账号里有没有确认失效 / 未激活的（无法判断的不算）
    static func hasProblem(for url: URL) -> Bool {
        let s = site(of: url.host ?? "")
        return candidates(for: url, rotate: false).compactMap { $0 }.contains { health(of: $0, site: s).needsLogin }
    }

    /// 小红书：带这个账号的 cookie 打开小红书，看网页认不认为已登录（nil = 没法判断）
    static func verifyOnline(_ file: URL) async -> Bool? {
        let config = URLSessionConfiguration.ephemeral
        if let jar = config.httpCookieStorage {
            for c in httpCookies(from: file) { jar.setCookie(c) }
        }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: URL(string: "https://www.xiaohongshu.com/explore")!, timeoutInterval: 20)
        for (k, v) in NoteParser.pageHeaders { req.setValue(v, forHTTPHeaderField: k) }
        guard let result = try? await session.data(for: req),
              let state = try? NoteParser.initialState(String(decoding: result.0, as: UTF8.self)),
              let user = state["user"] as? [String: Any] else { return nil }
        // 小红书网页的状态里，loggedIn 可能直接是布尔值，也可能包在 { _value / value } 里
        func bool(_ v: Any?) -> Bool? {
            if let b = v as? Bool { return b }
            if let d = v as? [String: Any] { return bool(d["_rawValue"] ?? d["_value"] ?? d["value"]) }
            return nil
        }
        return bool(user["loggedIn"])
    }

    /// 设置页显示用：每个账号文件有哪些网站、状态（只看名字，不显示值）
    struct Summary: Identifiable {
        var id: String { name }
        var name: String
        var file: URL
        var sites: [String]
        var health: Health
    }

    static func summaries() -> [Summary] {
        allFiles().map { file in
            let es = entries(in: file)
            let sites = Set(es.map { site(of: $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) })
            return Summary(name: file.lastPathComponent, file: file, sites: sites.sorted(), health: health(of: file))
        }
    }
}
