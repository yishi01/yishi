import Foundation
import SwiftUI
import UIKit
import WebKit

/// Persistent per-tab native WKWebView controller so browsing runs at 120Hz directly on iPhone
/// while the PC Agent can execute light DOM RPC commands over WebSocket.
@MainActor
final class BrowserTabController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let browserId: String
    let webView: WKWebView

    @Published var currentURL: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0

    var isExecutingAgentRPC: Bool = false
    var onHumanNavigationSettled: ((BrowserTabController) -> Void)?

    private var urlObs: NSKeyValueObservation?
    private var titleObs: NSKeyValueObservation?
    private var backObs: NSKeyValueObservation?
    private var fwdObs: NSKeyValueObservation?
    private var loadObs: NSKeyValueObservation?
    private var progObs: NSKeyValueObservation?

    init(browserId: String) {
        self.browserId = browserId
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = .white
        self.webView = wv
        super.init()

        wv.navigationDelegate = self
        wv.uiDelegate = self
        setupObservers()
    }

    private func setupObservers() {
        urlObs = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            let str = wv.url?.absoluteString ?? ""
            Task { @MainActor [weak self] in
                self?.currentURL = str
            }
        }
        titleObs = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            let t = wv.title ?? ""
            Task { @MainActor [weak self] in
                if !t.isEmpty { self?.pageTitle = t }
            }
        }
        backObs = webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            let v = wv.canGoBack
            Task { @MainActor [weak self] in
                self?.canGoBack = v
            }
        }
        fwdObs = webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            let v = wv.canGoForward
            Task { @MainActor [weak self] in
                self?.canGoForward = v
            }
        }
        loadObs = webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            let v = wv.isLoading
            Task { @MainActor [weak self] in
                self?.isLoading = v
            }
        }
        progObs = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            let v = wv.estimatedProgress
            Task { @MainActor [weak self] in
                self?.estimatedProgress = v
            }
        }
    }

    // MARK: - WKNavigationDelegate & WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url?.absoluteString ?? currentURL
        if let t = webView.title, !t.isEmpty {
            pageTitle = t
        }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if !isExecutingAgentRPC {
            onHumanNavigationSettled?(self)
        }
    }

    // MARK: - Async Control & DOM RPC

    private static func normalizedWebURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.lowercased() == "about:blank" {
            return URL(string: "about:blank")
        }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }

    private func waitForPageSettle(maxSeconds: Double = 6.5) async {
        let deadline = Date().addingTimeInterval(maxSeconds)
        try? await Task.sleep(nanoseconds: 350_000_000)
        while webView.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
    }

    func loadURL(_ raw: String, waitForSettle: Bool = true) async -> [String: Any] {
        guard let url = Self.normalizedWebURL(raw) else {
            return ["ok": false, "error": "无效网页地址: \(raw)"]
        }
        currentURL = url.absoluteString
        webView.load(URLRequest(url: url))
        if waitForSettle {
            await waitForPageSettle()
        }
        return await runSnapshotJS()
    }

    func goBack(waitForSettle: Bool = true) async -> [String: Any] {
        if webView.canGoBack {
            webView.goBack()
            if waitForSettle { await waitForPageSettle(maxSeconds: 5.0) }
        }
        return await runSnapshotJS()
    }

    func goForward(waitForSettle: Bool = true) async -> [String: Any] {
        if webView.canGoForward {
            webView.goForward()
            if waitForSettle { await waitForPageSettle(maxSeconds: 5.0) }
        }
        return await runSnapshotJS()
    }

    func reload(waitForSettle: Bool = true) async -> [String: Any] {
        webView.reload()
        if waitForSettle { await waitForPageSettle(maxSeconds: 6.0) }
        return await runSnapshotJS()
    }

    func clickElement(id: Int) async -> [String: Any] {
        let js = """
        (function(){
          var el = document.querySelector('[data-ds-id="\(id)"]');
          if (!el) return JSON.stringify({ok:false, error:'未找到编号为 [\(id)] 的交互元素'});
          try { el.scrollIntoView({block:'center', inline:'nearest'}); } catch(e) {}
          try { el.focus(); } catch(e) {}
          el.click();
          return JSON.stringify({ok:true});
        })();
        """
        _ = try? await webView.evaluateJavaScript(js)
        await waitForPageSettle(maxSeconds: 5.0)
        return await runSnapshotJS()
    }

    func typeText(id: Int?, text: String, submit: Bool) async -> [String: Any] {
        let b64 = Data(text.utf8).base64EncodedString()
        let targetExpr = id != nil
            ? "document.querySelector('[data-ds-id=\"\(id!)\"]')"
            : "(document.activeElement && ['INPUT','TEXTAREA','SELECT'].includes(document.activeElement.tagName) ? document.activeElement : document.querySelector('input:not([type=hidden]),textarea,select'))"
        let js = """
        (function(){
          var el = \(targetExpr);
          if (!el) return JSON.stringify({ok:false, error:'未找到目标输入框'});
          try { el.scrollIntoView({block:'center'}); el.focus(); } catch(e) {}
          var raw = decodeURIComponent(escape(atob('\(b64)')));
          var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var desc = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
          if (desc && desc.set) { desc.set.call(el, raw); } else { el.value = raw; }
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
          if (\(submit ? "true" : "false")) {
            if (el.form) {
              if (typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
              else el.form.submit();
            } else {
              el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true}));
            }
          }
          return JSON.stringify({ok:true});
        })();
        """
        _ = try? await webView.evaluateJavaScript(js)
        if submit {
            await waitForPageSettle(maxSeconds: 5.5)
        } else {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return await runSnapshotJS()
    }

    func scroll(deltaY: Int) async -> [String: Any] {
        let js = "window.scrollBy({top: \(deltaY), behavior: 'smooth'}); true;"
        _ = try? await webView.evaluateJavaScript(js)
        try? await Task.sleep(nanoseconds: 280_000_000)
        return await runSnapshotJS()
    }

    func runSnapshotJS() async -> [String: Any] {
        let js = """
        (function(){
          try {
            var els = [];
            var nodes = document.querySelectorAll('a[href],button,input:not([type=hidden]),textarea,select,[role=button]');
            var nextId = 1;
            for (var i = 0; i < nodes.length && els.length < 50; i++) {
              var n = nodes[i];
              var r = n.getBoundingClientRect();
              if (r.width < 2 || r.height < 2) continue;
              var st = window.getComputedStyle(n);
              if (st && (st.display === 'none' || st.visibility === 'hidden')) continue;
              var tid = nextId++;
              n.setAttribute('data-ds-id', String(tid));
              var tag = (n.tagName || '').toLowerCase();
              var tp = tag === 'a' ? 'link' : (n.getAttribute('type') || tag);
              var txt = (n.innerText || n.textContent || n.getAttribute('aria-label') || n.getAttribute('placeholder') || '').replace(/\\s+/g, ' ').trim().slice(0, 80);
              var val = (n.type === 'password') ? '' : String(n.value || '').slice(0, 80);
              els.push({
                id: tid,
                tag: tag,
                type: tp,
                text: txt,
                href: tag === 'a' ? (n.href || '') : '',
                value: val,
                bbox: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]
              });
            }
            var bodyTxt = (document.body ? (document.body.innerText || '') : '').replace(/\\n{3,}/g, '\\n\\n').trim().slice(0, 8500);
            var lowerTxt = (bodyTxt + ' ' + (document.documentElement ? document.documentElement.innerHTML.slice(0, 12000) : '')).toLowerCase();
            var humanReq = false;
            var humanReason = '';
            if (document.querySelector('input[type="password"]')) {
              humanReq = true; humanReason = '检测到密码登录表单，需真人操作';
            } else if (lowerTxt.indexOf('cf-turnstile') >= 0 || lowerTxt.indexOf('challenges.cloudflare.com') >= 0 || lowerTxt.indexOf('g-recaptcha') >= 0 || lowerTxt.indexOf('hcaptcha') >= 0 || lowerTxt.indexOf('verify you are human') >= 0 || lowerTxt.indexOf('正在验证') >= 0 || lowerTxt.indexOf('人机验证') >= 0) {
              humanReq = true; humanReason = '检测到 Cloudflare / 人机验证，需真人点击确认';
            }
            return JSON.stringify({
              ok: true,
              url: window.location.href || '',
              title: document.title || '',
              scroll_y: Math.round(window.scrollY || 0),
              elements: els,
              text_markdown: bodyTxt,
              human_required: humanReq,
              human_reason: humanReason
            });
          } catch(err) {
            return JSON.stringify({ok: false, error: String(err)});
          }
        })();
        """

        var parsed: [String: Any] = [:]
        if let raw = try? await webView.evaluateJavaScript(js) as? String,
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsed = obj
        }
        if (parsed["url"] as? String)?.isEmpty != false {
            parsed["url"] = webView.url?.absoluteString ?? currentURL
        }
        if (parsed["title"] as? String)?.isEmpty != false {
            parsed["title"] = webView.title ?? pageTitle
        }
        parsed["can_go_back"] = webView.canGoBack
        parsed["can_go_forward"] = webView.canGoForward
        parsed["mode"] = "mobile_wkwebview"
        return parsed
    }

    func captureSnapshotJPEG() async -> Data? {
        let config = WKSnapshotConfiguration()
        if let image = try? await webView.takeSnapshot(configuration: config) {
            return image.jpegData(compressionQuality: 0.85)
        }
        return nil
    }
}

/// Registry managing persistent WKWebView tabs across the app lifecycle.
@MainActor
final class MobileBrowserManager: ObservableObject {
    static let shared = MobileBrowserManager()

    private var tabs: [String: BrowserTabController] = [:]
    var onHumanNavigationSettled: ((String, [String: Any]) -> Void)?

    private init() {}

    func tab(for browserId: String) -> BrowserTabController {
        if let existing = tabs[browserId] {
            return existing
        }
        let created = BrowserTabController(browserId: browserId)
        created.onHumanNavigationSettled = { [weak self] controller in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let snap = await controller.runSnapshotJS()
                self.onHumanNavigationSettled?(controller.browserId, snap)
            }
        }
        tabs[browserId] = created
        return created
    }

    func removeTab(_ browserId: String) {
        tabs.removeValue(forKey: browserId)
    }

    func executeRPC(
        browserId: String,
        action: String,
        params: [String: Any],
        uploadScreenshot: ((Data, String) async -> ChatAttachmentItem?)? = nil
    ) async -> [String: Any] {
        let controller = tab(for: browserId)
        controller.isExecutingAgentRPC = true
        defer { controller.isExecutingAgentRPC = false }

        switch action.lowercased() {
        case "navigate", "open":
            let url = (params["url"] as? String) ?? ""
            return await controller.loadURL(url, waitForSettle: true)
        case "back":
            return await controller.goBack(waitForSettle: true)
        case "forward":
            return await controller.goForward(waitForSettle: true)
        case "reload":
            return await controller.reload(waitForSettle: true)
        case "click":
            if let eid = params["element_id"] as? Int {
                return await controller.clickElement(id: eid)
            }
            return await controller.runSnapshotJS()
        case "type":
            let txt = (params["text"] as? String) ?? ""
            let eid = params["element_id"] as? Int
            let submit = (params["submit"] as? Bool) ?? false
            return await controller.typeText(id: eid, text: txt, submit: submit)
        case "scroll":
            let dy = (params["delta_y"] as? Int) ?? 360
            return await controller.scroll(deltaY: dy)
        case "screenshot":
            var snap = await controller.runSnapshotJS()
            if let jpeg = await controller.captureSnapshotJPEG(),
               let uploader = uploadScreenshot,
               let att = await uploader(jpeg, "web_\(browserId).jpg") {
                snap["screenshot_att_id"] = att.attId
                snap["ok"] = true
            }
            return snap
        default:
            return await controller.runSnapshotJS()
        }
    }
}
