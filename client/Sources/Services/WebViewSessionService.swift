import Foundation
import WebKit

/// Extension-created WebViews (plan RT-14). An extension that builds an
/// `android.webkit.WebView` — typically hidden, as a JavaScript engine for
/// decrypting sources — gets a handle in its worker; the engine forwards its
/// operations here, and each session is an offscreen `WKWebView`:
///
/// * one view per session, with its own non-persistent website data store, so
///   sessions and extensions never share cookies or storage;
/// * `load` opens a web URL or an HTML page (with an optional web base URL);
///   only web navigations are allowed;
/// * `eval` runs a script in the page's global scope and returns the
///   JSON-encoded value, as Android's `evaluateJavascript` reports it;
/// * the names the extension registered with `addJavascriptInterface` exist in
///   the page as objects whose methods report their calls to the engine, which
///   invokes only `@JavascriptInterface` methods. Android returns values from
///   such calls synchronously; WebKit cannot, so they return `undefined`.
///
/// Nothing is shown. The engine bounds sessions, sizes and lifetimes.
@MainActor
final class WebViewSessionService {
    static let shared = WebViewSessionService()
    /// Matches the engine's own limit; a further session is refused.
    static let maxSessions = 16

    private var sessions: [String: Session] = [:]

    var sessionCount: Int { sessions.count }

    func handle(_ command: WebViewCommandDto, client: WebViewSessionClient = DaemonClient.shared) {
        switch command.op {
        case "load":
            let session: Session
            if let existing = sessions[command.session] {
                session = existing
            } else {
                guard sessions.count < Self.maxSessions else {
                    return reply(client, WebViewResultDto(commandId: command.commandId, error: "Too many WebView sessions"))
                }
                session = Session(id: command.session, client: client)
                sessions[command.session] = session
            }
            reply(client, WebViewResultDto(commandId: command.commandId, error: session.load(command)))
        case "eval":
            guard let session = sessions[command.session], let script = command.script else {
                return reply(client, WebViewResultDto(commandId: command.commandId, error: "Unknown WebView session"))
            }
            Task {
                let outcome = await session.evaluate(script)
                reply(client, WebViewResultDto(commandId: command.commandId, result: outcome.result, error: outcome.error))
            }
        case "destroy":
            sessions.removeValue(forKey: command.session)?.close()
            reply(client, WebViewResultDto(commandId: command.commandId))
        default:
            reply(client, WebViewResultDto(commandId: command.commandId, error: "Unknown WebView operation"))
        }
    }

    /// Engine generations cannot share sessions.
    func reset() {
        sessions.values.forEach { $0.close() }
        sessions.removeAll()
    }

    private func reply(_ client: WebViewSessionClient, _ result: WebViewResultDto) {
        Task.detached { try? await client.completeWebView(result) }
    }

    @MainActor
    final class Session: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandler = "csInterface"
        let id: String
        private let client: WebViewSessionClient
        private var webView: WKWebView?

        init(id: String, client: WebViewSessionClient) {
            self.id = id
            self.client = client
        }

        /// Returns an error message, or nil when the load started.
        func load(_ command: WebViewCommandDto) -> String? {
            let view = webView ?? makeView()
            install(interfaces: command.interfaces, in: view)
            if let agent = command.userAgent, !agent.isEmpty { view.customUserAgent = agent }
            if let html = command.html {
                let base = command.baseUrl.flatMap(URL.init(string:)).flatMap(Self.web)
                view.loadHTMLString(html, baseURL: base)
                return nil
            }
            guard let url = command.url.flatMap(URL.init(string:)).flatMap(Self.web) else { return "WebView load needs a web URL" }
            view.load(URLRequest(url: url))
            return nil
        }

        func evaluate(_ script: String) async -> (result: String?, error: String?) {
            guard let webView else { return (nil, "The page is not loaded") }
            // Global scope (indirect eval) and the completion value of the
            // script, JSON-encoded; a throwing script yields null, as on Android.
            guard let literal = String(data: (try? JSONEncoder().encode(script)) ?? Data(), encoding: .utf8) else { return (nil, "Invalid script") }
            let wrapped = """
            (function () { try { var v = (0, eval)(\(literal)); var s = JSON.stringify(v === undefined ? null : v); return s === undefined ? "null" : s; } catch (e) { return "null"; } })()
            """
            do {
                let value = try await webView.evaluateJavaScript(wrapped)
                return ((value as? String) ?? "null", nil)
            } catch {
                return ("null", nil)
            }
        }

        func close() {
            webView?.navigationDelegate = nil
            webView?.stopLoading()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandler)
            webView = nil
        }

        private func makeView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            configuration.userContentController.add(WeakMessageHandler(self), name: Self.messageHandler)
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
            view.navigationDelegate = self
            webView = view
            return view
        }

        /// One object per registered name; each method call is reported.
        private func install(interfaces: [String], in view: WKWebView) {
            let controller = view.configuration.userContentController
            controller.removeAllUserScripts()
            let names = interfaces.filter { $0.range(of: "^[A-Za-z_$][A-Za-z0-9_$]{0,63}$", options: .regularExpression) != nil }
            guard !names.isEmpty, let json = String(data: (try? JSONEncoder().encode(names)) ?? Data(), encoding: .utf8) else { return }
            let source = """
            (function () {
              var names = \(json);
              names.forEach(function (name) {
                window[name] = new Proxy({}, { get: function (_, method) {
                  if (typeof method !== "string") { return undefined; }
                  return function () {
                    var args = Array.prototype.slice.call(arguments).map(function (a) { return a === undefined || a === null ? "" : String(a); });
                    window.webkit.messageHandlers.\(Self.messageHandler).postMessage({ name: name, method: method, args: args });
                  };
                } });
              });
            })();
            """
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        private static func web(_ url: URL) -> URL? {
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil ? url : nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let scheme = url.scheme?.lowercased() ?? ""
            return ["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(WebViewEventPayload(kind: "finished", url: webView.url?.absoluteString))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let name = body["name"] as? String, let method = body["method"] as? String else { return }
            let args = (body["args"] as? [Any])?.prefix(16).map { String(describing: $0) } ?? []
            report(WebViewEventPayload(kind: "call", name: name, method: method, args: Array(args)))
        }

        private func report(_ event: WebViewEventPayload) {
            let dto = WebViewEventDto(session: id, event: event)
            let client = client
            Task.detached { try? await client.reportWebView(dto) }
        }
    }

    /// The content controller retains its handler; the session must not be kept alive by it.
    private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}
