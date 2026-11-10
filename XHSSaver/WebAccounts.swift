import Foundation
import WebKit

/// 在 App 内置浏览器里登录的账号。每个账号有一份独立的浏览器数据（互不干扰），
/// 登录后自动把 cookie 导出成 Netscape 格式写进号池（Documents/cookies/），yt-dlp 和小红书解析直接使用。
/// cookie 失效时在「设置 → 账号」里点「重新登录」即可。
struct WebAccount: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var site: String       // 例如 douyin.com、xiaohongshu.com
    var loginURL: String
    var lastExport: Date?
    /// 上次自动续期（用这个账号打开一次网站）是什么时候
    var lastVisit: Date?

    /// 号池里的文件名
    var cookieFileName: String { "web_\(site)_\(id.uuidString.prefix(8)).txt" }
    var cookieFile: URL { CookiePool.folder.appendingPathComponent(cookieFileName) }

    @MainActor var dataStore: WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: id) }
}

/// 「导出账号」得到的文件：所有账号的 cookie 打成一个 JSON，可以原样导入回来（换手机、重装之后用）
struct CookieBundle: Codable {
    static let formatName = "xhssaver-cookies"
    var format = CookieBundle.formatName
    var version = 1
    var exported: Date
    /// App 内登录的账号（名称、网站、对应哪个文件）
    var accounts: [WebAccount]
    /// 号池里的每个文件：Netscape 格式的原文
    var files: [File]

    struct File: Codable {
        var name: String
        var content: String
    }
}

struct SitePreset: Identifiable {
    var id: String { site }
    var title: String
    var site: String
    var loginURL: String
    /// 登录页要不要请求桌面网站（有的网站手机版网页不能登录，或者会被带去「打开 App」的页面）
    var desktop = false

    static func preset(for site: String) -> SitePreset? { all.first { $0.site == site } }

    static let all: [SitePreset] = [
        SitePreset(title: "抖音", site: "douyin.com", loginURL: "https://www.douyin.com/", desktop: true),
        // 小红书：手机版网页只有「打开 App」，没有登录入口；桌面版会弹出登录框（手机号 + 验证码）
        SitePreset(title: "小红书", site: "xiaohongshu.com", loginURL: "https://www.xiaohongshu.com/explore",
                   desktop: true),
        SitePreset(title: "哔哩哔哩", site: "bilibili.com", loginURL: "https://passport.bilibili.com/login"),
        SitePreset(title: "微博", site: "weibo.com", loginURL: "https://weibo.com/login.php"),
        SitePreset(title: "Instagram", site: "instagram.com", loginURL: "https://www.instagram.com/accounts/login/"),
        SitePreset(title: "X", site: "x.com", loginURL: "https://x.com/i/flow/login"),
        // 快手：www.kuaishou.com 用手机浏览器打开会被带去 m.kuaishou.com（只有「打开 App」，不能登录），
        // 所以用它的登录页本身，并请求桌面网站。
        // sid 必须是快手网页版自己用的 kuaishou.server.webday7；不要带 callback 参数：
        // 登录页只接受白名单里的回跳地址，随便填会在登录成功后报「跳转地址不合法」。
        // 不带时它用服务器给的回跳地址，登录完再去 redirectURL
        SitePreset(title: "快手", site: "kuaishou.com", loginURL:
            "https://passport.kuaishou.com/pc/account/login/?sid=kuaishou.server.webday7&redirectURL=https%3A%2F%2Fwww.kuaishou.com%2F",
                   desktop: true),
    ]
}

@MainActor
final class WebAccounts: ObservableObject {
    static let shared = WebAccounts()

    @Published private(set) var accounts: [WebAccount] = []
    /// 自动续期时发现已经掉线的账号（下载页顶上提示；用户看过或去登录后清空）
    @Published var offline: [WebAccount] = []
    private var renewing = false

    /// 设置里的开关：自动续期登录（默认开）
    static let autoRenewKey = "autoRenewLogins"
    static var autoRenew: Bool { UserDefaults.standard.object(forKey: autoRenewKey) as? Bool ?? true }
    /// 每个账号多久续一次
    private static let renewEvery: TimeInterval = 24 * 3600

    private var listFile: URL { CookiePool.folder.appendingPathComponent("accounts.json") }

    init() { load() }

    func load() {
        CookiePool.prepareFolder()
        guard let data = try? Data(contentsOf: listFile) else { return }
        // 保存时日期写成 ISO 8601 的文字，读的时候也要按这个格式；
        // 以前这里用了默认格式，导出过 cookie（lastExport 有值）的账号列表重启后读不出来
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([WebAccount].self, from: data) {
            accounts = list
        } else if let list = try? JSONDecoder().decode([WebAccount].self, from: data) {
            accounts = list
        }
    }

    // MARK: - 自动续期

    /// 给登录过的账号续期：每个账号每天最多一次，在内置浏览器里打开一次网站首页（和自己打开网页看一眼一样），
    /// 让网站自己决定要不要延长登录，再把最新的 cookie 同步到号池。
    /// 续完检查登录还在不在，掉线的记进 offline。固定期限的网站、已经被踢下线的登录续不上，只能重新登录
    func renewDue() async {
        guard Self.autoRenew, !renewing else { return }
        renewing = true
        defer { renewing = false }
        var lost: [WebAccount] = []
        for a in accounts where a.lastExport != nil {
            if let t = a.lastVisit, Date().timeIntervalSince(t) < Self.renewEvery { continue }
            // 正在保存时不打扰（保存时也可能在用这个账号的浏览器）；下次再续
            if SaveService.shared.isRunning { break }
            await visit(a)
            await exportCookies(a)
            if let i = accounts.firstIndex(where: { $0.id == a.id }) {
                accounts[i].lastVisit = Date()
                save()
            }
            var gone = CookiePool.health(of: a.cookieFile, site: a.site).needsLogin
            // 小红书被踢下线时 cookie 还在，要实际问一下网站认不认
            if !gone, a.site == "xiaohongshu.com", await CookiePool.verifyOnline(a.cookieFile) == false { gone = true }
            if gone { lost.append(a) }
        }
        if !lost.isEmpty { offline = lost }
    }

    /// 用这个账号在内置浏览器里打开一次网站首页，等它加载完
    private func visit(_ a: WebAccount) async {
        let preset = SitePreset.preset(for: a.site)
        var home = URL(string: "https://www.\(a.site)/")
        if preset == nil, let login = URL(string: a.loginURL), let host = login.host {
            home = URL(string: "https://\(host)/")
        }
        guard let home else { return }
        let web = makeWebView(for: a, desktop: preset?.desktop ?? false)
        web.load(URLRequest(url: home, timeoutInterval: 20))
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !web.isLoading { break }
        }
        // 页面自己的脚本（有的网站靠它换新的登录凭证）再给几秒
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        web.stopLoading()
    }

    // MARK: - 导出 / 导入

    /// 把所有账号打成一个文件（JSON）：号池里每个 cookies 文件的内容 + App 内登录的账号列表。
    /// 这个文件等于登录凭证，只应该由用户自己保管
    func exportBundle() async throws -> Data {
        // 先把内置浏览器里最新的 cookie 刷进号池（只刷登录过的账号）
        for a in accounts where a.lastExport != nil { await exportCookies(a) }
        let files = CookiePool.allFiles().compactMap { f -> CookieBundle.File? in
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
            return CookieBundle.File(name: f.lastPathComponent, content: text)
        }
        guard !files.isEmpty else { throw XHSError("还没有可以导出的账号") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(CookieBundle(exported: Date(), accounts: accounts, files: files))
    }

    /// 导入：这个 App 导出的文件，或者一个普通的 Netscape cookies 文件。返回一句结果。
    /// 同名的账号文件会被换成导入的；App 内登录的账号连内置浏览器里的登录状态一起恢复
    func importCookies(from url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        let fm = FileManager.default
        try fm.createDirectory(at: CookiePool.folder, withIntermediateDirectories: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let bundle = try? dec.decode(CookieBundle.self, from: data), bundle.format == CookieBundle.formatName {
            var written = 0
            for f in bundle.files {
                // 只取文件名本身，不让导入的文件写到号池文件夹外面
                let name = (f.name as NSString).lastPathComponent
                guard name.lowercased().hasSuffix(".txt"), name != "README.txt" else { continue }
                try f.content.write(to: CookiePool.folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
                written += 1
            }
            var restored = 0
            for a in bundle.accounts {
                if let i = accounts.firstIndex(where: { $0.id == a.id }) { accounts[i] = a } else { accounts.append(a) }
                guard fm.fileExists(atPath: a.cookieFile.path) else { continue }
                let store = a.dataStore.httpCookieStore
                for c in CookiePool.httpCookies(from: a.cookieFile) { await store.setCookie(c) }
                restored += 1
            }
            save()
            return "已导入 \(written) 个账号文件" + (restored > 0 ? "，恢复了 \(restored) 个内置浏览器账号的登录状态" : "")
        }
        // 普通的 Netscape cookies 文件：验证能读出 cookie 再放进号池
        guard !CookiePool.entries(in: url).isEmpty else {
            throw XHSError("不是这个 App 导出的文件，也不是 Netscape 格式的 cookies 文件")
        }
        var name = url.lastPathComponent
        if !name.lowercased().hasSuffix(".txt") { name += ".txt" }
        try data.write(to: CookiePool.folder.appendingPathComponent(name), options: .atomic)
        return "已导入：\(name)"
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(accounts) { try? data.write(to: listFile, options: .atomic) }
    }

    /// 补登用：这个网址所属网站已有账号就用第一个，没有就新建一个（常用网站用预设登录页，其它用网站首页）
    func accountForLogin(url: URL) -> WebAccount {
        let site = CookiePool.site(of: url.host ?? "")
        if let a = accounts(for: site).first { return a }
        if let preset = SitePreset.all.first(where: { $0.site == site }) {
            return add(name: preset.title, preset: preset)
        }
        let home = URL(string: "https://\(url.host ?? site)/") ?? url
        return add(name: site, url: home)
    }

    func accounts(for site: String) -> [WebAccount] {
        accounts.filter { $0.site == site || site.hasSuffix("." + $0.site) || $0.site.hasSuffix("." + site) }
    }

    func add(name: String, preset: SitePreset) -> WebAccount {
        let a = WebAccount(id: UUID(), name: name.isEmpty ? preset.title : name, site: preset.site,
                           loginURL: preset.loginURL, lastExport: nil)
        accounts.append(a)
        save()
        return a
    }

    func add(name: String, url: URL) -> WebAccount {
        let host = url.host ?? "site"
        let site = CookiePool.site(of: host)
        let a = WebAccount(id: UUID(), name: name.isEmpty ? site : name, site: site,
                           loginURL: url.absoluteString, lastExport: nil)
        accounts.append(a)
        save()
        return a
    }

    func remove(_ account: WebAccount) async {
        accounts.removeAll { $0.id == account.id }
        save()
        try? FileManager.default.removeItem(at: account.cookieFile)
        try? await WKWebsiteDataStore.remove(forIdentifier: account.id)
    }

    /// 把这个账号浏览器里的 cookie 导出到号池（只导出属于该网站的 cookie）。返回导出的条数
    @discardableResult
    func exportCookies(_ account: WebAccount) async -> Int {
        let cookies = await account.dataStore.httpCookieStore.allCookies()
        let mine = cookies.filter { c in
            let d = CookiePool.site(of: c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            return d == account.site || d.hasSuffix("." + account.site) || account.site.hasSuffix("." + d)
        }
        var lines = ["# Netscape HTTP Cookie File", "# 由多功能媒体下载器从内置浏览器导出：\(account.name)", ""]
        for c in mine {
            let domain = c.domain
            let sub = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let exp = c.expiresDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let prefix = c.isHTTPOnly ? "#HttpOnly_" : ""
            lines.append([prefix + domain, sub, c.path.isEmpty ? "/" : c.path, c.isSecure ? "TRUE" : "FALSE",
                          exp, c.name, c.value].joined(separator: "\t"))
        }
        try? FileManager.default.createDirectory(at: CookiePool.folder, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: account.cookieFile, atomically: true, encoding: .utf8)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i].lastExport = Date()
            save()
        }
        return mine.count
    }
}
