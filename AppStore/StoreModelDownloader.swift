import Foundation

/// URLSession writes large model weights to the sandbox's temporary directory.
/// ModelStore verifies the sealed manifest's size and digest before publication.
final class StoreModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let asset: ModelStore.Asset
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var result: Result<Void, Error>?

    private init(asset: ModelStore.Asset, destination: URL,
                 progress: @escaping @Sendable (Int64) -> Void) {
        self.asset = asset; self.destination = destination; self.progress = progress
    }

    static func download(_ asset: ModelStore.Asset, to destination: URL,
                         progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let downloader = StoreModelDownloader(asset: asset, destination: destination, progress: progress)
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { downloader.start($0) }
        }, onCancel: { downloader.cancel() })
    }

    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        guard let url = asset.url, url.scheme == "https", url.user == nil, url.password == nil else {
            lock.unlock(); continuation.resume(throwing: RuntimeSetupError.message("The model URL is invalid.")); return
        }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task; task.resume()
        lock.unlock()
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == "https" && url?.user == nil && url?.password == nil ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > asset.bytes || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > asset.bytes) {
            lock.lock(); result = .failure(RuntimeSetupError.message("The model download exceeded its verified size.")); lock.unlock()
            downloadTask.cancel()
        } else { progress(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber,
                  size.int64Value == asset.bytes else {
                throw RuntimeSetupError.message("The model download was incomplete. Retry setup.")
            }
            lock.lock(); let cancelled = cancelled; lock.unlock()
            guard !cancelled else { throw CancellationError() }
            // Both paths belong to this app's container. Never publish a model
            // until ModelStore has independently checked its SHA-256 digest.
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); result = .success(()); lock.unlock()
        } catch { lock.lock(); result = .failure(error); lock.unlock() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result = result ?? .failure(cancelled ? CancellationError() : error ?? RuntimeSetupError.message("The model download failed."))
        let continuation = continuation; self.continuation = nil
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
