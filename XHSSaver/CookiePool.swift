import Foundation

/// 号池：Documents/cookies/ 里每个账号一个 Netscape 格式的 .txt（与 phone/dl.py 相同）。
/// 电脑上整理好后，用 opendevice afc push 或「文件」App 放进这个文件夹即可，换 cookie 不用重新安装。
enum CookiePool {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var folder: URL { documents.appendingPathComponent("cookies", isDirectory: true) }
    private static var stateFile: URL { folder.appendingPathComponent(".next") }

    /// 这些网站先用游客试，失败才用号池账号：小红书大陆账号登录后网页只给压缩视频
    static let guestFirst: Set<String> = ["xiaohongshu.com"]

    /// 短链 / 别名域名 → 实际网站（rednote.com 算小红书，国内版、海外版账号可以混在一个号池里）
    static let siteAlias: [(String, String)] = [
        ("b23.tv", "bilibili.com"),
        ("xhslink.com", "xiaohongshu.com"), ("xhslink.cn", "xiaohongshu.com"), ("rednote.com", "xiaohongshu.com"),
        ("v.douyin.com", "douyin.com"), ("iesdouyin.com", "douyin.com"),
        ("twitter.com", "x.com"), ("t.co", "x.com"),
        ("instagr.am", "instagram.com"),
        ("weibo.cn", "weibo.com"), ("t.cn", "weibo.com"),
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
    static func candidates(for url: URL) -> [URL?] {
        let site = site(of: url.host ?? "")
        func sameSite(_ d: String) -> Bool {
            let sd = self.site(of: d)
            return sd == site || sd.hasSuffix("." + site) || site.hasSuffix("." + sd)
        }
        var files = allFiles().filter { domains(in: $0).contains(where: sameSite) }
        if !files.isEmpty {
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

    /// 设置页显示用：每个账号文件有哪些网站、是否包含登录凭证（只看名字，不显示值）
    struct Summary: Identifiable {
        var id: String { name }
        var name: String
        var sites: [String]
        var loggedIn: Bool
        var expired: Int
    }

    static func summaries() -> [Summary] {
        allFiles().map { file in
            let es = entries(in: file)
            let sites = Set(es.map { site(of: $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) })
            let names = Set(es.map(\.name))
            let loginNames: Set<String> = ["web_session", "SESSDATA", "sessionid", "auth_token", "SUB", "sessionid_ss"]
            return Summary(name: file.lastPathComponent, sites: sites.sorted(),
                           loggedIn: !names.isDisjoint(with: loginNames),
                           expired: es.filter { ($0.expires ?? .distantFuture) < Date() }.count)
        }
    }
}
