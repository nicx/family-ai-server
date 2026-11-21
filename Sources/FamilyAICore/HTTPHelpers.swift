import Foundation
import Hummingbird
import HTTPTypes

public struct FamilyContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let peerIP: String?

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        peerIP = source.channel.remoteAddress?.ipAddress
    }
}

struct APIError: Error {
    let status: HTTPResponse.Status
    let message: String
    init(_ status: HTTPResponse.Status, _ message: String) { self.status = status; self.message = message }
    static func bad(_ m: String) -> APIError { .init(.badRequest, m) }
    static let unauthorized = APIError(.unauthorized, "Nicht angemeldet")
    static let forbidden = APIError(.forbidden, "Keine Berechtigung")
    static let notFound = APIError(.notFound, "Nicht gefunden")
}

enum HTTP {
    static func json(_ obj: Any, status: HTTPResponse.Status = .ok, headers: HTTPFields = [:]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        var h = headers
        h[.contentType] = "application/json; charset=utf-8"
        h[.cacheControl] = "no-store"
        return Response(status: status, headers: h, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func encodable<T: Encodable>(_ v: T, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? jsonEncoder.encode(v)) ?? Data("{}".utf8)
        var h = HTTPFields()
        h[.contentType] = "application/json; charset=utf-8"
        h[.cacheControl] = "no-store"
        return Response(status: status, headers: h, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func toJSON<T: Encodable>(_ v: T) -> Any {
        (try? JSONSerialization.jsonObject(with: jsonEncoder.encode(v), options: [.fragmentsAllowed])) ?? NSNull()
    }

    static func data(_ d: Data, mime: String, headers: HTTPFields = [:]) -> Response {
        var h = headers
        h[.contentType] = mime
        h[.contentLength] = String(d.count)
        return Response(status: .ok, headers: h, body: .init(byteBuffer: ByteBuffer(bytes: d)))
    }

    static func ok() -> Response { json(["ok": true]) }

    static func body(_ request: Request, limit: Int = 2_000_000) async throws -> Data {
        var r = request
        let buf = try await r.collectBody(upTo: limit)
        return Data(buf.readableBytesView)
    }

    static func object(_ request: Request) async throws -> [String: Any] {
        let d = try await body(request)
        if d.isEmpty { return [:] }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw APIError.bad("Ungültiges JSON") }
        return o
    }

    static func decode<T: Decodable>(_ t: T.Type, _ request: Request) async throws -> T {
        let d = try await body(request)
        do { return try jsonDecoder.decode(t, from: d) } catch { throw APIError.bad("Ungültige Daten: \(error)") }
    }

    static func cookie(_ request: Request, _ name: String) -> String? {
        guard let header = request.headers[.cookie] else { return nil }
        for part in header.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    static func setCookie(_ name: String, _ value: String, maxAge: Int, secure: Bool) -> String {
        var c = "\(name)=\(value); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(maxAge)"
        if secure { c += "; Secure" }
        return c
    }
}

enum Net {
    /// IPv4/IPv6 addresses of this machine (to recognise a local reverse proxy).
    static let localAddresses: Set<String> = {
        var result: Set<String> = ["127.0.0.1", "::1"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if let sa = cur.pointee.ifa_addr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = sa.pointee.sa_family == UInt8(AF_INET6) ? socklen_t(MemoryLayout<sockaddr_in6>.size) : socklen_t(MemoryLayout<sockaddr_in>.size)
                if (sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6)),
                   getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(cString: host)
                    result.insert(s.split(separator: "%").first.map(String.init) ?? s)
                }
            }
            p = cur.pointee.ifa_next
        }
        return result
    }()

    /// Client address: if the direct peer is this machine (local reverse proxy),
    /// trust the right-most X-Forwarded-For entry.
    static func clientIP(_ request: Request, _ context: FamilyContext) -> String {
        let peer = (context.peerIP ?? "").replacingOccurrences(of: "::ffff:", with: "")
        if localAddresses.contains(peer) || peer.hasPrefix("127."),
           let xff = request.headers[HTTPField.Name("X-Forwarded-For")!] {
            if let last = xff.split(separator: ",").last?.trimmingCharacters(in: .whitespaces), !last.isEmpty {
                return last.replacingOccurrences(of: "::ffff:", with: "")
            }
        }
        return peer
    }

    /// Private/LAN/VPN address ranges (RFC1918, loopback, CGNAT/Tailscale, IPv6 ULA/link-local).
    static func isPrivate(_ ip: String) -> Bool {
        let s = ip.lowercased()
        if s == "::1" || s.hasPrefix("fe80:") || s.hasPrefix("fc") || s.hasPrefix("fd") { return true }
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        case (169, 254): return true
        default: return false
        }
    }
}
