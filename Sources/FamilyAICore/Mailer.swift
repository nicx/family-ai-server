import Foundation

/// SMTP delivery through the system `/usr/bin/curl` (present on every Mac).
///
/// curl handles all three transport variants — plain (local relay), STARTTLS
/// (usually port 587) and implicit TLS (usually 465) — plus AUTH LOGIN/PLAIN.
/// Network.framework cannot upgrade a running connection to TLS, which STARTTLS needs.
public enum Mailer {
    public enum Security: String, Codable, Sendable, CaseIterable {
        case none, starttls, tls
    }

    public struct Account: Sendable {
        public var host: String
        public var port: Int
        public var security: Security
        public var user: String
        public var password: String?
        public init(host: String, port: Int, security: Security = .none, user: String = "", password: String? = nil) {
            self.host = host; self.port = port; self.security = security; self.user = user; self.password = password
        }
    }

    /// RFC 5322 message with a UTF-8 subject and body.
    static func message(sender: String, recipient: String, subject: String, body: String, date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        let text = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return "From: \(sender)\r\nTo: \(recipient)\r\nSubject: \(encodedSubject)\r\n" +
            "Date: \(df.string(from: date))\r\nMIME-Version: 1.0\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(text)\r\n"
    }

    /// curl config file contents. Credentials go here (never on the command line, where
    /// `ps` could show them). Values are quoted with curl's config escaping.
    static func curlConfig(_ a: Account, sender: String, recipient: String, messageFile: String) -> String {
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let scheme = a.security == .tls ? "smtps" : "smtp"
        var lines = [
            "url = \(q("\(scheme)://\(a.host):\(a.port)"))",
            "mail-from = \(q(sender))",
            "mail-rcpt = \(q(recipient))",
            "upload-file = \(q(messageFile))",
            "connect-timeout = 10",
            "max-time = 30",
            "silent",
            "show-error",
        ]
        if a.security == .starttls { lines.append("ssl-reqd") }
        if !a.user.isEmpty { lines.append("user = \(q(a.user + ":" + (a.password ?? "")))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Sends one mail. Returns `nil` on success, otherwise curl's error text.
    public static func send(_ account: Account, sender: String, recipient: String,
                            subject: String, body: String) async -> String? {
        guard !account.host.isEmpty, !recipient.isEmpty, (1...65535).contains(account.port) else {
            return "SMTP-Server oder Empfänger fehlt"
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("family-ai-mail-\(newID())")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return "\(error)" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let msgURL = dir.appendingPathComponent("message.eml")
        let cfgURL = dir.appendingPathComponent("curl.cfg")
        let fm = FileManager.default
        guard fm.createFile(atPath: msgURL.path, contents: Data(message(sender: sender, recipient: recipient, subject: subject, body: body).utf8),
                            attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: cfgURL.path, contents: Data(curlConfig(account, sender: sender, recipient: recipient, messageFile: msgURL.path).utf8),
                            attributes: [.posixPermissions: 0o600]) else { return "Temporäre Datei nicht anlegbar" }

        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["--disable", "--config", cfgURL.path]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: proc.terminationStatus == 0 ? nil : (text.isEmpty ? "curl \(proc.terminationStatus)" : text))
            }
            do { try p.run() } catch { cont.resume(returning: "\(error)") }
        }
    }
}

/// Watches every person's OpenRouter key and mails at the threshold and at 100 %.
/// The limit itself is enforced by OpenRouter.
public actor BudgetMonitor {
    let store: Store
    let router: OpenRouter
    let keys: KeyStore
    public private(set) var statuses: [String: OpenRouter.KeyStatus] = [:]
    public private(set) var errors: [String: String] = [:]

    public init(store: Store, router: OpenRouter, keys: KeyStore) {
        self.store = store
        self.router = router
        self.keys = keys
    }

    public func status(userId: String) async -> OpenRouter.KeyStatus? {
        if let s = statuses[userId] { return s }
        guard let key = keys.get(userId) else { return nil }
        if let s = try? await router.keyStatus(key: key) { statuses[userId] = s; return s }
        return nil
    }

    public func refresh(userId: String) async -> OpenRouter.KeyStatus? {
        statuses[userId] = nil
        return await status(userId: userId)
    }

    public func checkAll() async {
        guard let users = try? await store.users(), let settings = try? await store.settings() else { return }
        for u in users {
            guard let key = keys.get(u.id) else { continue }
            do {
                let s = try await router.keyStatus(key: key)
                statuses[u.id] = s
                errors[u.id] = nil
                await evaluate(user: u, status: s, settings: settings)
            } catch {
                errors[u.id] = "\(error)"
            }
        }
    }

    private func evaluate(user: User, status: OpenRouter.KeyStatus, settings: GlobalSettings) async {
        guard let limit = status.limit, limit > 0, let remaining = status.remaining else { return }
        let fraction = (limit - remaining) / limit
        let threshold = Double(settings.budgetThreshold) / 100
        let level = fraction >= 1 ? 2 : (fraction >= threshold ? 1 : 0)
        let metaKey = "budget.level.\(user.id)"
        let notified = Int((try? await store.meta(metaKey)) ?? "0") ?? 0
        if level == 0 {
            if notified != 0 { try? await store.setMeta(metaKey, "0") }
            return
        }
        guard level > notified else { return }
        if settings.notifyOnBudget && !settings.mailRecipient.isEmpty {
            let pct = Int((fraction * 100).rounded())
            let used = String(format: "%.2f", limit - remaining)
            let lim = String(format: "%.2f", limit)
            let subject = level == 2
                ? "\(settings.aiName): Budget von \(user.displayName) aufgebraucht"
                : "\(settings.aiName): \(user.displayName) hat \(pct) % des Budgets verbraucht"
            let body = "\(user.displayName): \(used) $ von \(lim) $ verbraucht (\(pct) %).\nZurücksetzen: \(status.reset ?? "nie")\n\n" +
                (level == 2 ? "OpenRouter lehnt weitere Anfragen ab, bis das Limit zurückgesetzt oder erhöht wird."
                            : "Bei 100 % sperrt OpenRouter den Schlüssel bis zum nächsten Zurücksetzen.")
            let failure = await Mailer.send(settings.mailAccount(keys: keys), sender: settings.mailFrom,
                                            recipient: settings.mailRecipient, subject: subject, body: body)
            guard failure == nil else { return } // retry next round
        }
        try? await store.setMeta(metaKey, String(level))
    }
}
