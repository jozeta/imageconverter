import Foundation
import ImageconverterCore

/// The app's only network code: the release check against GitHub's API and the download of the release's
/// checksum and zip. Every request goes through `Transfer`: an ephemeral session (no cookies, cache or stored
/// credentials), the allowed hosts checked on the first URL, on every redirect and on the final response,
/// and a byte cap enforced while the body streams in. Sends only `User-Agent: imageconverter/<version>`.
/// `NoNetworkTests` allows networking only in this folder.
enum UpdateClient {
    static let releaseURL = URL(string: "https://api.github.com/repos/jozeta/imageconverter/releases/latest")!
    static var userAgent: String { "imageconverter/\(AppInfo.version)" }

    /// The newer release, or nil when the app is up to date.
    static func latestRelease(current: AppVersion) async throws -> UpdateRelease? {
        var request = URLRequest(url: releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try await Transfer.run(request, cap: UpdatePolicy.maxResponseBytes, tooLarge: .responseTooLarge,
                                          allowed: { UpdatePolicy.allowedAPIURL($0) })
        return try UpdateRelease.parse(data, current: current)
    }

    /// Downloads the checksum file and the zip into `folder`; returns the zip and its expected SHA-256.
    static func download(_ release: UpdateRelease, into folder: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (zip: URL, sha256: String) {
        let zipName = UpdatePolicy.zipName(for: release.version)
        let checksum = try await Transfer.run(URLRequest(url: release.shaURL), cap: UpdatePolicy.maxChecksumBytes,
                                              tooLarge: .badChecksumFile, allowed: { UpdatePolicy.allowedHost($0) })
        guard let expected = UpdatePolicy.expectedSHA256(from: checksum, fileName: zipName) else {
            throw UpdateError.badChecksumFile
        }
        let zip = folder.appendingPathComponent(zipName)
        guard FileManager.default.createFile(atPath: zip.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: zip) else {
            throw UpdateError.downloadFailed("the download could not be saved.")
        }
        _ = try await Transfer.run(URLRequest(url: release.zipURL), cap: UpdatePolicy.maxZipBytes, tooLarge: .downloadTooLarge,
                                   allowed: { UpdatePolicy.allowedHost($0) }, sink: handle, progress: progress)
        return (zip, expected)
    }
}

/// One request: the body in memory, or written to `sink`. Delegate calls arrive on one serial queue.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let cap: Int64
    private let tooLarge: UpdateError
    private let allowed: @Sendable (URL) -> Bool
    private let sink: FileHandle?
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private var buffer = Data()
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var reported: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Data, Error>?

    private init(cap: Int, tooLarge: UpdateError, allowed: @escaping @Sendable (URL) -> Bool, sink: FileHandle?,
                 progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.cap = Int64(cap)
        self.tooLarge = tooLarge
        self.allowed = allowed
        self.sink = sink
        self.progress = progress
    }

    static func run(_ request: URLRequest, cap: Int, tooLarge: UpdateError, allowed: @escaping @Sendable (URL) -> Bool,
                    sink: FileHandle? = nil, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> Data {
        guard let url = request.url, allowed(url) else {
            try? sink?.close()
            throw UpdateError.disallowedURL
        }
        var request = request
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.setValue(UpdateClient.userAgent, forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let transfer = Transfer(cap: cap, tooLarge: tooLarge, allowed: allowed, sink: sink, progress: progress)
        // The session keeps its delegate until it is invalidated, which `didCompleteWithError` does.
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: queue)
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    transfer.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func fail(_ error: UpdateError, _ task: URLSessionTask) {
        if failure == nil { failure = error }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allowed(url) else {
            fail(.disallowedURL, task)
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let url = response.url, allowed(url) else {
            fail(.disallowedURL, dataTask)
            return completionHandler(.cancel)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            fail(.serverStatus((response as? HTTPURLResponse)?.statusCode ?? 0), dataTask)
            return completionHandler(.cancel)
        }
        // A declared length over the cap ends it now; the cap is also counted while the body arrives.
        expected = response.expectedContentLength
        guard expected <= cap else {
            fail(tooLarge, dataTask)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= cap else { return fail(tooLarge, dataTask) }
        if let sink {
            do { try sink.write(contentsOf: data) } catch { return fail(.downloadFailed("the download could not be saved."), dataTask) }
        } else {
            buffer.append(data)
        }
        // At most every 256 KB, so a 200 MB download doesn't flood the main actor.
        if received - reported >= 256 * 1024 || received == expected {
            reported = received
            progress?(received, expected)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        try? sink?.close()
        let continuation = continuation
        self.continuation = nil
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            continuation?.resume(throwing: cancelled ? CancellationError() : UpdateError.downloadFailed(error.localizedDescription))
        } else {
            continuation?.resume(returning: buffer)
        }
    }
}
