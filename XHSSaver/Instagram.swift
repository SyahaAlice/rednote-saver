import SwiftUI
import WebKit

/// Instagram：yt-dlp 只能取视频，图片帖子存不了。
/// 做法和抖音一样：用「设置 → 账号」里登录过的 Instagram 账号，在 App 内置浏览器里打开帖子，
/// 网页自己会拿到帖子数据（写在网页里，或由网页脚本再请求），App 只是把那份数据复制一份来解析。
/// 不伪造请求、不伪装浏览器；如果 Instagram 要求登录或验证，由用户在弹出的页面里自己完成。
enum Instagram {
    /// 帖子类链接：/p/…、/reel/…、/reels/…、/tv/…，以及分享短链 /share/…（打开后会跳到前面几种）
    static func isPost(_ url: URL) -> Bool {
        guard CookiePool.site(of: url.host ?? "") == "instagram.com" else { return false }
        return shortcode(path: url.path) != nil || url.path.contains("/share/")
    }

    /// 从网址路径里取帖子代码（/p/ 后面那一段）；分享短链里的那一段不是帖子代码，返回 nil
    static func shortcode(path: String) -> String? {
        if path.contains("/share/") { return nil }
        guard let r = path.range(of: #"/(p|reel|reels|tv)/[A-Za-z0-9_-]+"#, options: .regularExpression) else {
            return nil
        }
        return path[r].split(separator: "/").last.map(String.init)
    }

    /// 在网页给的一大块数据里找出这个帖子：帖子代码对得上，而且带有图片 / 视频 / 多图字段。
    /// 不依赖外层结构（Instagram 经常改外层的名字）。帖子数据有新旧两种写法，两种都认：
    /// 新：code + image_versions2 / video_versions / carousel_media
    /// 旧：shortcode + display_url / display_resources / edge_sidecar_to_children
    static func find(in value: Any, code: String) -> [String: Any]? {
        if let d = value as? [String: Any] {
            if (d["code"] as? String) == code,
               d["image_versions2"] != nil || d["carousel_media"] != nil || d["video_versions"] != nil {
                return d
            }
            if (d["shortcode"] as? String) == code,
               d["display_url"] != nil || d["display_resources"] != nil || d["edge_sidecar_to_children"] != nil {
                return d
            }
            for v in d.values {
                if let hit = find(in: v, code: code) { return hit }
            }
        } else if let a = value as? [Any] {
            for v in a {
                if let hit = find(in: v, code: code) { return hit }
            }
        }
        return nil
    }

    private static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// 同一份媒体的各个尺寸，面积最大的在前。新写法是 url / width / height，旧写法是 src / config_width / config_height
    private static func sortedURLs(_ list: Any?) -> [URL] {
        let items = list as? [[String: Any]] ?? []
        func area(_ d: [String: Any]) -> Int {
            (d["width"] as? Int ?? d["config_width"] as? Int ?? 0) * (d["height"] as? Int ?? d["config_height"] as? Int ?? 0)
        }
        var seen = Set<String>()
        return items.sorted { area($0) > area($1) }.compactMap { d -> URL? in
            guard let s = (d["url"] as? String) ?? (d["src"] as? String), !s.isEmpty,
                  seen.insert(s).inserted else { return nil }
            return URL(string: s)
        }
    }

    private static func url(_ v: Any?) -> URL? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// 一张图或一段视频 → 一个媒体项；首选最高分辨率，次一档要先问用户
    private static func media(_ m: [String: Any]) -> NoteMedia? {
        // 新写法
        let videos = sortedURLs(m["video_versions"])
        if let best = videos.first {
            return NoteMedia(kind: .video, original: [best], fallback: Array(videos.dropFirst().prefix(2)))
        }
        let images = sortedURLs((m["image_versions2"] as? [String: Any])?["candidates"])
        if let best = images.first {
            return NoteMedia(kind: .image, original: [best], fallback: Array(images.dropFirst().prefix(1)))
        }
        // 旧写法
        if let video = url(m["video_url"]) {
            return NoteMedia(kind: .video, original: [video], fallback: [])
        }
        var old = sortedURLs(m["display_resources"])
        if old.isEmpty, let one = url(m["display_url"]) { old = [one] }
        if let best = old.first {
            return NoteMedia(kind: .image, original: [best], fallback: Array(old.dropFirst().prefix(1)))
        }
        return nil
    }

    /// 多图帖子里的每一项（新写法 carousel_media，旧写法 edge_sidecar_to_children）；不是多图就返回空
    private static func children(_ d: [String: Any]) -> [[String: Any]] {
        if let list = d["carousel_media"] as? [[String: Any]], !list.isEmpty { return list }
        let edges = (d["edge_sidecar_to_children"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
        return edges.compactMap { $0["node"] as? [String: Any] }
    }

    static func parse(item d: [String: Any]) throws -> ParsedNote {
        let code = (d["code"] as? String) ?? (d["shortcode"] as? String) ?? ""
        var items: [NoteMedia] = []
        let parts = children(d)
        if !parts.isEmpty {
            items = parts.compactMap { media($0) }
        } else if let one = media(d) {
            items = [one]
        }
        if items.isEmpty { throw XHSError("这个帖子里没找到可保存的内容") }

        var author: Author?
        if let u = (d["user"] as? [String: Any]) ?? (d["owner"] as? [String: Any]) {
            // 相册名用 @ 后面的用户名；匹配已有相册时数字 ID 也算
            let username = string(u["username"])
            var ids: [String] = []
            for i in [username, string(u["pk"]), string(u["id"])] where !i.isEmpty && !ids.contains(i) {
                ids.append(i)
            }
            if !ids.isEmpty {
                let fullName = string(u["full_name"])
                author = Author(name: fullName.isEmpty ? username : fullName,
                                primaryID: username.isEmpty ? ids[0] : username, ids: ids, idLabel: "用户名")
            }
        }
        var title = (d["caption"] as? [String: Any])?["text"] as? String ?? ""
        if title.isEmpty {  // 旧写法
            let edges = (d["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
            title = (edges.first?["node"] as? [String: Any])?["text"] as? String ?? ""
        }
        let published = ((d["taken_at"] as? Double) ?? (d["taken_at_timestamp"] as? Double))
            .map { Date(timeIntervalSince1970: $0) }
        return ParsedNote(platform: "Instagram", id: code.isEmpty ? string(d["pk"]) : code, title: title,
                          items: items, author: author, published: published,
                          referer: "https://www.instagram.com/")
    }
}

// MARK: - 内置浏览器读取帖子数据

private final class InstagramHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((String, String) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any],
              let path = d["path"] as? String, let text = d["text"] as? String else { return }
        onMessage?(path, text)
    }
}

@MainActor
final class InstagramCapture: ObservableObject, Identifiable {
    let id = UUID()
    let account: WebAccount
    let start: URL
    let webView: WKWebView
    @Published var hint = "正在用 Instagram 网页读取帖子…"

    private let handler = InstagramHandler()
    private var continuation: CheckedContinuation<[String: Any], Error>?

    /// 在网页里复制一份帖子数据（只读，不改动请求）。数据有两个来源：
    /// 1. 直接写在网页里的 <script type="application/json">；
    /// 2. 网页脚本之后请求 /graphql、/api/v1/ 接口拿到的返回内容。
    /// 只把提到图片 / 视频字段的那几块交给 App，由 App 按帖子代码挑出要的那一个
    private static let hookJS = """
    (function () {
      var KEYS = ['image_versions2', 'carousel_media', 'video_versions', 'display_url', 'display_resources'];
      function interesting(t) {
        if (!t || typeof t !== 'string') return false;
        for (var i = 0; i < KEYS.length; i++) if (t.indexOf(KEYS[i]) >= 0) return true;
        return false;
      }
      function send(t) {
        try {
          if (interesting(t)) window.webkit.messageHandlers.igCapture.postMessage({ path: location.pathname, text: t });
        } catch (e) {}
      }
      function isAPI(u) { u = String(u || ''); return u.indexOf('/graphql') >= 0 || u.indexOf('/api/v1/') >= 0; }
      var of = window.fetch;
      if (of) {
        window.fetch = function () {
          var args = arguments;
          return of.apply(this, args).then(function (r) {
            try {
              var u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
              if (isAPI(u)) r.clone().text().then(send);
            } catch (e) {}
            return r;
          });
        };
      }
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__igu = String(u); return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        var x = this;
        x.addEventListener('load', function () {
          try {
            if (!isAPI(x.__igu)) return;
            send((x.responseType === '' || x.responseType === 'text') ? x.responseText : JSON.stringify(x.response));
          } catch (e) {}
        });
        return os.apply(this, arguments);
      };
      function scan() {
        try {
          var list = document.querySelectorAll('script[type="application/json"]');
          for (var i = 0; i < list.length; i++) {
            if (list[i].__igSeen) continue;
            list[i].__igSeen = true;
            send(list[i].textContent);
          }
        } catch (e) {}
      }
      document.addEventListener('DOMContentLoaded', scan);
      var n = 0;
      var timer = setInterval(function () { scan(); if (++n > 60) clearInterval(timer); }, 500);
    })();
    """

    init(account: WebAccount, start: URL) {
        self.account = account
        self.start = start
        let config = WKWebViewConfiguration()
        config.websiteDataStore = account.dataStore
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(
            WKUserScript(source: Self.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        config.userContentController.add(handler, contentWorld: .page, name: "igCapture")
        webView = WKWebView(frame: .zero, configuration: config)
        handler.onMessage = { [weak self] path, text in
            Task { @MainActor in self?.received(path: path, text: text) }
        }
    }

    func run() async throws -> [String: Any] {
        webView.load(URLRequest(url: start))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.continuation != nil else { return }
            self.hint = "还没拿到帖子数据：可能需要登录或验证。请在下方页面里完成，再点「重新加载」。"
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    /// path 是网页当前的路径（分享短链跳转之后才有帖子代码），text 是网页拿到的一块数据
    private func received(path: String, text: String) {
        guard continuation != nil, let code = Instagram.shortcode(path: path) else { return }
        // 接口的返回内容有时是一行一个 JSON，整块读不出来就按行读
        var chunks = [text]
        if (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil {
            chunks = text.split(whereSeparator: \.isNewline).map(String.init)
        }
        for chunk in chunks {
            if let obj = try? JSONSerialization.jsonObject(with: Data(chunk.utf8)),
               let item = Instagram.find(in: obj, code: code) {
                finish(.success(item))
                return
            }
        }
    }

    func reload() {
        hint = "正在用 Instagram 网页读取帖子…"
        // 分享短链已经跳到帖子页的话，重新加载帖子页本身
        webView.load(URLRequest(url: webView.url ?? start))
    }

    func cancel() {
        finish(.failure(XHSError("已取消")))
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "igCapture", contentWorld: .page)
        webView.stopLoading()
        c.resume(with: result)
    }
}

/// 读取帖子时弹出的页面：能看到网页本身，需要登录或验证时用户可以直接操作
struct InstagramCaptureView: View {
    @ObservedObject var capture: InstagramCapture

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
            .navigationTitle("Instagram（\(capture.account.name)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { capture.cancel() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("重新加载") { capture.reload() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
