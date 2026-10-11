import Foundation
import WebKit

/// Offscreen WebKit bridge that clears anti-bot challenges on behalf of the
/// Kotlin daemon (Architecture.md §5.2).
///
/// When a scrape hits a Cloudflare Turnstile / JS challenge, the daemon parks
/// the request and the Swift client drives a real WebKit engine through it:
/// 1. An offscreen `WKWebView` loads the challenged URL with a genuine Safari
///    user agent.
/// 2. Page scripts run until the clearance cookie (`cf_clearance`) lands in the
///    shared cookie store.
/// 3. The cookies are POSTed to `/solve-callback`, completing the parked scrape.
///
/// Clearance is bound to the User-Agent that earned it, so the page is loaded
/// with the challenged request's own agent. A clearance is reused for further
/// challenges of the same site and agent while it is fresh. Like Android's
/// CloudflareKiller this never shows anything: a challenge that wants a person
/// times out and that source is simply missing. Every attempt is logged with
/// its outcome.
@MainActor
@Observable
final class WebViewSolverService: NSObject, WKNavigationDelegate {
    static let shared = WebViewSolverService()

    private(set) var isSolving = false
    private var webView: WKWebView?
    private var deadline: Date?
    private var websiteDataStore = WKWebsiteDataStore.nonPersistent()
    private var attempt: UUID?
    private var pollTask: Task<Void, Never>?
    private var startedAt = Date()
    private var host = ""
    /// Fresh clearances by "host|agent", reused instead of a new page load.
    private var clearances: [String: (cookies: String, until: Date)] = [:]

    private override init() {
        super.init()
    }

    func canSolve(targetUrl: String) -> Bool {
        guard let url = URL(string: targetUrl), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }

    @discardableResult
    func solve(taskId: String, targetUrl: String, userAgent: String? = nil, timeout: TimeInterval = 30) -> Bool {
        guard !isSolving, canSolve(targetUrl: targetUrl), let url = URL(string: targetUrl) else { return false }
        let host = url.host?.lowercased() ?? ""
        let agent = userAgent.flatMap { $0.isEmpty ? nil : $0 } ?? safariUserAgent
        if let reuse = clearances["\(host)|\(agent)"], reuse.until > Date() {
            DaemonLog.client("solve.reused", fields: ["host": host])
            Task { try? await DaemonClient.shared.submitSolve(taskId: taskId, targetUrl: targetUrl, cookies: reuse.cookies) }
            return true
        }
        self.host = host
        startedAt = Date()
        DaemonLog.client("solve.started", fields: ["host": host])
        let attempt = UUID()
        self.attempt = attempt
        websiteDataStore = WKWebsiteDataStore.nonPersistent()
        isSolving = true
        deadline = Date().addingTimeInterval(timeout)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = agent
        self.webView = webView

        webView.load(URLRequest(url: url))
        pollForClearance(taskId: taskId, targetUrl: targetUrl, agent: agent, attempt: attempt)
        return true
    }

    /// Polls the shared cookie store until a clearance cookie appears, then
    /// reports it to the daemon and tears the (offscreen) web view down.
    private func pollForClearance(taskId: String, targetUrl: String, agent: String, attempt: UUID) {
        pollTask = Task { [weak self] in
            while let self, self.attempt == attempt, !Task.isCancelled {
                if let deadline = self.deadline, Date() > deadline {
                    self.finish(attempt: attempt, outcome: "timeout")
                    return
                }
                let cookies = await self.clearanceCookies(for: targetUrl)
                guard self.attempt == attempt, !Task.isCancelled else { return }
                if let cookies, !cookies.isEmpty {
                    self.clearances["\(self.host)|\(agent)"] = (cookies, Date().addingTimeInterval(4 * 60))
                    do {
                        try await DaemonClient.shared.submitSolve(taskId: taskId, targetUrl: targetUrl, cookies: cookies)
                    } catch { /* The waiting daemon retains its own bounded deadline. */ }
                    self.finish(attempt: attempt, outcome: "cleared")
                    return
                }
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            }
        }
    }

    /// Engine generations cannot share a solve attempt or website data store.
    func reset() {
        if let attempt { finish(attempt: attempt, outcome: "reset") }
        clearances.removeAll()
        websiteDataStore = WKWebsiteDataStore.nonPersistent()
    }

    private func finish(attempt: UUID, outcome: String) {
        guard self.attempt == attempt else { return }
        DaemonLog.client("solve.finished", fields: ["host": host, "outcome": outcome, "seconds": String(Int(Date().timeIntervalSince(startedAt)))])
        self.attempt = nil
        pollTask?.cancel()
        pollTask = nil
        isSolving = false
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        deadline = nil
    }

    private func clearanceCookies(for targetUrl: String) async -> String? {
        guard let url = URL(string: targetUrl) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let store = websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        let chosen = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matchesDomain = cookie.domain.hasPrefix(".") ? (host == domain || host.hasSuffix("." + domain)) : host == domain
            // Only root-scoped clearance can safely be reused by the daemon
            // for this origin. Never export login/session or path-limited cookies.
            return !host.isEmpty && matchesDomain && cookie.name == "cf_clearance" && cookie.path == "/" &&
                (cookie.expiresDate.map { $0 > Date() } ?? true) &&
                cookie.value.utf8.count <= 4000 && cookie.value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 && $0 != ";" }
        }
        guard !chosen.isEmpty else { return nil }
        return chosen
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            // SEC-05: Offscreen challenge solver may only navigate to HTTPS or about: URLs, preventing external app handoffs
            decisionHandler(["https", "about"].contains(scheme) ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Let the challenge script complete its run inside the page.
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, self.webView === webView, let attempt = self.attempt else { return }
            self.finish(attempt: attempt, outcome: "navigation_failed")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, self.webView === webView, let attempt = self.attempt else { return }
            self.finish(attempt: attempt, outcome: "navigation_failed")
        }
    }

    /// Only when the engine did not say which agent was challenged.
    private var safariUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    }
}
