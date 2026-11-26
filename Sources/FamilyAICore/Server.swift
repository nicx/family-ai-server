import Foundation
import Hummingbird
import HTTPTypes
import WebAuthn

public struct ServerConfig: Sendable {
    public var dataDir: URL
    public var webRoot: URL
    public var host: String
    public var port: Int
    public var keyStore: KeyStore
    /// Reverse proxies whose `X-Forwarded-For` is believed, in addition to this machine itself
    /// (Docker: the proxy container's address range).
    public var trustedProxies: [IPRange]
    /// Docker: the first admin may only be created with a one-time code printed to the log,
    /// so nobody on the network can claim a freshly started, still empty server.
    public var requireSetupCode: Bool

    public init(dataDir: URL, webRoot: URL, host: String = "0.0.0.0", port: Int = 8097, keyStore: KeyStore,
                trustedProxies: [IPRange] = [], requireSetupCode: Bool = false) {
        self.trustedProxies = trustedProxies
        self.requireSetupCode = requireSetupCode
        self.dataDir = dataDir
        self.webRoot = webRoot
        self.host = host
        self.port = port
        self.keyStore = keyStore
    }
}

/// The Family AI Server server: JSON API, streaming chat, runner endpoints and the web app.
public final class FamilyServer: Sendable {
    public let config: ServerConfig
    public let store: Store
    let router: OpenRouter
    let keys: KeyStore
    let catalog: ModelCatalog
    let runner: RunnerHub
    let engine: ChatEngine
    public let budget: BudgetMonitor
    let limiter = LoginLimiter()
    /// One-time code for the first admin (nil if not required or already set up).
    let setupCode: String?
    let chatLimiter = RateLimiter(limit: 200, window: 3600)
    let runningChats = RunningChats()
    let challenges = ChallengeStore()
    public let version: String
    let assetVersion = String(Int(Date().timeIntervalSince1970), radix: 36)

    public init(config: ServerConfig, version: String = "0.1.0") async throws {
        self.config = config
        self.version = version
        store = try await Store(dataDir: config.dataDir)
        // Test hook: point model traffic at a local mock (never set in normal operation).
        if let u = ProcessInfo.processInfo.environment["FAMILY_AI_OPENROUTER_URL"], let url = URL(string: u) {
            router = OpenRouter(baseURL: url)
        } else {
            router = OpenRouter()
        }
        keys = config.keyStore
        catalog = ModelCatalog(router: router)
        runner = RunnerHub()
        engine = ChatEngine(store: store, router: router, keys: keys, catalog: catalog, runner: runner)
        budget = BudgetMonitor(store: store, router: router, keys: keys)
        if config.requireSetupCode, try await store.userCount() == 0 {
            let code = Auth.newSetupCode()
            setupCode = code
            FileHandle.standardOutput.write(Data("""

            ==> Einrichtungscode für den ersten Admin: \(code)
                (gilt bis zur Einrichtung; nach einem Neustart wird ein neuer erzeugt)


            """.utf8))
        } else {
            setupCode = nil
        }
    }

    // MARK: - Run

    public func run() async throws {
        let app = Application(router: buildRouter(),
                              configuration: .init(address: .hostname(config.host, port: config.port), serverName: nil))
        let maintenance = Task.detached { [self] in await self.maintenanceLoop() }
        defer { maintenance.cancel() }
        try await app.run()
    }

    func maintenanceLoop() async {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        var tick = 0
        while !Task.isCancelled {
            if tick % 60 == 0 {          // hourly
                await budget.checkAll()
                try? await store.purgeExpiredSessions()
                if let s = try? await store.settings(), s.retentionDays > 0 {
                    _ = try? await store.purgeOldChats(days: s.retentionDays)
                }
                try? await store.purgeOrphanFiles()
            }
            tick += 1
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    // MARK: - Auth helpers

    struct Session { let user: User; let tokenHash: String }

    func session(_ request: Request) async throws -> Session {
        guard let token = HTTP.cookie(request, Auth.cookieName) else { throw APIError.unauthorized }
        let hash = Auth.sha256(token)
        guard let s = try await store.session(tokenHash: hash), s.expires > now(),
              let user = try await store.user(id: s.userId), !user.disabled else { throw APIError.unauthorized }
        if now() - s.lastSeen > 3600 { try await store.touchSession(tokenHash: hash, ttl: Auth.sessionTTL) }
        return Session(user: user, tokenHash: hash)
    }

    func admin(_ request: Request, _ context: FamilyContext) async throws -> Session {
        let s = try await session(request)
        guard s.user.role == .admin else { throw APIError.forbidden }
        let settings = try await store.settings()
        if settings.adminLocalOnly && !Net.isPrivate(Net.clientIP(request, context, trusted: config.trustedProxies)) {
            throw APIError(.forbidden, "Der Admin-Bereich ist nur aus dem Heimnetz/VPN erreichbar.")
        }
        return s
    }

    func isSecure(_ request: Request) -> Bool {
        request.headers[HTTPField.Name("X-Forwarded-Proto")!] == "https"
    }

    func loginResponse(user: User, request: Request) async throws -> Response {
        let token = Auth.randomToken()
        try await store.createSession(tokenHash: Auth.sha256(token), userId: user.id, ttl: Auth.sessionTTL,
                                      userAgent: request.headers[.userAgent])
        var h = HTTPFields()
        h[.setCookie] = HTTP.setCookie(Auth.cookieName, token, maxAge: Int(Auth.sessionTTL), secure: isSecure(request))
        return HTTP.json(["ok": true, "user": publicUser(user)], headers: h)
    }

    func publicUser(_ u: User) -> [String: Any] {
        ["id": u.id, "username": u.username, "displayName": u.displayName, "role": u.role.rawValue,
         "profile": HTTP.toJSON(u.profile), "disabled": u.disabled, "createdAt": u.createdAt]
    }

    func ownedChat(_ id: String, _ user: User) async throws -> Chat {
        guard let c = try await store.chat(id: id), c.userId == user.id else { throw APIError.notFound }
        return c
    }

    /// May `viewer` read chats of `owner`? (own, or parent/admin reading a child with parental view).
    func canRead(viewer: User, ownerId: String) async throws -> Bool {
        if viewer.id == ownerId { return true }
        guard viewer.role == .parent || viewer.role == .admin,
              let owner = try await store.user(id: ownerId) else { return false }
        return owner.role == .child && owner.profile.parentalView
    }

    func allowedModels(for user: User) async -> [ModelInfo] {
        let models = await catalog.chatModels()
        // Admins see every model. Everyone else: the default models + personal extras.
        if user.role == .admin { return models }
        let settings = (try? await store.settings()) ?? GlobalSettings()
        let ids = Set(user.profile.allowedModels + [settings.defaultModel, user.profile.defaultModel ?? ""])
        return models.filter { ids.contains($0.id) }
    }

    /// Model for the one-off "answer with a stronger model" action, nil if disabled for this person.
    func escalationModel(for user: User) async -> String? {
        let p = user.profile.escalationModel
        if p == "off" { return nil }
        if !p.isEmpty { return p }
        let g = (try? await store.settings())?.escalationModel ?? ""
        return g.isEmpty ? nil : g
    }

    func defaultModel(for user: User, models: [ModelInfo]) async -> String? {
        let global = (try? await store.settings())?.defaultModel ?? ""
        for candidate in [user.profile.defaultModel ?? "", global] where !candidate.isEmpty {
            if models.contains(where: { $0.id == candidate }) { return candidate }
        }
        return models.first?.id
    }

    // MARK: - Router

    func buildRouter() -> Router<FamilyContext> {
        let r = Router(context: FamilyContext.self)
        r.add(middleware: SecurityMiddleware())
        r.add(middleware: ErrorMiddleware())
        let api = r.group("api")
        registerPublic(api)
        registerUser(api)
        registerChat(api)
        registerFiles(api)
        registerPasskeys(api)
        registerFamily(api)
        registerAdmin(api)
        registerRunner(api)
        r.get("**") { [self] request, _ in try self.staticFile(request) }
        r.get("/") { [self] request, _ in try self.staticFile(request) }
        return r
    }

    // MARK: Static web app

    func staticFile(_ request: Request) throws -> Response {
        var path = request.uri.path
        if path.hasPrefix("/api") { throw APIError.notFound }
        if path == "/" || path.isEmpty { path = "/index.html" }
        let clean = path.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        var url = config.webRoot.appendingPathComponent(clean)
        var isDir: ObjCBool = false
        let isDownload = clean.hasPrefix("runner/")
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || isDir.boolValue {
            // Downloads never fall back to the app shell (a missing .exe must not turn into HTML).
            if isDownload { throw APIError.notFound }
            url = config.webRoot.appendingPathComponent("index.html")   // SPA fallback
        }
        guard var data = try? Data(contentsOf: url) else { throw APIError.notFound }
        let mime = isDownload && url.lastPathComponent == "SHA256SUMS" ? "text/plain; charset=utf-8" : Self.mimeType(url.pathExtension)
        // Cache-busting token for the app shell (changes with every server start).
        if ["html", "js"].contains(url.pathExtension), let text = String(data: data, encoding: .utf8), text.contains("__V__") {
            data = Data(text.replacingOccurrences(of: "__V__", with: assetVersion).utf8)
        }
        var h = HTTPFields()
        h[.cacheControl] = "no-cache"
        if isDownload && url.lastPathComponent.hasPrefix("family-ai-runner-") {
            h[.contentDisposition] = "attachment; filename=\"\(url.lastPathComponent)\""
        }
        return HTTP.data(data, mime: mime, headers: h)
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    // MARK: Public

    func registerPublic(_ api: RouterGroup<FamilyContext>) {
        api.get("info") { [self] _, _ in
            let s = try await store.settings()
            let needsSetup = try await store.userCount() == 0
            return HTTP.json(["aiName": s.aiName, "language": s.language, "needsSetup": needsSetup, "setupCodeRequired": needsSetup && setupCode != nil,
                              "passkeys": Passkeys.manager(publicURL: s.publicURL, name: s.aiName) != nil,
                              "publicURL": s.publicURL, "version": version, "build": assetVersion])
        }

        api.post("setup") { [self] request, context in
            guard try await store.userCount() == 0 else { throw APIError.forbidden }
            let o = try await HTTP.object(request)
            if let expected = setupCode {
                let limitKeys = ["setup", "ip:" + Net.clientIP(request, context, trusted: config.trustedProxies)]
                if await limiter.isBlocked(limitKeys) {
                    throw APIError(.tooManyRequests, "Zu viele Fehlversuche. Bitte in 15 Minuten erneut versuchen.")
                }
                guard Auth.setupCodeMatches((o["setupCode"] as? String) ?? "", expected) else {
                    await limiter.fail(limitKeys)
                    throw APIError(.forbidden, "Der Einrichtungscode stimmt nicht. Er steht im Protokoll des Containers (docker logs).")
                }
            }
            let username = ((o["username"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let display = ((o["displayName"] as? String) ?? username).trimmingCharacters(in: .whitespaces)
            let pw = (o["password"] as? String) ?? ""
            guard Self.validUsername(username) else { throw APIError.bad("Benutzername: 2–32 Zeichen, nur Buchstaben, Ziffern, . _ -") }
            if let p = Auth.passwordProblem(pw) { throw APIError.bad(p) }
            var s = try await store.settings()
            if let ai = o["aiName"] as? String, !ai.isEmpty { s.aiName = String(ai.prefix(40)) }
            if let fam = o["familyName"] as? String { s.familyName = String(fam.prefix(60)) }
            if let lang = o["language"] as? String, ["de", "en"].contains(lang) { s.language = lang }
            try await store.saveSettings(s)
            let user = try await store.createUser(username: username, displayName: display.isEmpty ? username : display,
                                                  role: .admin, passwordHash: Auth.hashPassword(pw), profile: Profile.defaults(for: .admin))
            if let key = o["apiKey"] as? String, !key.isEmpty { keys.set(key.trimmingCharacters(in: .whitespaces), for: user.id) }
            return try await loginResponse(user: user, request: request)
        }

        api.post("login") { [self] request, context in
            let o = try await HTTP.object(request)
            let username = ((o["username"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let pw = (o["password"] as? String) ?? ""
            let ip = Net.clientIP(request, context, trusted: config.trustedProxies)
            let limitKeys = ["u:" + username, "ip:" + ip]
            if await limiter.isBlocked(limitKeys) {
                throw APIError(.tooManyRequests, "Zu viele Fehlversuche. Bitte in 15 Minuten erneut versuchen.")
            }
            guard let (user, hash) = try await store.userWithHash(username: username), !user.disabled,
                  Auth.verifyPassword(pw, hash: hash) else {
                await limiter.fail(limitKeys)
                try await Task.sleep(nanoseconds: 400_000_000)
                throw APIError(.unauthorized, "Benutzername oder Passwort falsch")
            }
            await limiter.succeed(limitKeys)
            return try await loginResponse(user: user, request: request)
        }

        api.post("logout") { [self] request, _ in
            if let token = HTTP.cookie(request, Auth.cookieName) { try? await store.deleteSession(tokenHash: Auth.sha256(token)) }
            var h = HTTPFields()
            h[.setCookie] = HTTP.setCookie(Auth.cookieName, "", maxAge: 0, secure: isSecure(request))
            return HTTP.json(["ok": true], headers: h)
        }
    }

    static func validUsername(_ s: String) -> Bool {
        guard (2...32).contains(s.count) else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    // MARK: User

    func registerUser(_ api: RouterGroup<FamilyContext>) {
        api.get("me") { [self] request, _ in
            let s = try await session(request)
            let settings = try await store.settings()
            var out: [String: Any] = ["user": publicUser(s.user), "aiName": settings.aiName, "language": settings.language,
                                      "familyName": settings.familyName]
            if s.user.role == .child && settings.kidNoticeVisible && s.user.profile.parentalView {
                out["parentNotice"] = true
            }
            out["hasKey"] = keys.get(s.user.id) != nil
            return HTTP.json(out)
        }

        // Nur Prozent und Rücksetzzeitpunkt – keine Beträge (die sieht nur die Admin-Ansicht).
        api.get("me/budget") { [self] request, _ in
            let s = try await session(request)
            guard let st = await budget.recent(userId: s.user.id) else { return HTTP.json(["available": false]) }
            var out: [String: Any] = ["available": true, "hasLimit": st.fraction != nil, "reset": st.reset as Any]
            if let f = st.fraction { out["percent"] = Int((f * 100).rounded(.down)) }
            if let d = st.nextReset() { out["resetsAt"] = ISO8601DateFormatter().string(from: d) }
            return HTTP.json(out)
        }

        api.post("me/password") { [self] request, _ in
            let s = try await session(request)
            let o = try await HTTP.object(request)
            guard let (_, hash) = try await store.userWithHash(username: s.user.username),
                  Auth.verifyPassword((o["old"] as? String) ?? "", hash: hash) else { throw APIError.bad("Altes Passwort stimmt nicht") }
            let new = (o["new"] as? String) ?? ""
            if let p = Auth.passwordProblem(new) { throw APIError.bad(p) }
            try await store.setPassword(userId: s.user.id, hash: Auth.hashPassword(new))
            return HTTP.ok()
        }

        api.get("models") { [self] request, _ in
            let s = try await session(request)
            let models = await allowedModels(for: s.user)
            let def = await defaultModel(for: s.user, models: models)
            return HTTP.json(["models": models.map { ["id": $0.id, "name": $0.name, "vision": $0.inputModalities.contains("image"),
                                                      "tools": $0.supportsTools, "imageOut": $0.outputModalities.contains("image")] },
                              "default": def as Any,
                              "escalation": await escalationModel(for: s.user) != nil])
        }

        api.get("memories") { [self] request, _ in
            let s = try await session(request)
            return HTTP.encodable(try await store.memories(userId: s.user.id))
        }
        api.post("memories") { [self] request, _ in
            let s = try await session(request)
            let o = try await HTTP.object(request)
            let c = ((o["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty else { throw APIError.bad("Leer") }
            return HTTP.encodable(try await store.addMemory(userId: s.user.id, content: String(c.prefix(500))))
        }
        api.delete("memories/:id") { [self] request, context in
            let s = try await session(request)
            _ = try await store.deleteMemory(userId: s.user.id, id: try context.parameters.require("id"))
            return HTTP.ok()
        }

        api.post("tts") { [self] request, _ in
            let s = try await session(request)
            guard s.user.profile.voice else { throw APIError.forbidden }
            guard let key = keys.get(s.user.id) else { throw APIError.bad("Kein OpenRouter-Schlüssel hinterlegt") }
            let o = try await HTTP.object(request)
            let text = Self.speakable((o["text"] as? String) ?? "")
            guard !text.isEmpty else { throw APIError.bad("Kein Text") }
            let settings = try await store.settings()
            let audio = try await router.speech(key: key, model: settings.ttsModel, voice: settings.ttsVoice, text: String(text.prefix(4000)))
            return HTTP.data(audio, mime: "audio/mpeg")
        }

        api.post("stt") { [self] request, _ in
            let s = try await session(request)
            guard s.user.profile.voice else { throw APIError.forbidden }
            guard let key = keys.get(s.user.id) else { throw APIError.bad("Kein OpenRouter-Schlüssel hinterlegt") }
            let data = try await HTTP.body(request, limit: 25_000_000)
            guard !data.isEmpty else { throw APIError.bad("Keine Aufnahme") }
            let mime = request.headers[.contentType] ?? "audio/webm"
            let settings = try await store.settings()
            let (audio, format) = AudioConvert.prepare(data: data, mime: mime)
            let text = try await router.transcribe(key: key, model: settings.sttModel, audio: audio, format: format,
                                                   language: settings.language)
            return HTTP.json(["text": text])
        }
    }

    /// Strips Markdown so TTS does not read symbols aloud.
    static func speakable(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_`#>|]", with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Chat

    func registerChat(_ api: RouterGroup<FamilyContext>) {
        api.get("chats") { [self] request, _ in
            let s = try await session(request)
            let q = request.uri.queryParameters.get("q")
            return HTTP.encodable(try await store.chats(userId: s.user.id, search: q))
        }

        api.post("chats") { [self] request, _ in
            let s = try await session(request)
            let o = try await HTTP.object(request)
            let models = await allowedModels(for: s.user)
            var model = (o["model"] as? String) ?? ""
            if !models.contains(where: { $0.id == model }) {
                model = await defaultModel(for: s.user, models: models) ?? ""
            }
            guard !model.isEmpty else { throw APIError.bad("Kein Modell freigegeben") }
            var mode = (o["mode"] as? String) == "code" ? "code" : "chat"
            var deviceId = o["deviceId"] as? String
            if mode == "code" {
                guard s.user.profile.code else { throw APIError.forbidden }
                if let d = deviceId, try await store.device(id: d)?.userId != s.user.id { deviceId = nil }
                if deviceId == nil { mode = "chat" }
            } else { deviceId = nil }
            let chat = try await store.createChat(userId: s.user.id, title: (o["title"] as? String) ?? "Neuer Chat",
                                                  model: model, mode: mode, deviceId: deviceId)
            return HTTP.encodable(chat)
        }

        api.get("chats/:id") { [self] request, context in
            let s = try await session(request)
            guard let chat = try await store.chat(id: try context.parameters.require("id")),
                  try await canRead(viewer: s.user, ownerId: chat.userId) else { throw APIError.notFound }
            let msgs = try await store.messages(chatId: chat.id)
            let owner = chat.userId == s.user.id ? s.user.displayName : (try await store.user(id: chat.userId))?.displayName ?? ""
            return HTTP.json(["chat": HTTP.toJSON(chat), "messages": HTTP.toJSON(msgs), "readOnly": chat.userId != s.user.id,
                              "ownerName": owner, "running": await runningChats.contains(chat.id)])
        }

        api.patch("chats/:id") { [self] request, context in
            let s = try await session(request)
            var chat = try await ownedChat(try context.parameters.require("id"), s.user)
            let o = try await HTTP.object(request)
            if let t = o["title"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty { chat.title = String(t.prefix(120)) }
            if let m = o["model"] as? String {
                guard await allowedModels(for: s.user).contains(where: { $0.id == m }) else { throw APIError.forbidden }
                chat.model = m
            }
            if let mode = o["mode"] as? String {
                if mode == "code" {
                    guard s.user.profile.code else { throw APIError.forbidden }
                    guard let did = o["deviceId"] as? String, let d = try await store.device(id: did), d.userId == s.user.id else {
                        throw APIError.bad("Computer nicht gefunden")
                    }
                    chat.mode = "code"; chat.deviceId = d.id
                } else {
                    chat.mode = "chat"; chat.deviceId = nil
                }
            }
            try await store.updateChat(chat)
            return HTTP.encodable(chat)
        }

        api.delete("chats/:id") { [self] request, context in
            let s = try await session(request)
            let chat = try await ownedChat(try context.parameters.require("id"), s.user)
            try await store.deleteChat(id: chat.id)
            return HTTP.ok()
        }

        api.post("chats/:id/messages") { [self] request, context in
            let s = try await session(request)
            let chat = try await ownedChat(try context.parameters.require("id"), s.user)
            guard await chatLimiter.allow(s.user.id) else { throw APIError(.tooManyRequests, "Zu viele Nachrichten in kurzer Zeit.") }
            let o = try await HTTP.object(request)
            let content = ((o["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fileIds = (o["attachments"] as? [String]) ?? []
            var atts: [Attachment] = []
            for id in fileIds.prefix(10) {
                guard let f = try await store.file(id: id), f.userId == s.user.id else { continue }
                atts.append(Attachment(fileId: f.id, name: f.name, mime: f.mime, kind: f.kind))
            }
            guard !content.isEmpty || !atts.isEmpty else { throw APIError.bad("Leere Nachricht") }
            let isFirst = try await store.messages(chatId: chat.id).isEmpty
            let msg = Message(id: newID(), chatId: chat.id, role: "user", content: String(content.prefix(100_000)),
                              attachments: atts, meta: MessageMeta(), createdAt: now())
            try await store.addMessage(msg)
            return streamAnswer(user: s.user, chat: chat, userMessage: msg, makeTitle: isFirst)
        }

        api.post("chats/:id/regenerate") { [self] request, context in
            let s = try await session(request)
            let chat = try await ownedChat(try context.parameters.require("id"), s.user)
            let msgs = try await store.messages(chatId: chat.id)
            if let last = msgs.last, last.role == "assistant" {
                try await store.deleteMessages(chatId: chat.id, after: last.createdAt)
            }
            guard try await store.messages(chatId: chat.id).last?.role == "user" else { throw APIError.bad("Nichts zu wiederholen") }
            // Einmalig mit dem Eskalationsmodell antworten; das Chat-Modell bleibt unverändert.
            var answerChat = chat
            let o = (try? await HTTP.object(request)) ?? [:]
            if (o["escalate"] as? Bool) == true {
                guard let esc = await escalationModel(for: s.user) else { throw APIError.forbidden }
                answerChat.model = esc
            }
            return streamAnswer(user: s.user, chat: answerChat, userMessage: nil, makeTitle: false)
        }
    }

    /// Runs the engine detached (it finishes and saves even if the browser disconnects)
    /// and streams its events as server-sent events.
    func streamAnswer(user: User, chat: Chat, userMessage: Message?, makeTitle: Bool) -> Response {
        let (stream, cont) = AsyncStream<String>.makeStream()
        let engine = self.engine
        let store = self.store
        let running = self.runningChats
        Task.detached {
            await running.begin(chat.id)
            if let userMessage {
                cont.yield(Self.sse(["t": "user", "message": HTTP.toJSON(userMessage)]))
            }
            let final = await engine.respond(user: user, chat: chat) { ev in
                cont.yield(Self.sse(ev.json))
            }
            await running.end(chat.id)
            if let final { cont.yield(Self.sse(ChatEvent.done(final).json)) }
            if makeTitle, let first = userMessage?.content, !first.isEmpty,
               let title = await engine.makeTitle(user: user, chat: chat, firstMessage: first),
               var c = try? await store.chat(id: chat.id) {
                c.title = title
                try? await store.updateChat(c)
                cont.yield(Self.sse(["t": "title", "v": title]))
            }
            cont.yield(Self.sse(["t": "end"]))
            cont.finish()
        }
        var h = HTTPFields()
        h[.contentType] = "text/event-stream; charset=utf-8"
        h[.cacheControl] = "no-cache"
        h[HTTPField.Name("X-Accel-Buffering")!] = "no"
        return Response(status: .ok, headers: h, body: ResponseBody { writer in
            do {
                for await chunk in stream {
                    try await writer.write(ByteBuffer(string: chunk))
                }
            } catch {
                // Browser went away; the detached task keeps running and saves the answer.
            }
            try? await writer.finish(nil)
        })
    }

    static func sse(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return "data: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
    }

    // MARK: Files & documents

    func registerFiles(_ api: RouterGroup<FamilyContext>) {
        api.post("files") { [self] request, _ in
            let s = try await session(request)
            let rawName = request.headers[HTTPField.Name("X-Filename")!].flatMap { $0.removingPercentEncoding } ?? "datei"
            let name = String(rawName.replacingOccurrences(of: "/", with: "_").prefix(200))
            let mime = (request.headers[.contentType] ?? "application/octet-stream").split(separator: ";").first.map(String.init) ?? "application/octet-stream"
            let data = try await HTTP.body(request, limit: 25_000_000)
            guard !data.isEmpty else { throw APIError.bad("Leere Datei") }
            let asDocument = request.uri.queryParameters.get("library") == "1"
            if mime.hasPrefix("image/") && !asDocument {
                guard ["image/png", "image/jpeg", "image/gif", "image/webp", "image/heic"].contains(mime) else {
                    throw APIError.bad("Bildformat nicht unterstützt")
                }
                var imgData = data, imgMime = mime
                if mime == "image/heic", let jpg = AudioConvert.heicToJPEG(data) { imgData = jpg; imgMime = "image/jpeg" }
                let rec = try await store.saveFile(userId: s.user.id, name: name, mime: imgMime, kind: "image", data: imgData)
                return HTTP.encodable(rec)
            }
            guard let text = Documents.extractText(data: data, name: name, mime: mime) else {
                throw APIError.bad("Dateityp wird nicht unterstützt (Bilder, PDF, Word, Text).")
            }
            let rec = try await store.saveFile(userId: s.user.id, name: name, mime: mime, kind: "document", data: data, text: text)
            // Long documents (and everything in the library) get indexed for search_documents.
            if s.user.profile.documents && (asDocument || text.count > ChatEngine.inlineTextLimit), let key = keys.get(s.user.id) {
                let settings = try await store.settings()
                let store = self.store, router = self.router, uid = s.user.id
                Task.detached {
                    do {
                        try await Documents.index(fileId: rec.id, userId: uid, text: text, store: store, router: router,
                                                  key: key, model: settings.embedModel)
                    } catch {
                        // Keyword search still works; record why semantic search is unavailable.
                        try? await store.setMeta("index.error.\(rec.id)", "\(error)")
                    }
                }
            }
            return HTTP.encodable(rec)
        }

        api.get("files/:id") { [self] request, context in
            let s = try await session(request)
            guard let f = try await store.file(id: try context.parameters.require("id")),
                  try await canRead(viewer: s.user, ownerId: f.userId),
                  let data = try? Data(contentsOf: store.filePath(id: f.id)) else { throw APIError.notFound }
            var h = HTTPFields()
            h[.cacheControl] = "private, max-age=86400"
            let safeName = f.name.replacingOccurrences(of: "\"", with: "")
            let inline = f.mime.hasPrefix("image/") || f.mime == "application/pdf"
            h[.contentDisposition] = "\(inline ? "inline" : "attachment"); filename*=UTF-8''\(safeName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "datei")"
            return HTTP.data(data, mime: f.mime, headers: h)
        }

        api.get("documents") { [self] request, _ in
            let s = try await session(request)
            return HTTP.encodable(try await store.documents(userId: s.user.id))
        }

        api.delete("documents/:id") { [self] request, context in
            let s = try await session(request)
            guard let f = try await store.file(id: try context.parameters.require("id")), f.userId == s.user.id else { throw APIError.notFound }
            try await store.deleteFile(id: f.id)
            return HTTP.ok()
        }
    }

    // MARK: Passkeys

    func registerPasskeys(_ api: RouterGroup<FamilyContext>) {
        api.get("passkeys") { [self] request, _ in
            let s = try await session(request)
            return HTTP.encodable(try await store.passkeys(userId: s.user.id))
        }
        api.delete("passkeys/:id") { [self] request, context in
            let s = try await session(request)
            try await store.deletePasskey(id: try context.parameters.require("id"), userId: s.user.id)
            return HTTP.ok()
        }

        api.post("passkeys/register/begin") { [self] request, _ in
            let s = try await session(request)
            let settings = try await store.settings()
            guard let wa = Passkeys.manager(publicURL: settings.publicURL, name: settings.aiName) else {
                throw APIError.bad("Passkeys brauchen eine öffentliche Adresse (Admin → Einstellungen).")
            }
            let options = wa.beginRegistration(user: .init(id: Array(s.user.id.utf8), name: s.user.username, displayName: s.user.displayName),
                                               authenticatorSelection: .init(residentKey: .required, userVerification: .preferred))
            let cid = newID()
            await challenges.put(cid, challenge: options.challenge, userId: s.user.id)
            return HTTP.json(["challengeId": cid, "options": HTTP.toJSON(options)])
        }

        api.post("passkeys/register/finish") { [self] request, _ in
            let s = try await session(request)
            let o = try await HTTP.object(request)
            guard let cid = o["challengeId"] as? String, let ch = await challenges.take(cid), ch.userId == s.user.id,
                  let credObj = o["credential"] else { throw APIError.bad("Abgelaufen, bitte erneut versuchen") }
            let settings = try await store.settings()
            guard let wa = Passkeys.manager(publicURL: settings.publicURL, name: settings.aiName) else { throw APIError.bad("Keine öffentliche Adresse") }
            let credData = try JSONSerialization.data(withJSONObject: credObj)
            let reg = try jsonDecoder.decode(RegistrationCredential.self, from: credData)
            let store = self.store
            let cred = try await wa.finishRegistration(challenge: ch.challenge, credentialCreationData: reg) { id in
                (try? await store.passkey(id: id)) == nil
            }
            let name = ((o["name"] as? String) ?? "Passkey").prefix(60)
            try await store.addPasskey(id: reg.id.asString(), userId: s.user.id, name: String(name), publicKey: cred.publicKey, signCount: cred.signCount)
            return HTTP.ok()
        }

        api.post("passkeys/login/begin") { [self] _, _ in
            let settings = try await store.settings()
            guard let wa = Passkeys.manager(publicURL: settings.publicURL, name: settings.aiName) else { throw APIError.bad("Passkeys nicht eingerichtet") }
            let options = wa.beginAuthentication(userVerification: .preferred)
            let cid = newID()
            await challenges.put(cid, challenge: options.challenge, userId: nil)
            return HTTP.json(["challengeId": cid, "options": HTTP.toJSON(options)])
        }

        api.post("passkeys/login/finish") { [self] request, context in
            let o = try await HTTP.object(request)
            let ip = Net.clientIP(request, context, trusted: config.trustedProxies)
            if await limiter.isBlocked(["ip:" + ip]) { throw APIError(.tooManyRequests, "Zu viele Fehlversuche.") }
            guard let cid = o["challengeId"] as? String, let ch = await challenges.take(cid), let credObj = o["credential"] else {
                throw APIError.bad("Abgelaufen, bitte erneut versuchen")
            }
            let settings = try await store.settings()
            guard let wa = Passkeys.manager(publicURL: settings.publicURL, name: settings.aiName) else { throw APIError.bad("Passkeys nicht eingerichtet") }
            let cred = try jsonDecoder.decode(AuthenticationCredential.self, from: JSONSerialization.data(withJSONObject: credObj))
            guard let pk = try await store.passkey(id: cred.id.asString()) else {
                await limiter.fail(["ip:" + ip])
                throw APIError(.unauthorized, "Passkey unbekannt")
            }
            do {
                let v = try wa.finishAuthentication(credential: cred, expectedChallenge: ch.challenge,
                                                    credentialPublicKey: pk.publicKey, credentialCurrentSignCount: pk.signCount)
                try await store.updatePasskeyCount(id: cred.id.asString(), signCount: v.newSignCount)
            } catch {
                await limiter.fail(["ip:" + ip])
                throw APIError(.unauthorized, "Passkey-Prüfung fehlgeschlagen")
            }
            guard let user = try await store.user(id: pk.userId), !user.disabled else { throw APIError.unauthorized }
            return try await loginResponse(user: user, request: request)
        }
    }

    // MARK: Family (parental view)

    func registerFamily(_ api: RouterGroup<FamilyContext>) {
        api.get("family/children") { [self] request, _ in
            let s = try await session(request)
            guard s.user.role == .parent || s.user.role == .admin else { throw APIError.forbidden }
            let kids = try await store.users().filter { $0.role == .child && $0.profile.parentalView && !$0.disabled }
            return HTTP.json(kids.map { ["id": $0.id, "displayName": $0.displayName] })
        }
        api.get("family/children/:id/chats") { [self] request, context in
            let s = try await session(request)
            let kid = try context.parameters.require("id")
            guard try await canRead(viewer: s.user, ownerId: kid), kid != s.user.id else { throw APIError.forbidden }
            return HTTP.encodable(try await store.chats(userId: kid))
        }
        // Read-only view of a child's memory — only while parental view is on for that child.
        api.get("family/children/:id/memories") { [self] request, context in
            let s = try await session(request)
            let kid = try context.parameters.require("id")
            guard try await canRead(viewer: s.user, ownerId: kid), kid != s.user.id else { throw APIError.forbidden }
            return HTTP.encodable(try await store.memories(userId: kid))
        }
    }

    // MARK: Admin

    func registerAdmin(_ api: RouterGroup<FamilyContext>) {
        api.get("admin/settings") { [self] request, context in
            _ = try await admin(request, context)
            var out = HTTP.toJSON(try await store.settings()) as? [String: Any] ?? [:]
            out["smtpPasswordSet"] = keys.get(GlobalSettings.smtpPasswordAccount) != nil
            return HTTP.json(out)
        }
        api.put("admin/settings") { [self] request, context in
            _ = try await admin(request, context)
            let raw = try await HTTP.body(request)
            var s: GlobalSettings
            do { s = try jsonDecoder.decode(GlobalSettings.self, from: raw) } catch { throw APIError.bad("Ungültige Einstellungen") }
            // The SMTP password is write-only: absent = keep, empty string = delete.
            if let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let pw = o["smtpPassword"] as? String {
                if pw.isEmpty { keys.delete(GlobalSettings.smtpPasswordAccount) }
                else { keys.set(pw, for: GlobalSettings.smtpPasswordAccount) }
            }
            if Mailer.Security(rawValue: s.smtpSecurity) == nil { s.smtpSecurity = "none" }
            s.smtpUser = s.smtpUser.trimmingCharacters(in: .whitespaces)
            s.aiName = String(s.aiName.trimmingCharacters(in: .whitespaces).prefix(40))
            if s.aiName.isEmpty { s.aiName = "Lumi" }
            if !["de", "en"].contains(s.language) { s.language = "de" }
            s.retentionDays = max(0, s.retentionDays)
            s.budgetThreshold = min(99, max(1, s.budgetThreshold))
            s.webSearchMaxResults = min(25, max(1, s.webSearchMaxResults))
            try await store.saveSettings(s)
            return HTTP.encodable(s)
        }

        api.get("admin/users") { [self] request, context in
            _ = try await admin(request, context)
            let users = try await store.users()
            return HTTP.json(users.map { u -> [String: Any] in
                var d = publicUser(u)
                d["hasKey"] = keys.get(u.id) != nil
                return d
            })
        }

        api.post("admin/users") { [self] request, context in
            _ = try await admin(request, context)
            let o = try await HTTP.object(request)
            let username = ((o["username"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard Self.validUsername(username) else { throw APIError.bad("Benutzername: 2–32 Zeichen, nur Buchstaben, Ziffern, . _ -") }
            guard try await store.userWithHash(username: username) == nil else { throw APIError.bad("Benutzername ist vergeben") }
            let role = Role(rawValue: (o["role"] as? String) ?? "") ?? .child
            let pw = (o["password"] as? String) ?? ""
            if let p = Auth.passwordProblem(pw) { throw APIError.bad(p) }
            var profile = Profile.defaults(for: role)
            if let po = o["profile"], let d = try? JSONSerialization.data(withJSONObject: po), let p = try? jsonDecoder.decode(Profile.self, from: d) {
                profile = p
            }
            let display = ((o["displayName"] as? String) ?? username).trimmingCharacters(in: .whitespaces)
            let u = try await store.createUser(username: username, displayName: display.isEmpty ? username : display,
                                               role: role, passwordHash: Auth.hashPassword(pw), profile: profile)
            if let key = o["apiKey"] as? String, !key.trimmingCharacters(in: .whitespaces).isEmpty {
                keys.set(key.trimmingCharacters(in: .whitespaces), for: u.id)
            }
            return HTTP.json(publicUser(u))
        }

        api.put("admin/users/:id") { [self] request, context in
            let me = try await admin(request, context)
            let id = try context.parameters.require("id")
            guard var u = try await store.user(id: id) else { throw APIError.notFound }
            let o = try await HTTP.object(request)
            if let d = o["displayName"] as? String, !d.trimmingCharacters(in: .whitespaces).isEmpty { u.displayName = String(d.prefix(60)) }
            if let r = o["role"] as? String, let role = Role(rawValue: r) {
                if u.id == me.user.id && role != .admin { throw APIError.bad("Du kannst dir die Admin-Rolle nicht selbst entziehen.") }
                u.role = role
            }
            if let dis = o["disabled"] as? Bool {
                if u.id == me.user.id && dis { throw APIError.bad("Du kannst dich nicht selbst sperren.") }
                u.disabled = dis
            }
            if let po = o["profile"], let d = try? JSONSerialization.data(withJSONObject: po), let p = try? jsonDecoder.decode(Profile.self, from: d) {
                u.profile = p
            }
            try await store.updateUser(u)
            if let pw = o["password"] as? String, !pw.isEmpty {
                if let p = Auth.passwordProblem(pw) { throw APIError.bad(p) }
                try await store.setPassword(userId: u.id, hash: Auth.hashPassword(pw))
                try await store.deleteSessions(userId: u.id)
            }
            if let key = o["apiKey"] as? String {
                let k = key.trimmingCharacters(in: .whitespaces)
                if k.isEmpty { keys.delete(u.id) } else { keys.set(k, for: u.id) }
                _ = await budget.refresh(userId: u.id)
            }
            if u.disabled { try await store.deleteSessions(userId: u.id) }
            var d = publicUser(u)
            d["hasKey"] = keys.get(u.id) != nil
            return HTTP.json(d)
        }

        api.delete("admin/users/:id") { [self] request, context in
            let me = try await admin(request, context)
            let id = try context.parameters.require("id")
            guard id != me.user.id else { throw APIError.bad("Du kannst dich nicht selbst löschen.") }
            try await store.deleteUser(id: id)
            keys.delete(id)
            try await store.purgeOrphanFiles()
            return HTTP.ok()
        }

        api.get("admin/catalog") { [self] request, context in
            _ = try await admin(request, context)
            let models = await catalog.all()
            return HTTP.json(models.map { m -> [String: Any] in
                ["id": m.id, "name": m.name, "in": m.inputModalities, "out": m.outputModalities, "tools": m.supportsTools,
                 "prompt": m.promptPrice as Any, "completion": m.completionPrice as Any, "context": m.contextLength as Any,
                 "voices": m.voices]
            })
        }

        api.get("admin/budgets") { [self] request, context in
            _ = try await admin(request, context)
            var out: [[String: Any]] = []
            for u in try await store.users() {
                var d: [String: Any] = ["userId": u.id, "displayName": u.displayName, "hasKey": keys.get(u.id) != nil]
                if let st = await budget.refresh(userId: u.id) {
                    d["limit"] = st.limit as Any; d["remaining"] = st.remaining as Any
                    d["usage"] = st.usage as Any; d["reset"] = st.reset as Any
                }
                out.append(d)
            }
            return HTTP.json(out)
        }

        api.post("admin/test-mail") { [self] request, context in
            _ = try await admin(request, context)
            let s = try await store.settings()
            let failure = await Mailer.send(s.mailAccount(keys: keys), sender: s.mailFrom,
                                            recipient: s.mailRecipient, subject: "\(s.aiName): Testmail",
                                            body: "Diese Testmail bestätigt, dass Budget-Benachrichtigungen ankommen.")
            return HTTP.json(failure.map { ["ok": false, "error": $0] } ?? ["ok": true])
        }
    }

    // MARK: Runner

    func registerRunner(_ api: RouterGroup<FamilyContext>) {
        api.get("devices") { [self] request, _ in
            let s = try await session(request)
            guard s.user.profile.code else { return HTTP.json([Any]()) }
            var out: [[String: Any]] = []
            for d in try await store.devices(userId: s.user.id) {
                var o = HTTP.toJSON(d) as? [String: Any] ?? [:]
                o["online"] = await runner.isOnline(d.id)
                out.append(o)
            }
            return HTTP.json(out)
        }
        api.post("devices") { [self] request, _ in
            let s = try await session(request)
            guard s.user.profile.code else { throw APIError.forbidden }
            let o = try await HTTP.object(request)
            let name = ((o["name"] as? String) ?? "Computer").trimmingCharacters(in: .whitespaces)
            let token = "fai_dev_" + Auth.randomToken()
            let d = try await store.addDevice(userId: s.user.id, name: String(name.prefix(60)), tokenHash: Auth.sha256(token))
            return HTTP.json(["device": HTTP.toJSON(d), "token": token])
        }
        // Open approval questions of the person's computers (every window shows them, see approvalCard in app.js).
        api.get("approvals") { [self] request, _ in
            let s = try await session(request)
            var out: [[String: Any]] = []
            for (deviceId, job) in await runner.openApprovals() {
                guard let dev = try await store.device(id: deviceId), dev.userId == s.user.id else { continue }
                let d = RunnerHub.describe(job)
                out.append(["id": job.id, "tool": job.tool, "title": d.title, "text": d.text])
            }
            return HTTP.json(out)
        }
        // Answer from the chat to a runner's approval question (only the owner of the computer).
        api.post("approvals/:id") { [self] request, context in
            let s = try await session(request)
            let id: String = try context.parameters.require("id")
            let o = try await HTTP.object(request)
            guard let allow = o["allow"] as? Bool else { throw APIError.bad("allow fehlt") }
            guard let did = await runner.deviceId(forJob: id), let dev = try await store.device(id: did), dev.userId == s.user.id,
                  await runner.decide(jobId: id, allow: allow) else { throw APIError.notFound }
            return HTTP.ok()
        }
        api.delete("devices/:id") { [self] request, context in
            let s = try await session(request)
            try await store.deleteDevice(id: try context.parameters.require("id"), userId: s.user.id)
            return HTTP.ok()
        }

        api.get("runner/poll") { [self] request, _ in
            let dev = try await device(request)
            let q = request.uri.queryParameters
            try await store.touchDevice(id: dev.id, workspace: q.get("workspace"), platform: q.get("platform"))
            guard let job = await runner.poll(deviceId: dev.id) else { return Response(status: .noContent) }
            return HTTP.encodable(job)
        }
        // Side-effect-free check for the runner apps' "test connection" button (address + key valid).
        api.get("runner/ping") { [self] request, _ in
            _ = try await device(request)
            return HTTP.ok()
        }
        api.post("runner/bye") { [self] request, _ in
            let dev = try await device(request)
            await runner.goOffline(deviceId: dev.id)
            return HTTP.ok()
        }
        api.post("runner/ask") { [self] request, _ in
            let dev = try await device(request)
            let o = try await HTTP.object(request)
            guard let jobId = o["jobId"] as? String else { throw APIError.bad("jobId fehlt") }
            return HTTP.json(["state": await runner.ask(deviceId: dev.id, jobId: jobId)])
        }
        api.post("runner/result") { [self] request, _ in
            let dev = try await device(request)
            let o = try await HTTP.object(request)
            guard let jobId = o["jobId"] as? String else { throw APIError.bad("jobId fehlt") }
            let ok = await runner.complete(deviceId: dev.id, jobId: jobId,
                                           result: .init(ok: (o["ok"] as? Bool) ?? false, output: (o["output"] as? String) ?? ""))
            return HTTP.json(["accepted": ok])
        }
    }

    func device(_ request: Request) async throws -> Store.Device {
        guard let auth = request.headers[.authorization], auth.hasPrefix("Bearer ") else { throw APIError.unauthorized }
        let token = String(auth.dropFirst(7))
        guard let d = try await store.device(tokenHash: Auth.sha256(token)),
              let u = try await store.user(id: d.userId), !u.disabled, u.profile.code else { throw APIError.unauthorized }
        return d
    }
}

// MARK: - Middleware

struct SecurityMiddleware: RouterMiddleware {
    typealias Context = FamilyContext
    func handle(_ request: Request, context: FamilyContext, next: (Request, FamilyContext) async throws -> Response) async throws -> Response {
        // CSRF: state-changing API calls from browsers must carry the X-Family-AI header
        // (cannot be set cross-site without CORS, which we never allow).
        if request.uri.path.hasPrefix("/api/"), request.method != .get, request.method != .head,
           !request.uri.path.hasPrefix("/api/runner/"),
           request.headers[HTTPField.Name("X-Family-AI")!] != "1" {
            return HTTP.json(["error": "CSRF-Schutz: Header fehlt"], status: .forbidden)
        }
        var response = try await next(request, context)
        response.headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        response.headers[HTTPField.Name("X-Frame-Options")!] = "DENY"
        response.headers[HTTPField.Name("Referrer-Policy")!] = "same-origin"
        response.headers[HTTPField.Name("Permissions-Policy")!] = "camera=(), geolocation=(), microphone=(self)"
        response.headers[HTTPField.Name("Content-Security-Policy")!] =
            "default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        return response
    }
}

struct ErrorMiddleware: RouterMiddleware {
    typealias Context = FamilyContext
    func handle(_ request: Request, context: FamilyContext, next: (Request, FamilyContext) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let e as APIError {
            return HTTP.json(["error": e.message], status: e.status)
        } catch let e as OpenRouterError {
            return HTTP.json(["error": e.description], status: .badGateway)
        } catch let e as HTTPError {
            return HTTP.json(["error": "\(e.status.reasonPhrase)"], status: e.status)
        } catch {
            return HTTP.json(["error": "\(error)"], status: .internalServerError)
        }
    }
}

/// Chats whose answer is being generated right now. The answer runs detached on the server, so a window that left the
/// chat (or a second window) asks this to show "still working" instead of an apparently idle chat.
actor RunningChats {
    private var counts: [String: Int] = [:]
    func begin(_ id: String) { counts[id, default: 0] += 1 }
    func end(_ id: String) {
        let n = (counts[id] ?? 1) - 1
        if n <= 0 { counts.removeValue(forKey: id) } else { counts[id] = n }
    }
    func contains(_ id: String) -> Bool { counts[id] != nil }
}
