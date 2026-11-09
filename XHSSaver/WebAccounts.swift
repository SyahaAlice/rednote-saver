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

    /// 号池里的文件名
    var cookieFileName: String { "web_\(site)_\(id.uuidString.prefix(8)).txt" }
    var cookieFile: URL { CookiePool.folder.appendingPathComponent(cookieFileName) }

    @MainActor var dataStore: WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: id) }
}

struct SitePreset: Identifiable {
    var id: String { site }
    var title: String
    var site: String
    var loginURL: String

    static let all: [SitePreset] = [
        SitePreset(title: "抖音", site: "douyin.com", loginURL: "https://www.douyin.com/"),
        SitePreset(title: "小红书", site: "xiaohongshu.com", loginURL: "https://www.xiaohongshu.com/explore"),
        SitePreset(title: "哔哩哔哩", site: "bilibili.com", loginURL: "https://passport.bilibili.com/login"),
        SitePreset(title: "微博", site: "weibo.com", loginURL: "https://weibo.com/login.php"),
        SitePreset(title: "Instagram", site: "instagram.com", loginURL: "https://www.instagram.com/accounts/login/"),
        SitePreset(title: "X", site: "x.com", loginURL: "https://x.com/i/flow/login"),
    ]
}

@MainActor
final class WebAccounts: ObservableObject {
    static let shared = WebAccounts()

    @Published private(set) var accounts: [WebAccount] = []

    private var listFile: URL { CookiePool.folder.appendingPathComponent("accounts.json") }

    init() { load() }

    func load() {
        CookiePool.prepareFolder()
        guard let data = try? Data(contentsOf: listFile),
              let list = try? JSONDecoder().decode([WebAccount].self, from: data) else { return }
        accounts = list
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
