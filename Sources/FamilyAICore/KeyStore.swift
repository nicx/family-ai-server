import Foundation

/// Where per-person OpenRouter keys live. Keys never go to the database or the browser.
public protocol KeyStore: Sendable {
    func get(_ account: String) -> String?
    @discardableResult func set(_ value: String, for account: String) -> Bool
    @discardableResult func delete(_ account: String) -> Bool
}

/// macOS Keychain through the Apple-signed `/usr/bin/security` tool.
///
/// In-process `SecItem*` access binds "Always allow" to the app's code hash, which
/// changes with every rebuild of a self-signed app and re-prompts for the keychain
/// password. `security` keeps a stable identity; items are created with
/// `-T /usr/bin/security` so it is on their access list from the start.
public struct KeychainKeyStore: KeyStore {
    let service: String
    private let tool = "/usr/bin/security"

    public init(service: String = "com.nicx.family-ai-server.openrouter") { self.service = service }

    private func run(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    public func get(_ account: String) -> String? {
        let (rc, out) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
        guard rc == 0 else { return nil }
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    public func set(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else { return delete(account) }
        _ = run(["delete-generic-password", "-s", service, "-a", account])
        return run(["add-generic-password", "-s", service, "-a", account, "-T", tool, "-w", value]).0 == 0
    }

    public func delete(_ account: String) -> Bool {
        let rc = run(["delete-generic-password", "-s", service, "-a", account]).0
        return rc == 0 || rc == 44
    }
}

/// JSON file with mode 0600 — for development, tests and headless use.
public final class FileKeyStore: KeyStore, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    private func load() -> [String: String] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    private func save(_ m: [String: String]) -> Bool {
        guard let d = try? JSONEncoder().encode(m) else { return false }
        do {
            try d.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    public func get(_ account: String) -> String? { lock.withLock { load()[account] } }

    public func set(_ value: String, for account: String) -> Bool {
        lock.withLock {
            var m = load()
            m[account] = value.isEmpty ? nil : value
            return save(m)
        }
    }

    public func delete(_ account: String) -> Bool {
        lock.withLock {
            var m = load()
            m[account] = nil
            return save(m)
        }
    }
}
