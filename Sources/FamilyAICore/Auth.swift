import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import HummingbirdBcrypt
import WebAuthn

public enum Auth {
    public static let sessionTTL: Double = 60 * 60 * 24 * 30      // 30 days, sliding
    public static let cookieName = "family_ai_session"

    public static func hashPassword(_ pw: String) -> String { Bcrypt.hash(pw, cost: 12) }
    public static func verifyPassword(_ pw: String, hash: String) -> Bool {
        guard !hash.isEmpty else { return false }
        return Bcrypt.verify(pw, hash: hash)
    }

    /// 32 random bytes, base64url.
    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64URLEncoded()
    }
    nonisolated(unsafe) static var rng = SystemRandomNumberGenerator()

    public static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One-time setup code such as `K7QM-3XDA` (no look-alike characters).
    public static func newSetupCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let c = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
        return String(c[0..<4]) + "-" + String(c[4..<8])
    }

    /// Case-, dash- and space-insensitive, constant-time comparison.
    public static func setupCodeMatches(_ given: String, _ expected: String) -> Bool {
        func norm(_ s: String) -> [UInt8] { Array(s.uppercased().filter { $0.isLetter || $0.isNumber }.utf8) }
        let a = norm(given), b = norm(expected)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Minimum password rules: 8+ characters.
    public static func passwordProblem(_ pw: String) -> String? {
        pw.count < 8 ? "Das Passwort muss mindestens 8 Zeichen lang sein." : nil
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Throttles failed logins per username and per client address.
public actor LoginLimiter {
    private var failures: [String: [Double]] = [:]
    private let window: Double = 15 * 60
    private let maxFailures = 8

    public init() {}

    public func isBlocked(_ keys: [String]) -> Bool {
        let t = now()
        for k in keys {
            let recent = (failures[k] ?? []).filter { t - $0 < window }
            failures[k] = recent
            if recent.count >= maxFailures { return true }
        }
        return false
    }

    public func fail(_ keys: [String]) {
        let t = now()
        for k in keys { failures[k, default: []].append(t) }
    }

    public func succeed(_ keys: [String]) {
        for k in keys { failures[k] = nil }
    }
}

/// Simple sliding-window rate limit per key (e.g. per user for model calls).
public actor RateLimiter {
    private var hits: [String: [Double]] = [:]
    let limit: Int
    let window: Double

    public init(limit: Int, window: Double) { self.limit = limit; self.window = window }

    public func allow(_ key: String) -> Bool {
        let t = now()
        var h = (hits[key] ?? []).filter { t - $0 < window }
        guard h.count < limit else { hits[key] = h; return false }
        h.append(t)
        hits[key] = h
        return true
    }
}

/// Short-lived WebAuthn challenges.
public actor ChallengeStore {
    private var items: [String: (challenge: [UInt8], userId: String?, expires: Double)] = [:]
    public init() {}

    public func put(_ id: String, challenge: [UInt8], userId: String?) {
        let t = now()
        items = items.filter { $0.value.expires > t }
        items[id] = (challenge, userId, t + 300)
    }

    public func take(_ id: String) -> (challenge: [UInt8], userId: String?)? {
        guard let v = items.removeValue(forKey: id), v.expires > now() else { return nil }
        return (v.challenge, v.userId)
    }
}

public enum Passkeys {
    /// Relying party from the configured public URL; nil if none is set.
    public static func manager(publicURL: String, name: String) -> WebAuthnManager? {
        guard let url = URL(string: publicURL.trimmingCharacters(in: .whitespaces)),
              let host = url.host, let scheme = url.scheme else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return WebAuthnManager(configuration: .init(relyingPartyID: host, relyingPartyName: name, relyingPartyOrigin: origin))
    }
}
