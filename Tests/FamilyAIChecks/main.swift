import Foundation

// Self-contained checks (XCTest and Swift Testing macros are unavailable with the
// Command Line Tools). Run: swift run FamilyAIChecks
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
func check(_ ok: Bool, _ msg: String = "", line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FEHLER Zeile \(line): \(msg)") }
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", line: Int = #line) { check(a == b, "\(a) != \(b) \(msg)", line: line) }
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, line: Int = #line) { check(a != b, "\(a) == \(b)", line: line) }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, line: Int = #line) { check(a > b, "\(a) <= \(b)", line: line) }
func XCTAssertNil<T>(_ a: T?, line: Int = #line) { check(a == nil, "nicht nil", line: line) }
func XCTAssertNotNil<T>(_ a: T?, line: Int = #line) { check(a != nil, "nil", line: line) }
@testable import FamilyAICore

struct FamilyAICoreTests {
    static func runAll() async {
        let t = FamilyAICoreTests()
        t.testChunking(); t.testCosine(); t.testPrivateAddresses(); t.testPasswords(); t.testSpeakable(); t.testUsernames(); t.testDataURL()
        t.testMailCurlConfig(); t.testStarterCatalog()
        do { try await t.testStoreRoundtrip() } catch { check(false, "Store: \(error)") }
        await t.testRunnerHubRoundtrip()
        print("\(checks) Prüfungen, \(failures) Fehler")
        exit(failures == 0 ? 0 : 1)
    }

    func testChunking() {
        let text = (0..<200).map { "Satz Nummer \($0) mit etwas Inhalt." }.joined(separator: " ")
        let chunks = Documents.chunk(text, size: 500, overlap: 50)
        XCTAssertGreaterThan(chunks.count, 5)
        check(chunks.allSatisfy { $0.count <= 520 })
        XCTAssertEqual(Documents.chunk("kurz"), ["kurz"])
        XCTAssertEqual(Documents.chunk(""), [])
    }

    func testCosine() {
        check(abs(Documents.cosine([1, 0], [1, 0]) - 1) < 1e-6)
        check(abs(Documents.cosine([1, 0], [0, 1])) < 1e-6)
        XCTAssertEqual(Documents.cosine([1], [1, 2]), -1)
    }

    func testPrivateAddresses() {
        for ip in ["192.168.1.10", "10.1.2.3", "172.20.0.1", "127.0.0.1", "100.100.1.1", "::1", "fd00::1"] {
            check(Net.isPrivate(ip))
        }
        for ip in ["8.8.8.8", "172.32.0.1", "2a00:1450::1", ""] {
            check(!(Net.isPrivate(ip)))
        }
    }

    func testPasswords() {
        let hash = Auth.hashPassword("geheim123")
        check(Auth.verifyPassword("geheim123", hash: hash))
        check(!(Auth.verifyPassword("falsch", hash: hash)))
        check(!(Auth.verifyPassword("x", hash: "")))
        XCTAssertNotNil(Auth.passwordProblem("kurz"))
        XCTAssertNil(Auth.passwordProblem("lang genug"))
        XCTAssertNotEqual(Auth.randomToken(), Auth.randomToken())
    }

    func testSpeakable() {
        XCTAssertEqual(FamilyServer.speakable("**Hallo** [Welt](https://x.de)\n```\ncode\n```"), "Hallo Welt")
    }

    func testUsernames() {
        check(FamilyServer.validUsername("max.m"))
        check(!(FamilyServer.validUsername("a")))
        check(!(FamilyServer.validUsername("max m")))
    }

    func testStoreRoundtrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("family-ai-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await Store(dataDir: dir)
        var profile = Profile.defaults(for: .child)
        profile.parentalView = true
        let u = try await store.createUser(username: "Kind", displayName: "Kind", role: .child, passwordHash: "h", profile: profile)
        XCTAssertEqual(try await store.userWithHash(username: "kind")?.0.id, u.id, "usernames are case-insensitive")
        let chat = try await store.createChat(userId: u.id, title: "T", model: "m", mode: "chat", deviceId: nil)
        try await store.addMessage(Message(id: newID(), chatId: chat.id, role: "user", content: "Hallo Welt",
                                           attachments: [], meta: MessageMeta(), createdAt: now()))
        XCTAssertEqual(try await store.messages(chatId: chat.id).count, 1)
        XCTAssertEqual(try await store.chats(userId: u.id, search: "Welt").count, 1)
        XCTAssertEqual(try await store.chats(userId: u.id, search: "nichts").count, 0)
        let m = try await store.addMemory(userId: u.id, content: "mag Fahrräder")
        XCTAssertEqual(try await store.memories(userId: u.id).first?.id, m.id)
        try await store.deleteUser(id: u.id)
        XCTAssertEqual(try await store.chats(userId: u.id).count, 0, "cascade delete")
        var s = try await store.settings()
        s.aiName = "Nova"
        try await store.saveSettings(s)
        XCTAssertEqual(try await store.settings().aiName, "Nova")
    }

    func testRunnerHubRoundtrip() async {
        let hub = RunnerHub()
        async let result = hub.execute(deviceId: "d1", tool: "read_file", args: ["path": "a.txt"], chatTitle: nil, timeout: 5)
        let job = await hub.poll(deviceId: "d1", timeout: 5)
        XCTAssertEqual(job?.tool, "read_file")
        let accepted = await hub.complete(deviceId: "d1", jobId: job!.id, result: .init(ok: true, output: "inhalt"))
        check(accepted)
        let r = await result
        XCTAssertEqual(r.output, "inhalt")
        let foreign = await hub.complete(deviceId: "d2", jobId: "x", result: .init(ok: true, output: ""))
        check(!(foreign))
    }

    func testMailCurlConfig() {
        let plain = Mailer.curlConfig(.init(host: "relay.local", port: 25), sender: "a@x", recipient: "b@y", messageFile: "/tmp/m")
        check(plain.contains("url = \"smtp://relay.local:25\""), "plain url")
        check(!plain.contains("ssl-reqd") && !plain.contains("user ="), "plain has no TLS/auth")
        let start = Mailer.curlConfig(.init(host: "mail.x", port: 587, security: .starttls, user: "u", password: #"p"a\b"#),
                                      sender: "a@x", recipient: "b@y", messageFile: "/tmp/m")
        check(start.contains("ssl-reqd"), "starttls requires TLS")
        check(start.contains(#"user = "u:p\"a\\b""#), "password quoted for curl config")
        let tls = Mailer.curlConfig(.init(host: "mail.x", port: 465, security: .tls), sender: "a@x", recipient: "b@y", messageFile: "/tmp/m")
        check(tls.contains("smtps://mail.x:465"), "implicit TLS uses smtps")
        let msg = Mailer.message(sender: "a@x", recipient: "b@y", subject: "Grüße", body: "Zeile 1\nZeile 2")
        check(msg.contains("Subject: =?UTF-8?B?"), "encoded subject")
        check(msg.contains("Zeile 1\r\nZeile 2\r\n"), "CRLF body")
    }

    func testStarterCatalog() {
        let s = GlobalSettings()
        check(s.catalog == GlobalSettings.starterCatalog && s.catalog.count == 4, "starter catalog")
        check(s.catalog.contains(s.defaultModel), "default model is in catalog")
        // Older settings without the new keys decode with the defaults.
        let old = try! JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"aiName":"Nova","catalog":[]}"#.utf8))
        check(old.catalog.isEmpty && old.smtpSecurity == "none", "explicit empty catalog stays empty")
    }

    func testDataURL() {
        let (d, mime) = ChatEngine.decodeDataURL("data:image/png;base64,aGFsbG8=")!
        XCTAssertEqual(String(data: d, encoding: .utf8), "hallo")
        XCTAssertEqual(mime, "image/png")
    }
}


await FamilyAICoreTests.runAll()
