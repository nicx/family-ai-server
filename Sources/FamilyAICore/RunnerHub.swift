import Foundation

/// Connects chats in "code" mode with a runner on the user's own computer.
///
/// The runner only makes outgoing requests: it long-polls for jobs and posts
/// results back, so the computer needs no open port. Every job is confirmed by
/// the person at the computer itself (the runner shows a dialog), so a
/// compromised server cannot run commands unnoticed.
public actor RunnerHub {
    public struct Job: Codable, Sendable {
        public var id: String
        public var tool: String
        public var args: [String: String]
        public var chatTitle: String?
    }

    public struct JobResult: Codable, Sendable {
        public var ok: Bool
        public var output: String
    }

    private var queues: [String: [Job]] = [:]
    private var waiters: [String: (token: String, cont: CheckedContinuation<Job?, Never>)] = [:]
    private var pending: [String: CheckedContinuation<JobResult, Never>] = [:]
    private var jobDevice: [String: String] = [:]
    private var lastPoll: [String: Double] = [:]

    public init() {}

    public func isOnline(_ deviceId: String) -> Bool {
        if waiters[deviceId] != nil { return true }
        guard let t = lastPoll[deviceId] else { return false }
        return now() - t < 45
    }

    /// Called by the runner. Returns a job or nil after `timeout` seconds.
    public func poll(deviceId: String, timeout: Double = 25) async -> Job? {
        lastPoll[deviceId] = now()
        if var q = queues[deviceId], !q.isEmpty {
            let job = q.removeFirst()
            queues[deviceId] = q
            return job
        }
        // Replace an older waiting poll of the same device.
        if let old = waiters.removeValue(forKey: deviceId) { old.cont.resume(returning: nil) }
        let token = newID()
        let job: Job? = await withCheckedContinuation { cont in
            waiters[deviceId] = (token, cont)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expireWaiter(deviceId: deviceId, token: token)
            }
        }
        lastPoll[deviceId] = now()
        return job
    }

    private func expireWaiter(deviceId: String, token: String) {
        if let w = waiters[deviceId], w.token == token {
            waiters.removeValue(forKey: deviceId)
            w.cont.resume(returning: nil)
        }
    }

    /// Called by the chat engine. Waits for the runner's result.
    public func execute(deviceId: String, tool: String, args: [String: String], chatTitle: String?, timeout: Double = 300) async -> JobResult {
        let job = Job(id: newID(), tool: tool, args: args, chatTitle: chatTitle)
        jobDevice[job.id] = deviceId
        let result: JobResult = await withCheckedContinuation { cont in
            pending[job.id] = cont
            if let w = waiters.removeValue(forKey: deviceId) {
                w.cont.resume(returning: job)
            } else {
                queues[deviceId, default: []].append(job)
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutJob(job.id)
            }
        }
        return result
    }

    private func timeoutJob(_ id: String) {
        if let cont = pending.removeValue(forKey: id) {
            if let dev = jobDevice[id] { queues[dev]?.removeAll { $0.id == id } }
            jobDevice[id] = nil
            cont.resume(returning: JobResult(ok: false, output: "Zeitüberschreitung: keine Antwort vom Gerät (nicht verbunden oder Freigabe nicht erteilt)."))
        }
    }

    /// Called by the runner with the outcome of a job.
    public func complete(deviceId: String, jobId: String, result: JobResult) -> Bool {
        guard jobDevice[jobId] == deviceId, let cont = pending.removeValue(forKey: jobId) else { return false }
        jobDevice[jobId] = nil
        cont.resume(returning: result)
        return true
    }
}
