import Foundation

/// Network access for updates: the release lookup and the disk-image
/// download. Ephemeral (no cookies, cache or credentials), HTTPS to GitHub's
/// hosts only, including every redirect.
final class UpdateNetwork: Sendable {
    let trustedHosts: Set<String>
    private let userAgent: String

    enum NetworkError: LocalizedError, Equatable {
        case status(Int)
        case rateLimited
        case untrustedRedirect(String)
        case sizeMismatch(expected: Int64, actual: Int64)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .status(let code): "GitHub answered with HTTP \(code)."
            case .rateLimited: "GitHub is limiting update checks from this network. Try again later."
            case .untrustedRedirect(let host): "The download was redirected to a host that isn’t GitHub (\(host))."
            case .sizeMismatch(let expected, let actual):
                "The download was incomplete (\(actual.formatted(.byteCount(style: .file))) of \(expected.formatted(.byteCount(style: .file))))."
            case .tooLarge: "The download is larger than the release said it would be."
            }
        }
    }

    init(trustedHosts: Set<String> = UpdateFeed.trustedHosts,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.trustedHosts = trustedHosts
        self.userAgent = "CloudStream-macOS/\(version) (update check)"
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.waitsForConnectivity = false
        return configuration
    }

    private func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        return request
    }

    /// GET a small JSON or text document (at most 1 MiB).
    func data(from url: URL, accept: String = "application/vnd.github+json") async throws -> Data {
        guard UpdateFeed.isTrusted(url, hosts: trustedHosts) else { throw UpdateFeed.FeedError.untrustedURL(url.absoluteString) }
        let guardDelegate = RedirectGuard(hosts: trustedHosts)
        let session = URLSession(configuration: configuration(), delegate: guardDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request(url, accept: accept))
        if let host = guardDelegate.refusedHost { throw NetworkError.untrustedRedirect(host) }
        guard let http = response as? HTTPURLResponse else { throw NetworkError.status(0) }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 || http.statusCode == 429,
               http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.statusCode == 429 {
                throw NetworkError.rateLimited
            }
            throw NetworkError.status(http.statusCode)
        }
        guard data.count <= 1024 * 1024 else { throw NetworkError.tooLarge }
        return data
    }

    /// Downloads `asset` to `destination` (replaced if present), reporting
    /// progress as a fraction. Cancelling the calling task cancels the
    /// transfer and removes any partial file.
    func download(_ asset: UpdateRelease.Asset, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UpdateFeed.isTrusted(asset.url, hosts: trustedHosts) else { throw UpdateFeed.FeedError.untrustedURL(asset.url.absoluteString) }
        let delegate = DownloadDelegate(hosts: trustedHosts, expectedBytes: asset.size, destination: destination, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: request(asset.url, accept: "application/octet-stream"))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Refuses redirects off the trusted hosts (or off HTTPS).
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let hosts: Set<String>
    private let lock = NSLock()
    private var refused: String?
    var refusedHost: String? { lock.withLock { refused } }

    init(hosts: Set<String>) { self.hosts = hosts }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if UpdateFeed.isTrusted(request.url, hosts: hosts) {
            completionHandler(request)
        } else {
            lock.withLock { refused = request.url?.host ?? "unknown" }
            completionHandler(nil)
        }
    }
}

/// One download. Delegate callbacks arrive on the session's serial queue;
/// `continuation` is set before the task starts and resumed exactly once.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let hosts: Set<String>
    private let expectedBytes: Int64
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var lastReported = -1.0

    init(hosts: Set<String>, expectedBytes: Int64, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.hosts = hosts
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if UpdateFeed.isTrusted(request.url, hosts: hosts) {
            completionHandler(request)
        } else {
            failure = UpdateNetwork.NetworkError.untrustedRedirect(request.url?.host ?? "unknown")
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes {
            failure = UpdateNetwork.NetworkError.tooLarge
            downloadTask.cancel()
            return
        }
        let fraction = min(1, Double(totalBytesWritten) / Double(max(expectedBytes, 1)))
        // About 200 updates over a whole download, not one per packet.
        if fraction - lastReported >= 0.005 || fraction == 1 {
            lastReported = fraction
            progress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns: check and move it now.
        guard failure == nil else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = UpdateNetwork.NetworkError.status(http.statusCode)
            return
        }
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard size == expectedBytes else {
            failure = UpdateNetwork.NetworkError.sizeMismatch(expected: expectedBytes, actual: max(size, 0))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = failure ?? error
        if result != nil { try? FileManager.default.removeItem(at: destination) }
        guard let continuation else { return }
        self.continuation = nil
        if let result {
            continuation.resume(throwing: (result as? URLError)?.code == .cancelled && failure == nil ? CancellationError() : result)
        } else {
            continuation.resume()
        }
    }
}
