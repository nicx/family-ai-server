import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// OpenRouter keys in one AES-256-GCM encrypted file (Docker / Linux, where there is no keychain).
///
/// The encryption key is derived (HKDF-SHA256) from a master key that is **not** stored next to the data:
/// it comes from a Docker secret (`FAMILY_AI_MASTER_KEY_FILE`) or the environment (`FAMILY_AI_MASTER_KEY`).
/// A stolen data volume or backup therefore does not reveal any OpenRouter key.
///
/// With a wrong or lost master key the file cannot be read; it is then never overwritten, so
/// starting again with the right key still works. If the key is lost for good, delete `keys.enc`
/// and enter the OpenRouter keys again (Admin → People).
public final class EncryptedKeyStore: KeyStore, @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case masterKeyTooShort
        public var description: String {
            "Der Master-Schlüssel ist zu kurz (mindestens \(EncryptedKeyStore.minimumMasterKeyLength) Zeichen). "
                + "Erzeugen mit: openssl rand -base64 32"
        }
    }

    public static let minimumMasterKeyLength = 24
    static let magic = Data("FAK1".utf8)

    let url: URL
    private let key: SymmetricKey
    private let lock = NSLock()

    public init(url: URL, masterKey: String) throws {
        let trimmed = masterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumMasterKeyLength else { throw Failure.masterKeyTooShort }
        self.url = url
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(trimmed.utf8)),
                                     salt: Data("family-ai-server/keystore".utf8),
                                     info: Data("v1".utf8), outputByteCount: 32)
    }

    /// Master key from `FAMILY_AI_MASTER_KEY_FILE` (path, e.g. a Docker secret) or `FAMILY_AI_MASTER_KEY`.
    public static func masterKey(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let path = env["FAMILY_AI_MASTER_KEY_FILE"], !path.isEmpty {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let v = env["FAMILY_AI_MASTER_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        return nil
    }

    /// True if a key file exists but this master key cannot decrypt it (wrong or changed master key).
    public var isLocked: Bool { lock.withLock { load() == nil } }

    /// nil = the file exists but cannot be decrypted. A missing file is an empty store.
    private func load() -> [String: String]? {
        guard let blob = try? Data(contentsOf: url) else { return [:] }
        guard blob.count > Self.magic.count, blob.prefix(Self.magic.count) == Self.magic,
              let box = try? AES.GCM.SealedBox(combined: blob.dropFirst(Self.magic.count)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Self.magic),
              let map = try? JSONDecoder().decode([String: String].self, from: plain) else { return nil }
        return map
    }

    private func save(_ map: [String: String]) -> Bool {
        guard let plain = try? JSONEncoder().encode(map),
              let box = try? AES.GCM.seal(plain, using: key, authenticating: Self.magic),
              let combined = box.combined else { return false }
        do {
            try (Self.magic + combined).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    public func get(_ account: String) -> String? { lock.withLock { load()?[account] } }

    public func set(_ value: String, for account: String) -> Bool {
        lock.withLock {
            guard var m = load() else { return false }       // never overwrite a file we cannot read
            m[account] = value.isEmpty ? nil : value
            return save(m)
        }
    }

    public func delete(_ account: String) -> Bool {
        lock.withLock {
            guard var m = load() else { return false }
            m[account] = nil
            return save(m)
        }
    }
}
