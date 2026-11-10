import SwiftUI
import WebKit

/// 抖音：未登录时作品数据接口直接拒绝（403），分享页里也不再带数据。
/// 做法：用「设置 → 账号」里登录过的抖音账号，在 App 内置浏览器（桌面版网页）里打开作品页，
/// 由抖音自己的网页脚本请求作品详情，App 只是把网页收到的那份数据复制一份来解析。
/// 登录后抖音常常把作品数据直接写在页面里、不再请求接口，所以同时也读页面里自带的那份（见 scanJS）。
/// 不伪造签名、不伪装浏览器；如果抖音要求验证，由用户在弹出的页面里自己完成。
enum Douyin {
    struct Ref { var id: String; var kind: String }  // kind: video / note

    static func isDouyin(_ url: URL) -> Bool {
        CookiePool.site(of: url.host ?? "") == "douyin.com"
    }

    static func ref(_ url: URL) -> Ref? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        let path = comps.path
        if let r = path.range(of: #"/(share/)?(video|note|slides)/[0-9]+"#, options: .regularExpression) {
            let parts = path[r].split(separator: "/").map(String.init)
            let kind = parts.contains("video") ? "video" : "note"
            if let id = parts.last { return Ref(id: id, kind: kind) }
        }
        for key in ["modal_id", "aweme_id", "item_id"] {
            if let v = comps.queryItems?.first(where: { $0.name == key })?.value, !v.isEmpty {
                return Ref(id: v, kind: "video")
            }
        }
        return nil
    }

    /// 跟随 v.douyin.com 短链跳转，拿到作品 ID 就停
    static func resolve(_ start: URL) async throws -> Ref {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let stopper = NoRedirect()
        var url = start
        for _ in 0..<8 {
            if let r = ref(url) { return r }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue(NoteParser.mobileUA, forHTTPHeaderField: "User-Agent")
            let (_, resp) = try await session.data(for: req, delegate: stopper)
            guard let http = resp as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                  let loc = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: loc, relativeTo: url)?.absoluteURL else { break }
            url = next
        }
        throw XHSError("链接里找不到抖音作品 ID：\(url.absoluteString)")
    }

    // MARK: - 解析作品详情

    /// 视频的各个清晰度，最好的在前；每一档是同一份视频的几个镜像地址
    static func videoTiers(_ video: [String: Any]) -> [[URL]] {
        let rates = (video["bit_rate"] as? [[String: Any]] ?? []).filter {
            let f = ($0["format"] as? String ?? "mp4").lowercased()
            return f == "mp4" || f.isEmpty  // dash 是分段流，不能直接保存
        }
        func area(_ b: [String: Any]) -> Int {
            let p = b["play_addr"] as? [String: Any] ?? [:]
            return (p["width"] as? Int ?? 0) * (p["height"] as? Int ?? 0)
        }
        let sorted = rates.sorted {
            let (a1, a2) = (area($0), area($1))
            return a1 != a2 ? a1 > a2 : ($0["bit_rate"] as? Int ?? 0) > ($1["bit_rate"] as? Int ?? 0)
        }
        var tiers: [[URL]] = sorted.compactMap { b in
            let urls = ((b["play_addr"] as? [String: Any])?["url_list"] as? [String] ?? []).compactMap(URL.init)
            return urls.isEmpty ? nil : urls
        }
        let plain = ((video["play_addr"] as? [String: Any])?["url_list"] as? [String] ?? []).compactMap(URL.init)
        if !plain.isEmpty { tiers.append(plain) }
        return tiers
    }

    /// 网页里直接带的作品数据（登录后抖音把它写在页面里，不再请求接口）字段名是驼峰写法，
    /// 这里换成和接口一样的写法，后面统一交给 parse(detail:)
    static func detail(fromPage p: [String: Any]) -> [String: Any] {
        func str(_ v: Any?) -> String {
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return ""
        }
        /// 地址列表：元素可能是 {src: …} 也可能直接是字符串；「//」开头的补上 https
        func urls(_ v: Any?) -> [String] {
            (v as? [Any] ?? []).compactMap { e -> String? in
                let s = (e as? String) ?? ((e as? [String: Any])?["src"] as? String) ?? ""
                if s.isEmpty { return nil }
                return s.hasPrefix("//") ? "https:" + s : s
            }
        }
        func video(_ v: [String: Any]) -> [String: Any] {
            let rates: [[String: Any]] = (v["bitRateList"] as? [[String: Any]] ?? []).map { b in
                ["format": str(b["format"]).isEmpty ? str(b["videoFormat"]) : str(b["format"]),
                 "bit_rate": b["bitRate"] as? Int ?? 0,
                 "play_addr": ["url_list": urls(b["playAddr"]),
                               "width": b["width"] as? Int ?? 0, "height": b["height"] as? Int ?? 0] as [String: Any]]
            }
            var covers = urls(v["coverUrlList"])
            if covers.isEmpty, let c = v["cover"] as? String, !c.isEmpty { covers = [c] }
            return ["bit_rate": rates, "play_addr": ["url_list": urls(v["playAddr"])], "cover": ["url_list": covers]]
        }
        var d: [String: Any] = ["aweme_id": str(p["awemeId"]), "desc": str(p["desc"]), "item_title": str(p["itemTitle"])]
        if let t = p["createTime"] as? Double, t > 0 { d["create_time"] = t }
        if let a = p["authorInfo"] as? [String: Any] {
            d["author"] = ["nickname": str(a["nickname"]), "uid": str(a["uid"]), "sec_uid": str(a["secUid"]),
                           "unique_id": str(a["uniqueId"]), "short_id": str(a["shortId"])]
        }
        let images: [[String: Any]] = (p["images"] as? [[String: Any]] ?? []).map { im in
            var out: [String: Any] = ["url_list": urls(im["urlList"] ?? im["url_list"])]
            if let v = im["video"] as? [String: Any] { out["video"] = video(v) }
            return out
        }
        if !images.isEmpty { d["images"] = images }
        if let v = p["video"] as? [String: Any] { d["video"] = video(v) }
        return d
    }

    static func parse(detail d: [String: Any]) throws -> ParsedNote {
        let id = d["aweme_id"] as? String ?? ""
        var items: [NoteMedia] = []
        if let images = d["images"] as? [[String: Any]], !images.isEmpty {
            for im in images {
                let urls = (im["url_list"] as? [String] ?? []).compactMap(URL.init)
                // 同一张图有 jpeg 和 webp 两种地址，分辨率相同，优先 jpeg（相册兼容最好）
                let jpeg = urls.filter { $0.path.contains(".jpeg") || $0.path.contains(".jpg") }
                var item = NoteMedia(kind: .image, original: jpeg + urls.filter { !jpeg.contains($0) }, fallback: [])
                if let v = im["video"] as? [String: Any] {
                    let clips = videoTiers(v).flatMap { $0 }
                    if !clips.isEmpty {
                        item.kind = .live
                        item.liveVideoURLs = clips
                    }
                }
                if !item.original.isEmpty { items.append(item) }
            }
        } else if let v = d["video"] as? [String: Any] {
            let tiers = videoTiers(v)
            guard let best = tiers.first else { throw XHSError("没找到视频地址") }
            // 最高清晰度失败时，次一档要先问用户
            var item = NoteMedia(kind: .video, original: best, fallback: Array(tiers.dropFirst().prefix(2).joined()))
            // 预览用视频封面
            item.preview = (((v["cover"] as? [String: Any])?["url_list"] as? [String]) ?? []).compactMap(URL.init).first
            items.append(item)
        }
        if items.isEmpty { throw XHSError("这个作品里没找到可保存的内容") }
        let desc = (d["item_title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? d["desc"] as? String ?? ""
        var author: Author?
        if let a = d["author"] as? [String: Any] {
            func str(_ k: String) -> String {
                if let s = a[k] as? String { return s }
                if let n = a[k] as? NSNumber { return n.stringValue }
                return ""
            }
            // 相册名用抖音号（unique_id，没设置时是 short_id）；匹配时 uid、sec_uid 也算
            let douyinNo = str("unique_id").isEmpty ? str("short_id") : str("unique_id")
            let uid = str("uid")
            let ids = [douyinNo, uid, str("sec_uid")].filter { !$0.isEmpty }
            if !ids.isEmpty {
                author = Author(name: str("nickname"), primaryID: douyinNo.isEmpty ? uid : douyinNo, ids: ids,
                                idLabel: "抖音号")
            }
        }
        let published = (d["create_time"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return ParsedNote(platform: "抖音", id: id, title: desc, items: items, author: author,
                          published: published, referer: "https://www.douyin.com/")
    }
}

// MARK: - 内置浏览器读取作品详情

private final class CaptureHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((String) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let s = message.body as? String { onMessage?(s) }
    }
}

@MainActor
final class DouyinCapture: ObservableObject, Identifiable {
    let id = UUID()
    let account: WebAccount
    let target: Douyin.Ref
    let webView: WKWebView
    @Published var hint = "正在用抖音网页读取作品…"

    private let handler = CaptureHandler()
    private var continuation: CheckedContinuation<[String: Any], Error>?

    /// 在网页里复制一份作品详情接口的返回内容（只读，不改动请求）
    private static let hookJS = """
    (function () {
      var TARGET = /\\/aweme\\/v1\\/web\\/aweme\\/detail\\//;
      function send(u, t) { try { if (TARGET.test(u) && t) window.webkit.messageHandlers.xhsCapture.postMessage(t); } catch (e) {} }
      var of = window.fetch;
      if (of) {
        window.fetch = function () {
          var args = arguments;
          return of.apply(this, args).then(function (r) {
            try { var u = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url) || '';
                  if (TARGET.test(u)) r.clone().text().then(function (t) { send(u, t); }); } catch (e) {}
            return r;
          });
        };
      }
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__xhsu = String(u); return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        var x = this;
        x.addEventListener('load', function () {
          try {
            var t = (x.responseType === '' || x.responseType === 'text') ? x.responseText : JSON.stringify(x.response);
            send(x.__xhsu || '', t);
          } catch (e) {}
        });
        return os.apply(this, arguments);
      };
    })();
    """

    init(account: WebAccount, target: Douyin.Ref) {
        self.account = account
        self.target = target
        let config = WKWebViewConfiguration()
        config.websiteDataStore = account.dataStore
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(
            WKUserScript(source: Self.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        config.userContentController.add(handler, contentWorld: .page, name: "xhsCapture")
        webView = WKWebView(frame: .zero, configuration: config)
        handler.onMessage = { [weak self] text in
            Task { @MainActor in self?.received(text) }
        }
    }

    /// 两种打开方式，读到的是同一份作品数据：
    /// - modalURL（先用）：精选页上弹出这个作品。作品数据整份写在页面里，格式规整，能直接读出来
    /// - pageURL（备用）：作品页本身。登录后数据是分段夹在页面脚本里的，常常读不出来；未登录时它会去请求详情接口
    var pageURL: URL { URL(string: "https://www.douyin.com/\(target.kind)/\(target.id)")! }
    private var modalURL: URL { URL(string: "https://www.douyin.com/jingxuan?modal_id=\(target.id)")! }
    /// 已经看过几次网页里的数据（「重新加载」时清零）
    private var polls = 0

    /// 在网页自带的数据里找这个作品（登录后抖音把作品数据直接写在页面的 <script> 里，不再请求接口）。
    /// 找到就返回它的 JSON 文字，没找到返回空字符串。只读页面内容，不发请求
    private var scanJS: String {
        """
        (function (id) {
          function find(o, depth) {
            if (!o || typeof o !== 'object' || depth > 14) return null;
            if (!Array.isArray(o) && String(o.awemeId) === id && (o.video || (o.images && o.images.length))) return o;
            for (var k in o) { var v = o[k]; if (v && typeof v === 'object') { var r = find(v, depth + 1); if (r) return r; } }
            return null;
          }
          var ss = document.scripts;
          for (var i = 0; i < ss.length; i++) {
            var t = ss[i].textContent || '';
            if (t.indexOf(id) < 0) continue;
            var cands = [t];
            try { cands.push(decodeURIComponent(t)); } catch (e) {}
            for (var j = 0; j < cands.length; j++) {
              try { var r = find(JSON.parse(cands[j]), 0); if (r) return JSON.stringify(r); } catch (e) {}
            }
          }
          return '';
        })("\(target.id)")
        """
    }

    private func readPage() async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript(scanJS, in: nil, in: .page) { result in
                if case .success(let v) = result, let s = v as? String {
                    c.resume(returning: s)
                } else {
                    c.resume(returning: "")
                }
            }
        }
    }

    /// 接口那边没等到数据时，每隔一会儿看一眼网页里有没有
    private func pollPage() async {
        var started = false
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // 读取结束（拿到数据或取消）后停下；刚开始那一下 continuation 可能还没设好
            if continuation == nil {
                if started { return }
                continue
            }
            started = true
            polls += 1
            // 先用的是「精选页 + 作品浮层」的网址；等了一阵还没有，再换成作品页本身读一次
            if polls == 7 {
                hint = "换一种方式读取…"
                webView.load(URLRequest(url: pageURL))
                continue
            }
            let text = await readPage()
            guard !text.isEmpty,
                  let page = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            let detail = Douyin.detail(fromPage: page)
            if (detail["aweme_id"] as? String) == target.id {
                finish(.success(detail))
                return
            }
        }
    }

    func run() async throws -> [String: Any] {
        webView.load(URLRequest(url: modalURL))
        Task { [weak self] in await self?.pollPage() }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.continuation != nil else { return }
            self.hint = "还没拿到作品数据：可能需要登录或验证。请在下方页面里完成，再点「重新加载」。"
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func received(_ text: String) {
        guard continuation != nil,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let detail = obj["aweme_detail"] as? [String: Any],
              (detail["aweme_id"] as? String) == target.id else { return }
        finish(.success(detail))
    }

    func reload() {
        hint = "正在用抖音网页读取作品…"
        polls = 0
        webView.load(URLRequest(url: modalURL))
    }

    func cancel() {
        finish(.failure(XHSError.cancelled))
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "xhsCapture", contentWorld: .page)
        webView.stopLoading()
        c.resume(with: result)
    }
}

/// 读取作品时弹出的页面：能看到网页本身，需要验证时用户可以直接操作
struct DouyinCaptureView: View {
    @ObservedObject var capture: DouyinCapture

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
            .navigationTitle("抖音（\(capture.account.name)）")
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
