import Foundation
import Synchronization

/// Loads small remote resources (artwork, subtitle sidecars) into memory with
/// a hard byte budget enforced while the body is received — never after a
/// whole body has already been buffered.
enum BoundedHTTPResource {
    enum Failure: Error, Equatable {
        case invalidURL
        case status(Int)
        /// Declared or received bytes exceeded the budget.
        case tooLarge
        case redirectRejected
        case unexpectedContentType
        case empty
        case transport(URLError.Code)
    }

    /// Named initial budgets; tune from measured valid artwork, not guesses.
    static let imageBytes = 32 * 1_048_576
    static let subtitleBytes = 5 * 1_048_576

    /// One session for every bounded load: no response cache (the caller owns
    /// caching) and a small per-host connection count.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// - Parameter acceptsContentType: receives the lowercased MIME type, or
    ///   nil when the server sent none.
    static func load(
        _ request: URLRequest,
        maxBytes: Int,
        acceptsContentType: (@Sendable (String?) -> Bool)? = nil,
        session: URLSession = BoundedHTTPResource.session,
    ) async throws -> Data {
        guard let url = request.url, isAllowed(url) else { throw Failure.invalidURL }
        let receiver = Receiver(maxBytes: maxBytes, acceptsContentType: acceptsContentType, original: request)
        let task = session.dataTask(with: request)
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func isAllowed(_ url: URL) -> Bool {
        (try? MediaResourcePolicy.remoteURL(url.absoluteString)) != nil
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, Sendable {
        private struct State {
            var data = Data()
            var failure: Failure?
            var continuation: CheckedContinuation<Data, Error>?
        }
        private let state = Mutex(State())
        private let maxBytes: Int
        private let acceptsContentType: (@Sendable (String?) -> Bool)?
        private let original: URLRequest

        init(maxBytes: Int, acceptsContentType: (@Sendable (String?) -> Bool)?, original: URLRequest) {
            self.maxBytes = maxBytes
            self.acceptsContentType = acceptsContentType
            self.original = original
        }

        func start(_ continuation: CheckedContinuation<Data, Error>) {
            state.withLock { $0.continuation = continuation }
        }

        private func reject(_ failure: Failure, _ task: URLSessionTask) {
            state.withLock { if $0.failure == nil { $0.failure = failure; $0.data = Data() } }
            task.cancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let target = request.url, BoundedHTTPResource.isAllowed(target) else {
                reject(.redirectRejected, task)
                completionHandler(nil)
                return
            }
            var next = request
            // Request headers were authorized for the original origin only.
            if target.host?.lowercased() != original.url?.host?.lowercased()
                || target.scheme?.lowercased() != original.url?.scheme?.lowercased() || target.port != original.url?.port {
                for field in (original.allHTTPHeaderFields ?? [:]).keys where field.lowercased() != "user-agent" {
                    next.setValue(nil, forHTTPHeaderField: field)
                }
            }
            completionHandler(next)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else { reject(.status(0), dataTask); return completionHandler(.cancel) }
            guard (200..<300).contains(http.statusCode) else { reject(.status(http.statusCode), dataTask); return completionHandler(.cancel) }
            if response.expectedContentLength > Int64(maxBytes) { reject(.tooLarge, dataTask); return completionHandler(.cancel) }
            if let acceptsContentType, !acceptsContentType(http.mimeType?.lowercased()) {
                reject(.unexpectedContentType, dataTask); return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Decoded bytes are what occupy memory, whatever was declared.
            let exceeded = state.withLock { state -> Bool in
                guard state.failure == nil else { return false }
                if state.data.count + data.count > maxBytes { return true }
                state.data.append(data)
                return false
            }
            if exceeded { reject(.tooLarge, dataTask) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, result): (CheckedContinuation<Data, Error>?, Result<Data, Error>) = state.withLock { state in
                defer { state.continuation = nil; state.data = Data() }
                if let failure = state.failure { return (state.continuation, .failure(failure)) }
                if let error {
                    let code = (error as? URLError)?.code ?? .unknown
                    return (state.continuation, .failure(code == .cancelled ? CancellationError() : Failure.transport(code)))
                }
                return (state.continuation, state.data.isEmpty ? .failure(Failure.empty) : .success(state.data))
            }
            continuation?.resume(with: result)
        }
    }
}
