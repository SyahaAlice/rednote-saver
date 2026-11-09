import SwiftUI
import WebKit

/// 包一层 WKWebView 给 SwiftUI 用
struct WebViewBox: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
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

/// 登录 / 重新登录：打开该账号的浏览器，登录好之后点「完成」，cookie 自动导出到号池
struct WebLoginView: View {
    let account: WebAccount
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var exporting = false

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
                    Text("在页面里登录（抖音、小红书可用手机号验证码），完成后点右上角「完成」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear {
            // 不管点「完成」还是「取消」，已经登录的状态都导出一次到号池
            Task { await WebAccounts.shared.exportCookies(account) }
        }
        .onAppear {
            // 抖音用桌面版网页（手机版页面拿不到作品数据）
            let web = makeWebView(for: account, desktop: account.site == "douyin.com")
            if let url = URL(string: account.loginURL) { web.load(URLRequest(url: url)) }
            webView = web
        }
    }
}
