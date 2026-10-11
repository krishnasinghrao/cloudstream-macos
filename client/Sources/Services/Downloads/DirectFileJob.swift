import Foundation

/// Resumable HTTP download of a direct video file (Android `downloadThing`
/// parity): bytes stream into `<base>.part`, and an interrupted transfer —
/// pause, crash, quit, network loss — continues with a `Range` request
/// instead of starting over.
///
/// Resume is only attempted when the sidecar metadata proves it's the *same*
/// file: same mirror identity, same total length, and a matching strong
/// validator via `If-Range`. Anything else restarts
/// from zero rather than splicing two different files together.
final class DirectFileJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case completed(bytes: Int64, mimeType: String?)
        case failed(DownloadPolicy.FailureReason)
        /// The "direct" link actually served an HLS playlist; the caller
        /// should hand the same link to ffmpeg.
        case notDirect
        case cancelled
    }

    /// Persisted next to the partial file (`<base>.part.json`).
    struct ResumeMetadata: Codable, Equatable {
        var mirrorKey: String
        var totalBytes: Int64?
        var entityTag: String?
        var lastModified: String?
        var mimeType: String?
        var responseDate: String? = nil
        /// Written only after body-length validation and file synchronization.
        var completed: Bool? = nil

        var validator: String? {
            if let entityTag { return DirectFileJob.strongEntityTag(entityTag) }
            guard let lastModified, let modified = DirectFileJob.httpDate(lastModified) else { return nil }
            if let responseDate, let served = DirectFileJob.httpDate(responseDate) {
                guard served >= modified else { return nil }
            }
            return lastModified
        }
    }

    /// Anything smaller is an error page or a placeholder, not a video.
    static let minimumVideoBytes: Int64 = 512 * 1024

    private let url: URL
    private let headers: [(name: String, value: String)]
    private let partURL: URL
    private let metadataURL: URL
    private let mirrorKey: String
    private let onProgress: @Sendable (_ written: Int64, _ total: Int64?) -> Void

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var fileHandle: FileHandle?
    private var written: Int64 = 0
    private var total: Int64?
    private var resumeOffset: Int64 = 0
    private var metadata: ResumeMetadata?
    private var pendingOutcome: Outcome?
    private var sniffedFirstBytes = false
    private var lastProgressEmit = Date.distantPast
    private var userCancelled = false
    private var retryFresh = false
    private var hasRetriedFresh = false

    init(
        url: URL,
        headers: [(name: String, value: String)],
        partURL: URL,
        mirrorKey: String,
        onProgress: @escaping @Sendable (_ written: Int64, _ total: Int64?) -> Void,
    ) {
        self.url = url
        self.headers = headers
        self.partURL = partURL
        self.metadataURL = partURL.appendingPathExtension("json")
        self.mirrorKey = mirrorKey
        self.onProgress = onProgress
    }

    static func metadataURL(forPart partURL: URL) -> URL {
        partURL.appendingPathExtension("json")
    }

    func run() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                lock.lock()
                if userCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                start()
            }
        } onCancel: {
            cancel()
        }
    }

    /// Stops the transfer, keeping the partial file and its metadata so a
    /// later run can resume.
    func cancel() {
        lock.lock()
        userCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Start

    private func start(allowResume: Bool = true) {
        do {
            try MediaResourcePolicy.remoteURL(url.absoluteString)
            _ = try MediaResourcePolicy.headers(Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }))
            guard Set(headers.map { $0.name.lowercased() }).count == headers.count else {
                throw MediaResourcePolicy.Rejection.invalidHeader("duplicate")
            }
        } catch { finish(.failed(.protocolUnsupported)); return }
        let existing = allowResume ? Self.loadMetadata(at: metadataURL) : nil
        let partSize = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for header in headers where !["range", "if-range", "accept-encoding"].contains(header.name.lowercased()) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        // Range offsets refer to representation bytes, not a decompressed
        // body returned by URLSession. Never splice content-coded responses.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if DownloadPolicy.header("User-Agent", in: headers) == nil {
            request.setValue(DownloadService.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }

        if let existing, let validator = existing.validator, existing.mirrorKey == mirrorKey, existing.totalBytes != nil,
           partSize > 0, partSize < (existing.totalBytes ?? 0) {
            resumeOffset = partSize
            metadata = existing
            metadata?.completed = false
            persistMetadata()
            request.setValue("bytes=\(partSize)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        } else if let existing, existing.mirrorKey == mirrorKey, let totalBytes = existing.totalBytes,
                  existing.completed == true, existing.validator != nil,
                  partSize == totalBytes, partSize >= Self.minimumVideoBytes {
            // Finished transfer whose completion wasn't recorded (quit at the
            // last byte). Nothing left to fetch.
            finish(.completed(bytes: partSize, mimeType: existing.mimeType))
            return
        } else {
            removePartial()
            resumeOffset = 0
            metadata = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45 // idle gap between packets → stall
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)

        lock.lock()
        self.session = session
        self.task = task
        let cancelledEarly = userCancelled
        lock.unlock()

        if cancelledEarly {
            session.invalidateAndCancel()
            finish(.cancelled)
            return
        }
        task.resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        // A redirect must not escape to file:// or other schemes, and
        // credentials stay on the origin they were issued for (audit M3).
        let original = task.originalRequest?.url ?? response.url
        guard let original, let redirected = Self.redirectedRequest(request, from: original) else {
            fail(.protocolUnsupported)
            completionHandler(nil)
            return
        }
        if redirected.allHTTPHeaderFields?.count != request.allHTTPHeaderFields?.count {
            DaemonLog.client("download.redirect_stripped_credentials", fields: [:])
        }
        completionHandler(redirected)
    }

    /// An MPD document labelled as a plain file: `<MPD` within the first 512
    /// bytes, after an optional XML prolog or comments (case-insensitive).
    nonisolated static func looksLikeDASHManifest(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        guard let range = head.range(of: "<mpd") else { return false }
        let before = head[head.startIndex..<range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        // Only markup may precede the root element (a prolog or comments), never media bytes.
        return before.isEmpty || before.hasPrefix("<?xml") || before.hasPrefix("<!--")
    }

    /// Headers that are not credentials but keep a resumed transfer correct.
    nonisolated static let transferHeaders: Set<String> = ["range", "if-range", "accept-encoding"]

    /// The request to follow for a redirect, or nil when its target is not an
    /// allowed remote address. Leaving the original origin (scheme, host,
    /// port) drops every header but the shareable ones and those a resumed
    /// transfer needs, as the engine relay does for the same redirect.
    nonisolated static func redirectedRequest(_ new: URLRequest, from original: URL) -> URLRequest? {
        guard let target = new.url?.absoluteString, DownloadPolicy.isAllowedRemoteURL(target),
              (try? MediaResourcePolicy.remoteURL(target)) != nil else { return nil }
        guard MediaResourcePolicy.origin(target) != MediaResourcePolicy.origin(original.absoluteString) else { return new }
        var stripped = new
        for name in new.allHTTPHeaderFields.map({ Array($0.keys) }) ?? [] {
            let lowered = name.lowercased()
            if !MediaResourcePolicy.shareableHeaders.contains(lowered) && !transferHeaders.contains(lowered) {
                stripped.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return stripped
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(.invalidMedia)
            completionHandler(.cancel)
            return
        }

        let status = http.statusCode
        let mimeType = http.mimeType?.lowercased()

        if status == 416, resumeOffset > 0 {
            requestFreshResponse()
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(status) else {
            switch status {
            case 403: fail(.forbidden)
            case 404: fail(.notFound)
            default: fail(.httpStatus(status))
            }
            completionHandler(.cancel)
            return
        }

        // Manifests are not files: ffmpeg downloads what they name (Q6).
        if let mimeType, mimeType.contains("mpegurl") || mimeType.contains("dash+xml") {
            finishNotDirect()
            completionHandler(.cancel)
            return
        }
        if let mimeType, mimeType.hasPrefix("text/html") || mimeType == "application/json" {
            fail(.invalidMedia)
            completionHandler(.cancel)
            return
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            fail(.invalidMedia)
            completionHandler(.cancel)
            return
        }

        do {
            if status == 206 {
                guard let range = Self.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
                      let rangeTotal = range.total, range.start == resumeOffset,
                      range.end == rangeTotal - 1,
                      http.expectedContentLength == -1 || http.expectedContentLength == rangeTotal - range.start,
                      resumeOffset == 0 || (rangeTotal == metadata?.totalBytes && responseMatchesValidator(http)) else {
                    // Reject this body entirely. Fresh retry begins only after
                    // cancellation closes the old writer in didComplete.
                    requestFreshResponse()
                    completionHandler(.cancel)
                    return
                }
                if resumeOffset > 0 {
                    let handle = try FileHandle(forWritingTo: partURL)
                    try handle.seek(toOffset: UInt64(resumeOffset))
                    lock.lock()
                    fileHandle = handle
                    written = resumeOffset
                    total = rangeTotal
                    sniffedFirstBytes = true
                    lock.unlock()
                } else {
                    try restartFromZero(response: http, mimeType: mimeType, expectedLength: rangeTotal)
                }
            } else {
                guard status == 200 else {
                    fail(.invalidMedia)
                    completionHandler(.cancel)
                    return
                }
                // Ignored Range / changed validator: a 200 is a fresh entity.
                try restartFromZero(response: http, mimeType: mimeType)
            }
            completionHandler(.allow)
        } catch {
            fail(Self.fileSystemFailure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handle = fileHandle
        let exceedsLength = total.map { Int64(data.count) > $0 - written } ?? false
        let needsSniff = !sniffedFirstBytes
        sniffedFirstBytes = true
        lock.unlock()
        guard let handle else { return }
        if exceedsLength {
            fail(.invalidMedia)
            dataTask.cancel()
            return
        }

        if needsSniff {
            let prefix = String(decoding: data.prefix(16), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            if prefix.hasPrefix("#EXTM3U") || Self.looksLikeDASHManifest(data) {
                finishNotDirect()
                dataTask.cancel()
                return
            }
            if prefix.lowercased().hasPrefix("<!doctype") || prefix.lowercased().hasPrefix("<html") {
                fail(.invalidMedia)
                dataTask.cancel()
                return
            }
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(Self.fileSystemFailure(error))
            dataTask.cancel()
            return
        }

        lock.lock()
        written += Int64(data.count)
        let snapshot = (written, total)
        let now = Date()
        let shouldEmit = now.timeIntervalSince(lastProgressEmit) >= 0.5
        if shouldEmit { lastProgressEmit = now }
        lock.unlock()
        if shouldEmit {
            onProgress(snapshot.0, snapshot.1)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let handle = fileHandle
        fileHandle = nil
        let bytes = written
        let expected = total
        let explicitlyCancelled = userCancelled
        lock.unlock()
        do {
            try handle?.synchronize()
            try handle?.close()
        } catch {
            try? handle?.close()
            fail(Self.fileSystemFailure(error))
        }
        session.finishTasksAndInvalidate()

        if retryFresh, !explicitlyCancelled {
            retryFresh = false
            removePartial()
            start(allowResume: false)
            return
        }

        if let error {
            if explicitlyCancelled {
                finish(.cancelled)
                return
            }
            let urlError = error as? URLError
            switch urlError?.code {
            case .cancelled?:
                finish(.cancelled) // superseded by an earlier fail()/notDirect
            case .timedOut?:
                finish(.failed(.stalled))
            case .unsupportedURL?:
                finish(.failed(.protocolUnsupported))
            default:
                finish(.failed(.network(urlError?.localizedDescription ?? error.localizedDescription)))
            }
            return
        }

        onProgress(bytes, expected)
        if let expected, bytes != expected {
            finish(.failed(.truncated))
            return
        }
        if bytes < Self.minimumVideoBytes {
            finish(.failed(.invalidMedia))
            return
        }
        if pendingOutcome == nil {
            metadata?.completed = true
            persistMetadata()
        }
        finish(.completed(bytes: bytes, mimeType: metadata?.mimeType))
    }

    // MARK: - Helpers

    private func restartFromZero(response: HTTPURLResponse, mimeType: String?, expectedLength: Int64? = nil) throws {
        removePartial()
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        let length = expectedLength ?? (response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
        let meta = ResumeMetadata(
            mirrorKey: mirrorKey,
            totalBytes: length,
            entityTag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            mimeType: mimeType,
            responseDate: response.value(forHTTPHeaderField: "Date"),
        )
        // Retain ownership metadata even when byte-resume is unavailable, so
        // abandoned partial cleanup still recognizes this app's files.
        // Start's validator gate controls whether any bytes can be reused.
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metadataURL, options: .atomic)
        }
        lock.lock()
        fileHandle = handle
        written = 0
        total = length
        metadata = meta
        resumeOffset = 0
        sniffedFirstBytes = false
        lock.unlock()
    }

    private func responseMatchesValidator(_ response: HTTPURLResponse) -> Bool {
        guard let metadata, let validator = metadata.validator else { return false }
        if metadata.entityTag != nil {
            return Self.strongEntityTag(response.value(forHTTPHeaderField: "ETag")) == validator
        }
        return response.value(forHTTPHeaderField: "Last-Modified") == validator
    }

    private func requestFreshResponse() {
        if hasRetriedFresh {
            fail(.invalidMedia)
            removePartial()
        } else {
            hasRetriedFresh = true
            retryFresh = true
        }
    }

    private func persistMetadata() {
        guard let metadata, let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func removePartial() {
        try? FileManager.default.removeItem(at: partURL)
        try? FileManager.default.removeItem(at: metadataURL)
    }

    private func fail(_ reason: DownloadPolicy.FailureReason) {
        lock.lock()
        if pendingOutcome == nil { pendingOutcome = .failed(reason) }
        lock.unlock()
        // Delivered from didCompleteWithError once the task has fully ended,
        // unless no task exists yet.
        lock.lock()
        let hasTask = task != nil
        lock.unlock()
        if !hasTask { finish(.failed(reason)) }
    }

    private func finishNotDirect() {
        lock.lock()
        if pendingOutcome == nil { pendingOutcome = .notDirect }
        lock.unlock()
        removePartial()
    }

    /// Resumes the awaiting caller exactly once. A recorded failure or
    /// not-direct verdict wins over the generic cancellation it caused.
    private func finish(_ outcome: Outcome) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let explicitlyCancelled = userCancelled
        let resolved: Outcome
        if explicitlyCancelled {
            resolved = .cancelled
        } else if let pendingOutcome {
            resolved = pendingOutcome
        } else {
            resolved = outcome
        }
        lock.unlock()
        continuation?.resume(returning: resolved)
    }

    static func loadMetadata(at url: URL) -> ResumeMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResumeMetadata.self, from: data)
    }

    /// Strict single byte range. Unknown totals parse but cannot be resumed.
    static func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst("bytes ".count)
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        func integer(_ raw: Substring) -> Int64? {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(raw)
        }
        guard bounds.count == 2, let start = integer(bounds[0]), let end = integer(bounds[1]), end >= start else { return nil }
        if parts[1] == "*" { return (start, end, nil) }
        guard let total = integer(parts[1]), total > end else { return nil }
        return (start, end, total)
    }

    static func strongEntityTag(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count >= 2, raw.first == "\"", raw.last == "\"",
              raw.dropFirst().dropLast().unicodeScalars.allSatisfy({
                  $0.value == 0x21 || (0x23...0x7E).contains($0.value) || (0x80...0xFF).contains($0.value)
              }) else { return nil }
        return raw
    }

    static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
        return date
    }

    static func fileSystemFailure(_ error: Error) -> DownloadPolicy.FailureReason {
        let nsError = error as NSError
        let posix: Int32? = {
            if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return Int32(underlying.code)
            }
            return nil
        }()
        switch posix {
        case ENOSPC?, EDQUOT?: return .diskFull
        case EACCES?, EPERM?, EROFS?: return .permissionDenied
        case ENAMETOOLONG?: return .destinationUnavailable("file name too long")
        default: break
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError: return .diskFull
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError: return .permissionDenied
            default: break
            }
        }
        return .destinationUnavailable(nsError.localizedDescription)
    }
}
