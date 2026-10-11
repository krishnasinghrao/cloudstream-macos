import Foundation
import WebKit

/// Native JavaScript media resolution (plan RT-11). An extension's
/// `WebViewResolver` asks the engine for a page load; the engine parks it and
/// this service runs it in an offscreen `WKWebView`:
///
/// 1. Each task gets its own non-persistent website data store, so two
///    extensions (or two tasks) never share cookies or storage.
/// 2. A document-start script in every frame reports the requests the page
///    makes (fetch, XHR, media/source/iframe `src`, and resource timing
///    entries); navigations are reported by the navigation delegate.
/// 3. Reports go to the engine, which matches the extension's patterns and
///    answers `stop` at the intercept match. The page's script result and the
///    cookies of the hosts it used are returned on completion.
///
/// WebKit does not expose every request to page scripts or delegates; what is
/// not observed is not reported, and the extension sees no match rather than
/// a fabricated one.
@MainActor
final class MediaResolverService {
    static let shared = MediaResolverService()
    static let maxConcurrent = 2

    private var sessions: [String: Session] = [:]

    private init() {}

    var activeTaskIds: Set<String> { Set(sessions.keys) }

    func start(_ task: MediaPendingDto, client: MediaResolveClient = DaemonClient.shared) {
        guard sessions[task.taskId] == nil, sessions.count < Self.maxConcurrent, task.timeoutMs > 0,
              let url = URL(string: task.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return }
        let session = Session(task: task, url: url, client: client) { [weak self] id in self?.sessions[id] = nil }
        sessions[task.taskId] = session
        session.begin()
    }

    /// Engine generations cannot share page sessions.
    func reset() {
        sessions.values.forEach { $0.cancel() }
        sessions.removeAll()
    }

    /// One page load. Owned by the service until it finishes.
    @MainActor
    final class Session: NSObject, WKNavigationDelegate {
        private let task: MediaPendingDto
        private let url: URL
        private let client: MediaResolveClient
        private let onFinish: (String) -> Void
        private let store = WKWebsiteDataStore.nonPersistent()
        private var webView: WKWebView?
        private var buffer: [MediaObservedRequestDto] = []
        private var hosts: [String] = []
        private var reported = Set<String>()
        private var scriptResult: String?
        private var flushTask: Task<Void, Never>?
        private var deadlineTask: Task<Void, Never>?
        private var finished = false

        init(task: MediaPendingDto, url: URL, client: MediaResolveClient, onFinish: @escaping (String) -> Void) {
            self.task = task
            self.url = url
            self.client = client
            self.onFinish = onFinish
        }

        func begin() {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            configuration.mediaTypesRequiringUserActionForPlayback = []
            let handler = MessageHandler { [weak self] url, method in self?.observe(url, method: method) }
            configuration.userContentController.add(handler, name: MessageHandler.name)
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
            webView.navigationDelegate = self
            webView.customUserAgent = task.userAgent ?? Self.safariUserAgent
            self.webView = webView

            var request = URLRequest(url: url)
            request.httpMethod = task.method == "POST" ? "POST" : "GET"
            if request.httpMethod == "POST" { request.httpBody = Data() }
            for (name, value) in task.headers { request.setValue(value, forHTTPHeaderField: name) }
            webView.load(request)

            flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !self.finished else { return }
                    await self.flush()
                }
            }
            let timeout = Double(task.timeoutMs) / 1000
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled else { return }
                await self.complete()
            }
        }

        private func observe(_ raw: String, method: String) {
            guard !finished, raw.count <= 8192, let parsed = URL(string: raw),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), reported.insert(raw).inserted,
                  reported.count <= 5000 else { return }
            if let host = parsed.host?.lowercased(), !hosts.contains(host) { hosts.append(host) }
            buffer.append(MediaObservedRequestDto(url: raw, method: method))
        }

        private func flush() async {
            guard !buffer.isEmpty, !finished else { return }
            let batch = buffer
            buffer.removeAll()
            guard let response = try? await client.observeMedia(taskId: task.taskId, requests: batch) else { return }
            if !response.known { cancel() } else if response.stop { await complete() }
        }

        /// Reports remaining requests, the script result and cookies, then tears down.
        private func complete() async {
            guard !finished else { return }
            await flush()
            guard !finished else { return }
            finished = true
            let cookies = await cookieHeaders()
            let pageUrl = webView?.url?.absoluteString
            let userAgent = webView?.customUserAgent
            try? await client.completeMedia(MediaCompleteRequestDto(
                taskId: task.taskId, scriptResult: scriptResult, cookies: cookies, userAgent: userAgent, pageUrl: pageUrl))
            tearDown()
        }

        func cancel() {
            guard !finished else { return }
            finished = true
            tearDown()
        }

        private func tearDown() {
            flushTask?.cancel()
            deadlineTask?.cancel()
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil
            onFinish(task.taskId)
        }

        /// Cookies of this session's own ephemeral store, per host the page used (bounded).
        private func cookieHeaders() async -> [String: String] {
            let all = await store.httpCookieStore.allCookies()
            var result: [String: String] = [:]
            for host in (hosts + [url.host?.lowercased()].compactMap { $0 }).suffix(16) {
                let matching = all.filter { cookie in
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let hostMatches = cookie.domain.hasPrefix(".") ? (host == domain || host.hasSuffix("." + domain)) : host == domain
                    return hostMatches && (cookie.expiresDate.map { $0 > Date() } ?? true) &&
                        cookie.value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 && $0 != ";" }
                }
                let header = matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                if !header.isEmpty, header.utf8.count <= 8000 { result[host] = header }
            }
            return result
        }

        // MARK: Navigation

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            MainActor.assumeIsolated {
                let url = navigationAction.request.url
                let method = navigationAction.request.httpMethod ?? "GET"
                let scheme = url?.scheme?.lowercased() ?? ""
                if let url { self.observe(url.absoluteString, method: method) }
                // Pages may not hand off to other apps or local files.
                decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                guard let script = self.task.script, !self.finished, self.scriptResult == nil else { return }
                webView.evaluateJavaScript(script) { [weak self] value, error in
                    MainActor.assumeIsolated {
                        guard let self, !self.finished else { return }
                        // Android hands scriptCallback the JSON encoding of the value.
                        self.scriptResult = error == nil ? Self.jsonValue(value) : "null"
                    }
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}

        static func jsonValue(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "null" }
            if let string = value as? String {
                let data = try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed])
                return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "null"
            }
            if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue }
            if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) {
                return String(data: data, encoding: .utf8) ?? "null"
            }
            return "null"
        }

        static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

        /// Reports requests made by page scripts and media elements, in every frame.
        static let captureScript = """
        (() => {
          if (window.__csCapture) return; window.__csCapture = true;
          const report = (u, m) => {
            try {
              if (!u) return;
              const href = new URL(String(u), document.baseURI).href;
              window.webkit.messageHandlers.\(MessageHandler.name).postMessage({ u: href, m: String(m || 'GET').toUpperCase() });
            } catch (e) {}
          };
          const fetch0 = window.fetch;
          if (fetch0) window.fetch = function (input, init) {
            try { report(typeof input === 'string' ? input : (input && input.url) || input, (init && init.method) || (input && input.method)); } catch (e) {}
            return fetch0.apply(this, arguments);
          };
          const open0 = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) { report(url, method); return open0.apply(this, arguments); };
          for (const proto of [HTMLMediaElement.prototype, HTMLSourceElement.prototype, HTMLIFrameElement.prototype]) {
            const d = Object.getOwnPropertyDescriptor(proto, 'src');
            if (d && d.set) Object.defineProperty(proto, 'src', { configurable: true, enumerable: d.enumerable, get: d.get,
              set(v) { report(v); return d.set.call(this, v); } });
          }
          const setAttribute0 = Element.prototype.setAttribute;
          Element.prototype.setAttribute = function (name, value) {
            if (String(name).toLowerCase() === 'src' && (this instanceof HTMLMediaElement || this instanceof HTMLSourceElement || this instanceof HTMLIFrameElement)) report(value);
            return setAttribute0.apply(this, arguments);
          };
          try { new PerformanceObserver(list => list.getEntries().forEach(e => report(e.name))).observe({ type: 'resource', buffered: true }); } catch (e) {}
        })();
        """
    }

    /// Separate object: a user content controller retains its handlers.
    final class MessageHandler: NSObject, WKScriptMessageHandler {
        static let name = "csObserve"
        private let onRequest: @MainActor (String, String) -> Void

        init(onRequest: @escaping @MainActor (String, String) -> Void) { self.onRequest = onRequest }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let url = body["u"] as? String else { return }
            let method = (body["m"] as? String).map { String($0.prefix(7)) } ?? "GET"
            MainActor.assumeIsolated { onRequest(url, method) }
        }
    }
}
