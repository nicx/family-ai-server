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
        t.testMailCurlConfig(); t.testSettingsDefaults(); t.testPrivacy(); t.testDocuments(); t.testEncryptedKeyStore(); t.testTrustedProxies(); t.testSetupCode()
        do { try await t.testStoreRoundtrip() } catch { check(false, "Store: \(error)") }
        await t.testRunnerHubRoundtrip()
        await t.testStreaming()
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

    func testPrivacy() {
        check(ChatEngine.firstName("Hanna Mustermann") == "Hanna", "first name only")
        check(ChatEngine.firstName("  Max   von Beispiel ") == "Max", "first name ignores extra spaces")
        check(ChatEngine.firstName("Timo") == "Timo" && ChatEngine.firstName("") == "", "single / empty name")
        let id = "7C1F2D9A-1111-2222-3333-444455556666"
        let p = ChatEngine.pseudonym(id)
        check(p == ChatEngine.pseudonym(id) && p != ChatEngine.pseudonym(id + "x"), "pseudonym stable and distinct")
        check(p.hasPrefix("u_") && p.count == 18 && !p.contains("7C1F") && !p.lowercased().contains("7c1f2d9a"), "pseudonym hides the id")
    }

    func testDocuments() {
        let xml = "<w:document><w:body><w:p><w:r><w:t>Hallo &amp; Welt</w:t></w:r></w:p><w:p><w:r><w:t>Zeile</w:t></w:r><w:tab/><w:r><w:t>zwei</w:t></w:r></w:p></w:body></w:document>"
        check(Documents.xmlText(xml) == "Hallo & Welt\nZeile\tzwei", "xmlText: paragraphs, tabs and entities")
        check(Documents.xmlText("<text:p>Eins</text:p><text:p>a<text:s/>b</text:p>") == "Eins\na b", "xmlText: OpenDocument")
        check(Documents.extractText(data: Data("Notiz".utf8), name: "n.txt", mime: "text/plain") == "Notiz", "plain text passes through")
        // Minimal hand-written PDF (viewers rebuild the missing xref table).
        let pdf = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
            + "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n"
            + "4 0 obj<</Length 44>>stream\nBT /F1 12 Tf 20 50 Td (Hallo PDF) Tj ET\nendstream endobj\n"
            + "5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\ntrailer<</Root 1 0 R/Size 6>>\n%%EOF\n"
        let pdfText = Documents.extractText(data: Data(pdf.utf8), name: "a.pdf", mime: "application/pdf") ?? ""
        check(pdfText.contains("Hallo PDF"), "PDF text extracted: \(pdfText)")
        // DOCX = ZIP with word/document.xml (built with the system zip tool).
        if let zip = ExternalTool.find("zip") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("family-ai-docx-\(newID())")
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent("word"), withIntermediateDirectories: true)
            try? Data(xml.utf8).write(to: dir.appendingPathComponent("word/document.xml"))
            let out = dir.appendingPathComponent("t.docx")
            let z = Process(); z.executableURL = URL(fileURLWithPath: zip); z.currentDirectoryURL = dir
            z.arguments = ["-q", "-r", out.path, "word"]; z.standardOutput = FileHandle.nullDevice
            if (try? z.run()) != nil { z.waitUntilExit() }
            if let d = try? Data(contentsOf: out) {
                let t = Documents.extractText(data: d, name: "t.docx", mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document") ?? ""
                check(t.contains("Hallo & Welt"), "DOCX text extracted: \(t)")
            }
            try? FileManager.default.removeItem(at: dir)
        }
        check(Documents.extractText(data: Data(), name: "x.bin", mime: "application/octet-stream") == nil, "unknown type rejected")
    }

    /// Streams from a tiny local fake of the OpenRouter SSE endpoint (python3), on macOS and Linux alike.
    func testStreaming() async {
        guard let py = ExternalTool.find("python3") else { print("python3 fehlt – Streaming-Prüfung übersprungen"); return }
        let script = """
        import http.server, json, time
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0)); self.rfile.read(n)
                if self.headers.get('Authorization') == 'Bearer bad':
                    b = json.dumps({"error": {"message": "kaputt"}}).encode()
                    self.send_response(401); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b); return
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
                for t in ["Hal", "lo ", "Welt"]:
                    self.wfile.write(('data: ' + json.dumps({"choices": [{"delta": {"content": t}}]}) + '\\r\\n\\r\\n').encode()); self.wfile.flush(); time.sleep(0.05)
                self.wfile.write(('data: ' + json.dumps({"choices": [{"delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 3, "completion_tokens": 4}}) + '\\n\\n').encode())
                self.wfile.write(b'data: [DONE]\\n\\n'); self.wfile.flush()
        http.server.ThreadingHTTPServer(('127.0.0.1', 18391), H).serve_forever()
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { check(false, "Fake-Server startet nicht"); return }
        defer { p.terminate() }
        try? await Task.sleep(nanoseconds: 800_000_000)
        let or = OpenRouter(baseURL: URL(string: "http://127.0.0.1:18391/api/v1")!)
        var text = "", finish: String?, usage: Usage?
        do {
            for try await ev in or.streamChat(key: "good", body: ["model": "x", "messages": []]) {
                switch ev {
                case .text(let t): text += t
                case .finished(_, let f, let u): finish = f; usage = u
                default: break
                }
            }
        } catch { check(false, "Streaming: \(error)") }
        XCTAssertEqual(text, "Hallo Welt", "SSE text assembled")
        XCTAssertEqual(finish ?? "", "stop")
        XCTAssertEqual(usage?.completionTokens ?? 0, 4)
        do {
            for try await _ in or.streamChat(key: "bad", body: ["model": "x", "messages": []]) {}
            check(false, "Fehlerstatus muss werfen")
        } catch let e as OpenRouterError {
            check(e.status == 401 && e.message.contains("kaputt"), "error status and message: \(e.status) \(e.message)")
        } catch { check(false, "falscher Fehlertyp: \(error)") }
    }

    func testEncryptedKeyStore() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("family-ai-ks-\(newID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("keys.enc")
        let master = "ein-ausreichend-langer-master-key-123"
        guard let ks = try? EncryptedKeyStore(url: url, masterKey: master) else { check(false, "init"); return }
        check(ks.get("u1") == nil && !ks.isLocked, "empty store is not locked")
        check(ks.set("sk-or-geheim-1", for: "u1") && ks.set("sk-or-geheim-2", for: "u2"), "set")
        check(ks.get("u1") == "sk-or-geheim-1" && ks.get("u2") == "sk-or-geheim-2", "roundtrip")
        let raw = (try? Data(contentsOf: url)) ?? Data()
        check(!raw.isEmpty && String(decoding: raw, as: UTF8.self).range(of: "geheim") == nil, "file holds no plaintext")
        check(((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) == 0o600, "mode 0600")
        // A new instance with the same master key reads it.
        let again = try? EncryptedKeyStore(url: url, masterKey: master)
        check(again?.get("u2") == "sk-or-geheim-2", "persisted")
        // Wrong master key: locked, no reads, and the file stays untouched.
        let wrong = try? EncryptedKeyStore(url: url, masterKey: "ein-ganz-anderer-master-key-456")
        check(wrong?.isLocked == true && wrong?.get("u1") == nil, "wrong key is locked")
        check(wrong?.set("x", for: "u3") == false && wrong?.delete("u1") == false, "locked store refuses writes")
        check((try? Data(contentsOf: url)) == raw, "file untouched by the wrong key")
        check(again?.get("u1") == "sk-or-geheim-1", "right key still works afterwards")
        check(ks.delete("u1") && ks.get("u1") == nil && ks.get("u2") == "sk-or-geheim-2", "delete")
        check(ks.set("", for: "u2") && ks.get("u2") == nil, "empty value deletes")
        // Tampering is detected.
        var bad = (try? Data(contentsOf: url)) ?? Data()
        if !bad.isEmpty { bad[bad.count - 1] ^= 0xFF; try? bad.write(to: url) }
        check((try? EncryptedKeyStore(url: url, masterKey: master))?.isLocked == true, "tampered file is rejected")
        // Master key rules.
        check((try? EncryptedKeyStore(url: url, masterKey: "kurz")) == nil, "short master key rejected")
        let keyFile = dir.appendingPathComponent("master")
        try? "  \(master)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        check(EncryptedKeyStore.masterKey(environment: ["FAMILY_AI_MASTER_KEY_FILE": keyFile.path]) == master, "master key from secret file")
        check(EncryptedKeyStore.masterKey(environment: ["FAMILY_AI_MASTER_KEY": master]) == master, "master key from environment")
        check(EncryptedKeyStore.masterKey(environment: [:]) == nil, "no master key")
    }

    func testTrustedProxies() {
        let net = IPRange.list("172.29.0.0/16, 10.9.8.7 fd12::/16")!
        check(net.count == 3 && IPRange.list("172.29.0.0/99") == nil && IPRange.list("kein-ip") == nil, "list parsing")
        check(net[0].contains("172.29.5.9") && net[0].contains("::ffff:172.29.0.2") && !net[0].contains("172.30.0.1"), "CIDR /16")
        check(net[1].contains("10.9.8.7") && !net[1].contains("10.9.8.8"), "single address")
        check(net[2].contains("fd12:aaaa::1") && !net[2].contains("fd13::1") && !net[2].contains("172.29.0.1"), "IPv6 and family mismatch")
        check(IPRange("10.0.0.0/13")!.contains("10.7.255.255") && !IPRange("10.0.0.0/13")!.contains("10.8.0.0"), "non-byte prefix")
        // Without trusted proxies only the local machine counts (as before).
        check(Net.clientIP(peer: "203.0.113.5", forwardedFor: "10.0.0.1", trusted: []) == "203.0.113.5", "direct client cannot spoof")
        check(Net.clientIP(peer: "127.0.0.1", forwardedFor: "198.51.100.4", trusted: []) == "198.51.100.4", "local proxy still trusted")
        // Docker: the proxy container is in the trusted range, the client's address comes from the header.
        check(Net.clientIP(peer: "172.29.0.2", forwardedFor: "198.51.100.4", trusted: net) == "198.51.100.4", "proxy container trusted")
        check(Net.clientIP(peer: "172.29.0.2", forwardedFor: "198.51.100.4", trusted: []) == "172.29.0.2", "proxy not trusted without the setting")
        check(Net.clientIP(peer: "172.29.0.2", forwardedFor: "10.0.0.5, 198.51.100.4", trusted: net) == "198.51.100.4", "spoofed left entries ignored")
        check(Net.clientIP(peer: "172.29.0.2", forwardedFor: "198.51.100.4, 172.29.0.7", trusted: net) == "198.51.100.4", "chain of proxies")
        check(Net.clientIP(peer: "172.29.0.2", forwardedFor: nil, trusted: net) == "172.29.0.2", "no header")
        check(!Net.isPrivate(Net.clientIP(peer: "172.29.0.2", forwardedFor: "198.51.100.4", trusted: net)), "outside client is not private")
    }

    func testSetupCode() {
        let c = Auth.newSetupCode()
        check(c.count == 9 && c.dropFirst(4).first == "-" && c != Auth.newSetupCode(), "format and randomness: \(c)")
        check(Auth.setupCodeMatches(c, c) && Auth.setupCodeMatches(c.lowercased().replacingOccurrences(of: "-", with: " "), c), "case and separator insensitive")
        check(!Auth.setupCodeMatches("AAAA-AAAA", "AAAA-AAAB") && !Auth.setupCodeMatches("", c) && !Auth.setupCodeMatches(c + "X", c), "mismatches")
    }

    func testSettingsDefaults() {
        let s = GlobalSettings()
        check(!s.defaultModel.isEmpty && !s.escalationModel.isEmpty, "default and escalation model set")
        // Defaults must work with "no retention" (ZDR): Gemini image/embedding models are rejected by it.
        check(s.imageModel == "microsoft/mai-image-2.7-flash" && s.embedModel == "openai/text-embedding-3-large"
              && s.ttsModel == "microsoft/mai-voice-2.1-flash" && s.sttModel == "openai/whisper-large-v3-turbo", "ZDR-capable default models")
        // Older settings (incl. the removed "catalog" key) decode with the defaults.
        let old = try! JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"aiName":"Nova","catalog":[]}"#.utf8))
        check(old.aiName == "Nova" && old.smtpSecurity == "none" && old.defaultModel == s.defaultModel, "old settings decode")
    }

    func testDataURL() {
        let (d, mime) = ChatEngine.decodeDataURL("data:image/png;base64,aGFsbG8=")!
        XCTAssertEqual(String(data: d, encoding: .utf8), "hallo")
        XCTAssertEqual(mime, "image/png")
    }
}


await FamilyAICoreTests.runAll()
