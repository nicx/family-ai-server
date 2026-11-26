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
    // Approval in the chat (only when the runner on the computer is set to ask there instead of with a popup).
    private var jobs: [String: Job] = [:]
    private var onAsk: [String: @Sendable (Job) async -> Void] = [:]
    private var asked: Set<String> = []
    private var decisions: [String: Bool] = [:]
    private var askWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    /// Online = a poll is waiting, the runner polled a moment ago, or it is busy with a job we gave it.
    /// The runner polls again right away after every poll, so a few seconds of silence mean it is gone.
    public func isOnline(_ deviceId: String) -> Bool {
        if waiters[deviceId] != nil { return true }
        if jobDevice.values.contains(deviceId) { return true }
        guard let t = lastPoll[deviceId] else { return false }
        return now() - t < 6
    }

    /// Called by the runner. Returns a job or nil after `timeout` seconds.
    public func poll(deviceId: String, timeout: Double = 10) async -> Job? {
        lastPoll[deviceId] = now()
        if var q = queues[deviceId], !q.isEmpty {
            let job = q.removeFirst()
            queues[deviceId] = q
            return job
        }
        // Replace an older waiting poll of the same device.
        if let old = waiters.removeValue(forKey: deviceId) { old.cont.resume(returning: nil) }
        let token = newID()
        // A dropped connection cancels this task: then the device goes offline at once instead of after the timeout.
        let job: Job? = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Job?, Never>) in
                if Task.isCancelled { cont.resume(returning: nil); return }
                waiters[deviceId] = (token, cont)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.expireWaiter(deviceId: deviceId, token: token)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.abandon(deviceId: deviceId, token: token) }
        }
        if job != nil { lastPoll[deviceId] = now() }
        return job
    }

    /// The runner's connection broke off: no longer online.
    private func abandon(deviceId: String, token: String) {
        guard let w = waiters[deviceId], w.token == token else { return }
        waiters.removeValue(forKey: deviceId)
        lastPoll[deviceId] = nil
        w.cont.resume(returning: nil)
    }

    /// The runner said goodbye (it is being closed): offline immediately.
    public func goOffline(deviceId: String) {
        if let w = waiters.removeValue(forKey: deviceId) { w.cont.resume(returning: nil) }
        lastPoll[deviceId] = nil
    }

    private func expireWaiter(deviceId: String, token: String) {
        if let w = waiters[deviceId], w.token == token {
            waiters.removeValue(forKey: deviceId)
            // The 6 s grace starts now: between this answer and the runner's next poll the device is not "gone".
            lastPoll[deviceId] = now()
            w.cont.resume(returning: nil)
        }
    }

    /// Called by the chat engine. Waits for the runner's result.
    /// `onAsk` is called once when the runner wants the person's approval in the chat (see `ask`).
    public func execute(deviceId: String, tool: String, args: [String: String], chatTitle: String?, timeout: Double = 300,
                        onAsk: (@Sendable (Job) async -> Void)? = nil) async -> JobResult {
        let job = Job(id: newID(), tool: tool, args: args, chatTitle: chatTitle)
        jobDevice[job.id] = deviceId
        jobs[job.id] = job
        onAsk.map { self.onAsk[job.id] = $0 }
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
            forgetApproval(id)
            cont.resume(returning: JobResult(ok: false, output: "Zeitüberschreitung: keine Antwort vom Gerät (nicht verbunden oder Freigabe nicht erteilt)."))
        }
    }

    /// Called by the runner with the outcome of a job.
    public func complete(deviceId: String, jobId: String, result: JobResult) -> Bool {
        guard jobDevice[jobId] == deviceId, let cont = pending.removeValue(forKey: jobId) else { return false }
        jobDevice[jobId] = nil
        forgetApproval(jobId)
        cont.resume(returning: result)
        return true
    }

    // MARK: Approval in the chat

    private func forgetApproval(_ id: String) {
        jobs[id] = nil; onAsk[id] = nil; asked.remove(id); decisions[id] = nil
        askWaiters.removeValue(forKey: id)?.resume()
    }

    /// The runner asks whether it may run the job. Shows the question in the chat (first call) and waits up to
    /// `wait` seconds for the person's answer: "allow", "deny" or "pending" (ask again – keeps every request short).
    public func ask(deviceId: String, jobId: String, wait: Double = 8) async -> String {
        guard jobDevice[jobId] == deviceId, let job = jobs[jobId] else { return "deny" }
        if !asked.contains(jobId) {
            asked.insert(jobId)
            if let cb = onAsk[jobId] { Task { await cb(job) } }
        }
        if decisions[jobId] == nil {
            askWaiters.removeValue(forKey: jobId)?.resume()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                askWaiters[jobId] = cont
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    await self?.wakeAsk(jobId)
                }
            }
        }
        guard jobDevice[jobId] == deviceId else { return "deny" }
        switch decisions[jobId] {
        case .some(true): return "allow"
        case .some(false): return "deny"
        case .none: return "pending"
        }
    }

    private func wakeAsk(_ id: String) { askWaiters.removeValue(forKey: id)?.resume() }

    /// The person's answer from the chat.
    public func decide(jobId: String, allow: Bool) -> Bool {
        guard asked.contains(jobId), decisions[jobId] == nil else { return false }
        decisions[jobId] = allow
        wakeAsk(jobId)
        return true
    }

    public func deviceId(forJob id: String) -> String? { jobDevice[id] }

    /// Questions the runner has asked that nobody has answered yet. Lets every open window of the web app show the
    /// card, not only the one that started the answer (switching browser/app must not lose it).
    public func openApprovals() -> [(deviceId: String, job: Job)] {
        asked.sorted().compactMap { id in
            guard decisions[id] == nil, let job = jobs[id], let dev = jobDevice[id] else { return nil }
            return (dev, job)
        }
    }

    /// Text for the approval card in the chat.
    public static func describe(_ job: Job) -> (title: String, text: String) {
        let a = job.args
        switch job.tool {
        case "run_command": return ("Befehl ausführen", a["command"] ?? "")
        case "write_file":
            let c = a["content"] ?? ""
            return ("Datei schreiben", (a["path"] ?? "") + "\n\n" + (c.count > 1500 ? String(c.prefix(1500)) + "\n…" : c))
        case "save_image": return ("Bild speichern", a["path"] ?? "")
        case "read_file": return ("Datei lesen", a["path"] ?? "")
        case "search_files": return ("Dateien durchsuchen", a["query"] ?? a["name"] ?? "")
        case "make_dir": return ("Ordner anlegen", a["path"] ?? "")
        case "move_file": return ("Datei verschieben", (a["from"] ?? "") + " → " + (a["to"] ?? ""))
        case "delete_file": return ("Datei löschen", a["path"] ?? "")
        default: return ("Dateien auflisten", a["path"] ?? ".")
        }
    }
}
