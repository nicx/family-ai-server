#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

/// Linux replacement for `URLSession.bytes(for:).lines`: a data delegate splits the body into lines.
final class LineStreamLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var responseCont: CheckedContinuation<Int, Error>?
    private var lineCont: AsyncThrowingStream<String, Error>.Continuation?
    private var gotResponse = false

    static func open(_ req: URLRequest, configuration: URLSessionConfiguration) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        let loader = LineStreamLoader()
        let lines = AsyncThrowingStream<String, Error> { loader.lineCont = $0 }
        let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: nil)
        let task = session.dataTask(with: req)
        let status: Int = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                loader.lock.withLock { loader.responseCont = c }
                task.resume()
            }
        } onCancel: { task.cancel() }
        loader.lineCont?.onTermination = { _ in task.cancel(); session.finishTasksAndInvalidate() }
        return (status, lines)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            gotResponse = true
            responseCont?.resume(returning: (response as? HTTPURLResponse)?.statusCode ?? 0)
            responseCont = nil
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let out: [String] = lock.withLock {
            buffer.append(data)
            var lines: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<nl]
                if line.last == 0x0D { line = line.dropLast() }
                buffer = Data(buffer[buffer.index(after: nl)...])
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            }
            return lines
        }
        for l in out { lineCont?.yield(l) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (rest, cont): (String?, CheckedContinuation<Int, Error>?) = lock.withLock {
            let r = buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
            buffer = Data()
            let c = responseCont
            responseCont = nil
            return (r, c)
        }
        if let cont { cont.resume(throwing: error ?? URLError(.badServerResponse)); lineCont?.finish(throwing: error); return }
        if let rest { lineCont?.yield(rest) }
        if let error, (error as? URLError)?.code != .cancelled { lineCont?.finish(throwing: error) } else { lineCont?.finish() }
        session.finishTasksAndInvalidate()
    }
}
#endif
