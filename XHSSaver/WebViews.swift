import SwiftUI
import WebKit

/// 包一层 WKWebView 给 SwiftUI 用。
/// 网页视图放在一个容器里：同一个网页视图会先放在主界面底下（后台读取），需要时再挪到弹出的页面上，
/// 谁后出现就归谁
struct WebViewBox: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        attach(to: box)
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {
        if webView.superview !== box { attach(to: box) }
    }

    private func attach(to box: UIView) {
        webView.removeFromSuperview()
        webView.frame = box.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(webView)
    }
}

/// 用账号自己的浏览器数据创建网页视图。desktop = 请求桌面网站（与 Safari 的同名功能相同）
@MainActor
func makeWebView(for account: WebAccount, desktop: Bool) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = account.dataStore
    config.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = .all
    let web = WKWebView(frame: .zero, configuration: config)
    web.allowsBackForwardNavigationGestures = true
    return web
}

/// 登录页里网页想开新窗口时（第三方登录、「在新窗口打开」的链接），就在当前页面里打开。
/// 不处理的话 WKWebView 会直接忽略，页面看起来像卡住。
final class LoginWebHelper: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

/// 登录 / 重新登录：打开该账号的浏览器，登录好之后点「完成」，cookie 自动导出到号池
struct WebLoginView: View {
    let account: WebAccount
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var exporting = false
    @State private var helper = LoginWebHelper()
    /// 浏览器里已经有这个网站的登录 cookie（nil = 这个网站没有检查规则，看不出来）
    @State private var loggedIn: Bool?

    /// 看一眼浏览器里的 cookie：登录其实已经成功、只是网页卡在跳转上时，让用户知道可以直接点「完成」
    @MainActor private func checkLogin() async {
        guard let names = CookiePool.loginCookieNames[account.site] else { loggedIn = nil; return }
        let now = Date()
        let cookies = await account.dataStore.httpCookieStore.allCookies()
        loggedIn = cookies.contains { c in
            names.contains(c.name) && !c.value.isEmpty && (c.expiresDate ?? .distantFuture) > now
                && CookiePool.site(of: c.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == account.site
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let webView {
                    WebViewBox(webView: webView)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(exporting ? "保存中…" : "完成") {
                        Task {
                            exporting = true
                            await WebAccounts.shared.exportCookies(account)
                            exporting = false
                            dismiss()
                        }
                    }
                    .disabled(exporting)
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        if loggedIn == true {
                            Label("已经登录成功，点右上角「完成」即可（页面还在转圈也不用等）",
                                  systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .accessibilityIdentifier("login-status")
                                .accessibilityValue("logged-in")
                        } else {
                            Text("在页面里登录（抖音、小红书可用手机号验证码），完成后点右上角「完成」")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("login-status")
                                .accessibilityValue(loggedIn == nil ? "unknown" : "not-logged-in")
                        }
                        Spacer()
                        Button {
                            webView?.reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("重新加载")
                        .accessibilityIdentifier("login-reload")
                    }
                }
            }
        }
        .onDisappear {
            // 不管点「完成」还是「取消」，已经登录的状态都导出一次到号池
            Task { await WebAccounts.shared.exportCookies(account) }
        }
        .onAppear {
            // 常用网站按预设来：登录页地址和要不要请求桌面网站都以预设为准
            // （这样改了预设之后，以前建好的账号也会用上新的登录页）
            let preset = SitePreset.preset(for: account.site)
            let web = makeWebView(for: account, desktop: preset?.desktop ?? false)
            web.uiDelegate = helper
            if let url = URL(string: preset?.loginURL ?? account.loginURL) { web.load(URLRequest(url: url)) }
            webView = web
        }
        .task {
            // 登录页开着的时候每 2 秒看一次；页面关掉时这个任务会被取消
            while !Task.isCancelled {
                await checkLogin()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
