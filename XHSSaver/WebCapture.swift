import SwiftUI
import WebKit

/// 通用的「内置浏览器读取」：用「设置 → 账号」里登录过的账号，在 App 内置浏览器里打开作品页，
/// 网页自己会拿到作品数据（写在网页里，或由网页脚本再请求），App 只是把那份数据复制一份。
/// 不伪造请求、不伪装浏览器；网站要求登录或验证时，由用户在弹出的页面里自己完成。
///
/// 新增一个网站只需要写一份 WebCaptureSpec（看哪些数据、怎么认出要的那一份）和一个解析函数，
/// 参考 Instagram.swift、XPost.swift、Weibo.swift。抖音（Douyin.swift）是更早写的，用的是自己的一套。
struct WebCaptureSpec {
    /// 导航栏和提示里显示的网站名
    var title: String
    /// true = 请求桌面网站（与 Safari 的同名功能相同）
    var desktop: Bool = false
    /// 一块数据的文字里含有其中任意一个，才交给 App（过滤掉无关的数据）
    var keywords: [String]
    /// 网页脚本请求的接口：网址里含有其中任意一个，才看它的返回内容
    var apiHints: [String]
    /// 写在网页里的普通脚本（不是 JSON 类型）：文字里含有其中任意一个时，整段交给 unwrap
    var inlineMarkers: [String] = []
    /// 从普通脚本的文字里取出 JSON 文字（配合 inlineMarkers）
    var unwrap: ((String) -> String?)?
    /// path 是网页当前的路径（短链跳转之后的），value 是解析好的一块数据；
    /// 从里面认出要的那个作品就返回它，否则返回 nil 继续等
    var match: (_ path: String, _ value: Any) -> [String: Any]?
}

/// 在一大块 JSON 里找东西的小工具（网站经常改外层结构，所以按特征去找，不按固定路径）
enum JSONTree {
    /// 深度优先找第一个满足条件的字典
    static func first(in value: Any, where test: ([String: Any]) -> Bool) -> [String: Any]? {
        if let d = value as? [String: Any] {
            if test(d) { return d }
            for v in d.values {
                if let hit = first(in: v, where: test) { return hit }
            }
        } else if let a = value as? [Any] {
            for v in a {
                if let hit = first(in: v, where: test) { return hit }
            }
        }
        return nil
    }

    static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func url(_ v: Any?) -> URL? {
        guard var s = v as? String, !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("http://") { s = "https://" + String(s.dropFirst("http://".count)) }
        return URL(string: s)
    }

    /// X 和微博用的时间写法，例如 "Wed Oct 10 20:19:24 +0000 2018"
    static func postDate(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f.date(from: s)
    }
}

private final class WebCaptureHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((String, String, String) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any],
              let path = d["path"] as? String, let text = d["text"] as? String else { return }
        onMessage?(path, text, d["kind"] as? String ?? "")
    }
}

@MainActor
final class WebCapture: ObservableObject, Identifiable {
    let id = UUID()
    let account: WebAccount
    let start: URL
    let spec: WebCaptureSpec
    let webView: WKWebView
    @Published var hint: String

    private let handler = WebCaptureHandler()
    private var continuation: CheckedContinuation<[String: Any], Error>?

    /// 在网页里复制一份数据（只读，不改动请求）。数据有三个来源：
    /// 1. 网页脚本请求接口（fetch / XMLHttpRequest）拿到的返回内容；
    /// 2. 直接写在网页里的 <script type="application/json">；
    /// 3. 写在网页里的普通脚本（含 inlineMarkers 里的标记时）。
    /// CFG 是 Swift 端传进来的 WebCaptureSpec（keywords / apiHints / inlineMarkers）
    private static let hookBody = """
      function has(t, list) {
        for (var i = 0; i < list.length; i++) if (t.indexOf(list[i]) >= 0) return true;
        return false;
      }
      function send(t, kind) {
        try {
          if (t && typeof t === 'string' && has(t, CFG.keywords)) {
            window.webkit.messageHandlers.webCapture.postMessage({ path: location.pathname, text: t, kind: kind });
          }
        } catch (e) {}
      }
      function isAPI(u) { return has(String(u || ''), CFG.apiHints); }
      var of = window.fetch;
      if (of) {
        window.fetch = function () {
          var args = arguments;
          return of.apply(this, args).then(function (r) {
            try {
              var u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
              if (isAPI(u)) r.clone().text().then(function (t) { send(t, 'api'); });
            } catch (e) {}
            return r;
          });
        };
      }
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__wcu = String(u); return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        var x = this;
        x.addEventListener('load', function () {
          try {
            if (!isAPI(x.__wcu)) return;
            send((x.responseType === '' || x.responseType === 'text') ? x.responseText : JSON.stringify(x.response), 'api');
          } catch (e) {}
        });
        return os.apply(this, arguments);
      };
      function scan() {
        try {
          var list = document.querySelectorAll('script');
          for (var i = 0; i < list.length; i++) {
            var el = list[i];
            if (el.__wcSeen) continue;
            el.__wcSeen = true;
            var t = el.textContent || '';
            if (el.type === 'application/json') send(t, 'json');
            else if (!el.src && CFG.inlineMarkers.length && has(t, CFG.inlineMarkers)) send(t, 'inline');
          }
        } catch (e) {}
      }
      document.addEventListener('DOMContentLoaded', scan);
      var n = 0;
      var timer = setInterval(function () { scan(); if (++n > 60) clearInterval(timer); }, 500);
    })();
    """

    private static func hookJS(_ spec: WebCaptureSpec) -> String {
        let cfg: [String: Any] = ["keywords": spec.keywords, "apiHints": spec.apiHints,
                                  "inlineMarkers": spec.inlineMarkers]
        let data = (try? JSONSerialization.data(withJSONObject: cfg)) ?? Data("{}".utf8)
        return "(function () {\n  var CFG = " + String(decoding: data, as: UTF8.self) + ";\n" + hookBody
    }

    init(account: WebAccount, start: URL, spec: WebCaptureSpec) {
        self.account = account
        self.start = start
        self.spec = spec
        hint = "正在用\(spec.title)网页读取…"
        let config = WKWebViewConfiguration()
        config.websiteDataStore = account.dataStore
        config.defaultWebpagePreferences.preferredContentMode = spec.desktop ? .desktop : .mobile
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(
            WKUserScript(source: Self.hookJS(spec), injectionTime: .atDocumentStart, forMainFrameOnly: true,
                         in: .page))
        config.userContentController.add(handler, contentWorld: .page, name: "webCapture")
        webView = WKWebView(frame: .zero, configuration: config)
        handler.onMessage = { [weak self] path, text, kind in
            Task { @MainActor in self?.received(path: path, text: text, kind: kind) }
        }
    }

    func run() async throws -> [String: Any] {
        webView.load(URLRequest(url: start))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.continuation != nil else { return }
            self.hint = "还没拿到数据：可能需要登录或验证。请在下方页面里完成，再点「重新加载」。"
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func received(path: String, text: String, kind: String) {
        guard continuation != nil else { return }
        var source = text
        if kind == "inline" {
            guard let inner = spec.unwrap?(text) else { return }
            source = inner
        }
        // 接口的返回内容有时是一行一个 JSON，整块读不出来就按行读
        var chunks = [source]
        if (try? JSONSerialization.jsonObject(with: Data(source.utf8))) == nil {
            chunks = source.split(whereSeparator: \.isNewline).map(String.init)
        }
        for chunk in chunks {
            if let obj = try? JSONSerialization.jsonObject(with: Data(chunk.utf8)),
               let hit = spec.match(path, obj) {
                finish(.success(hit))
                return
            }
        }
    }

    func reload() {
        hint = "正在用\(spec.title)网页读取…"
        // 短链已经跳到作品页的话，重新加载作品页本身
        webView.load(URLRequest(url: webView.url ?? start))
    }

    func cancel() {
        finish(.failure(XHSError.cancelled))
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "webCapture",
                                                                               contentWorld: .page)
        webView.stopLoading()
        c.resume(with: result)
    }
}

/// 读取作品时弹出的页面：能看到网页本身，需要登录或验证时用户可以直接操作
struct WebCaptureView: View {
    @ObservedObject var capture: WebCapture

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    ProgressView().padding(.trailing, 4)
                    Text(capture.hint).font(.callout)
                    Spacer()
                }
                .padding()
                WebViewBox(webView: capture.webView)
            }
            .navigationTitle("\(capture.spec.title)（\(capture.account.name)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { capture.cancel() }
                        .accessibilityIdentifier("capture-cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("重新加载") { capture.reload() }
                        .accessibilityIdentifier("capture-reload")
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
