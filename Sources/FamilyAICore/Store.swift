import Foundation

/// Data access layer on top of `Database`. All persistent state of Family AI Server lives here.
public final class Store: Sendable {
    public let db: Database
    public let filesDir: URL

    public init(dataDir: URL) async throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        filesDir = dataDir.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        db = try Database(path: dataDir.appendingPathComponent("family-ai.sqlite").path)
        try await migrate()
    }

    // MARK: - Schema

    private func migrate() async throws {
        try await db.executeScript("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            username TEXT NOT NULL UNIQUE COLLATE NOCASE,
            display_name TEXT NOT NULL,
            role TEXT NOT NULL,
            password_hash TEXT NOT NULL,
            profile TEXT NOT NULL DEFAULT '{}',
            disabled INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            token_hash TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            last_seen REAL NOT NULL,
            user_agent TEXT
        );
        CREATE TABLE IF NOT EXISTS chats (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            model TEXT NOT NULL,
            mode TEXT NOT NULL DEFAULT 'chat',
            device_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS chats_user ON chats(user_id, updated_at);
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            attachments TEXT NOT NULL DEFAULT '[]',
            meta TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS messages_chat ON messages(chat_id, created_at);
        CREATE TABLE IF NOT EXISTS files (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            mime TEXT NOT NULL,
            size INTEGER NOT NULL,
            kind TEXT NOT NULL,
            text TEXT,
            indexed INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chunks (
            id TEXT PRIMARY KEY,
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            user_id TEXT NOT NULL,
            idx INTEGER NOT NULL,
            text TEXT NOT NULL,
            embedding BLOB
        );
        CREATE INDEX IF NOT EXISTS chunks_user ON chunks(user_id);
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            content TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS passkeys (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            public_key BLOB NOT NULL,
            sign_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS devices (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            workspace TEXT,
            platform TEXT,
            created_at REAL NOT NULL,
            last_seen REAL
        );
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
        try await db.execute("INSERT OR IGNORE INTO meta(key, value) VALUES('schema', '1')")
    }

    // MARK: - Settings

    public func settings() async throws -> GlobalSettings {
        let row = try await db.queryOne("SELECT value FROM settings WHERE key='global'")
        return decodeJSON(GlobalSettings.self, row?["value"]?.string) ?? GlobalSettings()
    }

    public func saveSettings(_ s: GlobalSettings) async throws {
        try await db.execute("INSERT INTO settings(key,value) VALUES('global',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                             [.text(encodeJSON(s))])
    }

    public func meta(_ key: String) async throws -> String? {
        try await db.queryOne("SELECT value FROM meta WHERE key=?", [.text(key)])?["value"]?.string
    }

    public func setMeta(_ key: String, _ value: String) async throws {
        try await db.execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                             [.text(key), .text(value)])
    }

    // MARK: - Users

    static func user(_ r: Row) -> User {
        User(id: r["id"]?.string ?? "",
             username: r["username"]?.string ?? "",
             displayName: r["display_name"]?.string ?? "",
             role: Role(rawValue: r["role"]?.string ?? "") ?? .child,
             profile: decodeJSON(Profile.self, r["profile"]?.string) ?? Profile(),
             createdAt: r["created_at"]?.double ?? 0,
             disabled: r["disabled"]?.bool ?? false)
    }

    public func userCount() async throws -> Int {
        Int(try await db.queryOne("SELECT COUNT(*) AS n FROM users")?["n"]?.int ?? 0)
    }

    public func users() async throws -> [User] {
        try await db.query("SELECT * FROM users ORDER BY created_at").map(Store.user)
    }

    public func user(id: String) async throws -> User? {
        try await db.queryOne("SELECT * FROM users WHERE id=?", [.text(id)]).map(Store.user)
    }

    public func userWithHash(username: String) async throws -> (User, String)? {
        guard let r = try await db.queryOne("SELECT * FROM users WHERE username=?", [.text(username)]) else { return nil }
        return (Store.user(r), r["password_hash"]?.string ?? "")
    }

    public func createUser(username: String, displayName: String, role: Role, passwordHash: String, profile: Profile) async throws -> User {
        let u = User(id: newID(), username: username, displayName: displayName, role: role,
                     profile: profile, createdAt: now(), disabled: false)
        try await db.execute("INSERT INTO users(id,username,display_name,role,password_hash,profile,created_at) VALUES(?,?,?,?,?,?,?)",
                             [.text(u.id), .text(username), .text(displayName), .text(role.rawValue),
                              .text(passwordHash), .text(encodeJSON(profile)), .double(u.createdAt)])
        return u
    }

    public func updateUser(_ u: User) async throws {
        try await db.execute("UPDATE users SET username=?, display_name=?, role=?, profile=?, disabled=? WHERE id=?",
                             [.text(u.username), .text(u.displayName), .text(u.role.rawValue),
                              .text(encodeJSON(u.profile)), .of(u.disabled), .text(u.id)])
    }

    public func setPassword(userId: String, hash: String) async throws {
        try await db.execute("UPDATE users SET password_hash=? WHERE id=?", [.text(hash), .text(userId)])
    }

    public func deleteUser(id: String) async throws {
        try await db.execute("DELETE FROM users WHERE id=?", [.text(id)])
    }

    // MARK: - Sessions

    public func createSession(tokenHash: String, userId: String, ttl: Double, userAgent: String?) async throws {
        let t = now()
        try await db.execute("INSERT INTO sessions(token_hash,user_id,created_at,expires_at,last_seen,user_agent) VALUES(?,?,?,?,?,?)",
                             [.text(tokenHash), .text(userId), .double(t), .double(t + ttl), .double(t), .of(userAgent)])
    }

    public func session(tokenHash: String) async throws -> (userId: String, expires: Double, lastSeen: Double)? {
        guard let r = try await db.queryOne("SELECT user_id, expires_at, last_seen FROM sessions WHERE token_hash=?", [.text(tokenHash)]) else { return nil }
        return (r["user_id"]?.string ?? "", r["expires_at"]?.double ?? 0, r["last_seen"]?.double ?? 0)
    }

    public func touchSession(tokenHash: String, ttl: Double) async throws {
        let t = now()
        try await db.execute("UPDATE sessions SET last_seen=?, expires_at=? WHERE token_hash=?",
                             [.double(t), .double(t + ttl), .text(tokenHash)])
    }

    public func deleteSession(tokenHash: String) async throws {
        try await db.execute("DELETE FROM sessions WHERE token_hash=?", [.text(tokenHash)])
    }

    public func deleteSessions(userId: String) async throws {
        try await db.execute("DELETE FROM sessions WHERE user_id=?", [.text(userId)])
    }

    public func purgeExpiredSessions() async throws {
        try await db.execute("DELETE FROM sessions WHERE expires_at < ?", [.double(now())])
    }

    // MARK: - Chats & messages

    static func chat(_ r: Row) -> Chat {
        Chat(id: r["id"]?.string ?? "", userId: r["user_id"]?.string ?? "",
             title: r["title"]?.string ?? "", model: r["model"]?.string ?? "",
             mode: r["mode"]?.string ?? "chat", deviceId: r["device_id"]?.string,
             createdAt: r["created_at"]?.double ?? 0, updatedAt: r["updated_at"]?.double ?? 0)
    }

    static func message(_ r: Row) -> Message {
        Message(id: r["id"]?.string ?? "", chatId: r["chat_id"]?.string ?? "",
                role: r["role"]?.string ?? "", content: r["content"]?.string ?? "",
                attachments: decodeJSON([Attachment].self, r["attachments"]?.string) ?? [],
                meta: decodeJSON(MessageMeta.self, r["meta"]?.string) ?? MessageMeta(),
                createdAt: r["created_at"]?.double ?? 0)
    }

    public func chats(userId: String, search: String? = nil) async throws -> [Chat] {
        if let search, !search.isEmpty {
            let like = "%\(search)%"
            return try await db.query("""
                SELECT DISTINCT c.* FROM chats c LEFT JOIN messages m ON m.chat_id = c.id
                WHERE c.user_id=? AND (c.title LIKE ? OR m.content LIKE ?)
                ORDER BY c.updated_at DESC LIMIT 200
                """, [.text(userId), .text(like), .text(like)]).map(Store.chat)
        }
        return try await db.query("SELECT * FROM chats WHERE user_id=? ORDER BY updated_at DESC LIMIT 500",
                                  [.text(userId)]).map(Store.chat)
    }

    public func chat(id: String) async throws -> Chat? {
        try await db.queryOne("SELECT * FROM chats WHERE id=?", [.text(id)]).map(Store.chat)
    }

    public func createChat(userId: String, title: String, model: String, mode: String, deviceId: String?) async throws -> Chat {
        let t = now()
        let c = Chat(id: newID(), userId: userId, title: title, model: model, mode: mode, deviceId: deviceId, createdAt: t, updatedAt: t)
        try await db.execute("INSERT INTO chats(id,user_id,title,model,mode,device_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                             [.text(c.id), .text(userId), .text(title), .text(model), .text(mode), .of(deviceId), .double(t), .double(t)])
        return c
    }

    public func updateChat(_ c: Chat) async throws {
        try await db.execute("UPDATE chats SET title=?, model=?, mode=?, device_id=?, updated_at=? WHERE id=?",
                             [.text(c.title), .text(c.model), .text(c.mode), .of(c.deviceId), .double(c.updatedAt), .text(c.id)])
    }

    public func deleteChat(id: String) async throws {
        try await db.execute("DELETE FROM chats WHERE id=?", [.text(id)])
    }

    public func messages(chatId: String) async throws -> [Message] {
        try await db.query("SELECT * FROM messages WHERE chat_id=? ORDER BY created_at", [.text(chatId)]).map(Store.message)
    }

    public func addMessage(_ m: Message) async throws {
        try await db.transaction([
            ("INSERT INTO messages(id,chat_id,role,content,attachments,meta,created_at) VALUES(?,?,?,?,?,?,?)",
             [.text(m.id), .text(m.chatId), .text(m.role), .text(m.content),
              .text(encodeJSON(m.attachments)), .text(encodeJSON(m.meta)), .double(m.createdAt)]),
            ("UPDATE chats SET updated_at=? WHERE id=?", [.double(m.createdAt), .text(m.chatId)]),
        ])
    }

    public func deleteMessages(chatId: String, after createdAt: Double) async throws {
        try await db.execute("DELETE FROM messages WHERE chat_id=? AND created_at >= ?", [.text(chatId), .double(createdAt)])
    }

    /// Deletes chats not updated for `days` days. Returns number of deleted chats.
    public func purgeOldChats(days: Int) async throws -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now() - Double(days) * 86400
        return try await db.execute("DELETE FROM chats WHERE updated_at < ?", [.double(cutoff)])
    }

    // MARK: - Files

    public struct FileRecord: Sendable, Codable {
        public var id: String
        public var userId: String
        public var name: String
        public var mime: String
        public var size: Int
        public var kind: String
        public var indexed: Bool
        public var createdAt: Double
    }

    static func file(_ r: Row) -> FileRecord {
        FileRecord(id: r["id"]?.string ?? "", userId: r["user_id"]?.string ?? "",
                   name: r["name"]?.string ?? "", mime: r["mime"]?.string ?? "",
                   size: Int(r["size"]?.int ?? 0), kind: r["kind"]?.string ?? "",
                   indexed: r["indexed"]?.bool ?? false, createdAt: r["created_at"]?.double ?? 0)
    }

    public func filePath(id: String) -> URL { filesDir.appendingPathComponent(id) }

    public func saveFile(userId: String, name: String, mime: String, kind: String, data: Data, text: String? = nil) async throws -> FileRecord {
        let id = newID()
        try data.write(to: filePath(id: id), options: .atomic)
        let rec = FileRecord(id: id, userId: userId, name: name, mime: mime, size: data.count, kind: kind, indexed: false, createdAt: now())
        try await db.execute("INSERT INTO files(id,user_id,name,mime,size,kind,text,created_at) VALUES(?,?,?,?,?,?,?,?)",
                             [.text(id), .text(userId), .text(name), .text(mime), .int(Int64(data.count)), .text(kind), .of(text), .double(rec.createdAt)])
        return rec
    }

    public func file(id: String) async throws -> FileRecord? {
        try await db.queryOne("SELECT * FROM files WHERE id=?", [.text(id)]).map(Store.file)
    }

    public func fileText(id: String) async throws -> String? {
        try await db.queryOne("SELECT text FROM files WHERE id=?", [.text(id)])?["text"]?.string
    }

    public func documents(userId: String) async throws -> [FileRecord] {
        try await db.query("SELECT * FROM files WHERE user_id=? AND kind='document' ORDER BY created_at DESC", [.text(userId)]).map(Store.file)
    }

    public func deleteFile(id: String) async throws {
        try await db.execute("DELETE FROM files WHERE id=?", [.text(id)])
        try? FileManager.default.removeItem(at: filePath(id: id))
    }

    /// Removes images no longer referenced by any message (deleted chats) and files on
    /// disk that no longer have a database row (after user deletion).
    public func purgeOrphanFiles() async throws {
        try await db.execute("""
            DELETE FROM files WHERE kind IN ('image','generated') AND created_at < ?
            AND id NOT IN (SELECT json_extract(j.value, '$.fileId') FROM messages m, json_each(m.attachments) j)
            """, [.double(now() - 86400)])
        let ids = Set(try await db.query("SELECT id FROM files").compactMap { $0["id"]?.string })
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: filesDir.path)) ?? []
        for name in onDisk where !ids.contains(name) {
            try? FileManager.default.removeItem(at: filesDir.appendingPathComponent(name))
        }
    }

    // MARK: - Document chunks

    public func replaceChunks(fileId: String, userId: String, chunks: [(String, [Float])]) async throws {
        var stmts: [(String, [SQLValue])] = [("DELETE FROM chunks WHERE file_id=?", [.text(fileId)])]
        for (i, c) in chunks.enumerated() {
            let blob = c.1.withUnsafeBufferPointer { Data(buffer: $0) }
            stmts.append(("INSERT INTO chunks(id,file_id,user_id,idx,text,embedding) VALUES(?,?,?,?,?,?)",
                          [.text(newID()), .text(fileId), .text(userId), .int(Int64(i)), .text(c.0), .blob(blob)]))
        }
        stmts.append(("UPDATE files SET indexed=1 WHERE id=?", [.text(fileId)]))
        try await db.transaction(stmts)
    }

    public func chunks(userId: String, fileIds: [String]?) async throws -> [(fileId: String, text: String, vector: [Float])] {
        var rows: [Row]
        if let fileIds, !fileIds.isEmpty {
            let qs = Array(repeating: "?", count: fileIds.count).joined(separator: ",")
            rows = try await db.query("SELECT file_id, text, embedding FROM chunks WHERE user_id=? AND file_id IN (\(qs))",
                                      [.text(userId)] + fileIds.map { .text($0) })
        } else {
            rows = try await db.query("SELECT file_id, text, embedding FROM chunks WHERE user_id=?", [.text(userId)])
        }
        return rows.map { r in
            let data = r["embedding"]?.data ?? Data()
            let vec: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return (r["file_id"]?.string ?? "", r["text"]?.string ?? "", vec)
        }
    }

    // MARK: - Memories

    public struct Memory: Codable, Sendable { public var id: String; public var content: String; public var createdAt: Double }

    public func memories(userId: String) async throws -> [Memory] {
        try await db.query("SELECT * FROM memories WHERE user_id=? ORDER BY created_at", [.text(userId)]).map {
            Memory(id: $0["id"]?.string ?? "", content: $0["content"]?.string ?? "", createdAt: $0["created_at"]?.double ?? 0)
        }
    }

    @discardableResult
    public func addMemory(userId: String, content: String) async throws -> Memory {
        let m = Memory(id: newID(), content: content, createdAt: now())
        try await db.execute("INSERT INTO memories(id,user_id,content,created_at) VALUES(?,?,?,?)",
                             [.text(m.id), .text(userId), .text(content), .double(m.createdAt)])
        return m
    }

    public func deleteMemory(userId: String, id: String) async throws -> Bool {
        try await db.execute("DELETE FROM memories WHERE id=? AND user_id=?", [.text(id), .text(userId)]) > 0
    }

    // MARK: - Passkeys

    public struct PasskeyRecord: Codable, Sendable {
        public var id: String
        public var userId: String
        public var name: String
        public var createdAt: Double
    }

    public func addPasskey(id: String, userId: String, name: String, publicKey: [UInt8], signCount: UInt32) async throws {
        try await db.execute("INSERT INTO passkeys(id,user_id,name,public_key,sign_count,created_at) VALUES(?,?,?,?,?,?)",
                             [.text(id), .text(userId), .text(name), .blob(Data(publicKey)), .int(Int64(signCount)), .double(now())])
    }

    public func passkey(id: String) async throws -> (userId: String, publicKey: [UInt8], signCount: UInt32)? {
        guard let r = try await db.queryOne("SELECT * FROM passkeys WHERE id=?", [.text(id)]) else { return nil }
        return (r["user_id"]?.string ?? "", [UInt8](r["public_key"]?.data ?? Data()), UInt32(r["sign_count"]?.int ?? 0))
    }

    public func passkeys(userId: String) async throws -> [PasskeyRecord] {
        try await db.query("SELECT id,user_id,name,created_at FROM passkeys WHERE user_id=? ORDER BY created_at", [.text(userId)]).map {
            PasskeyRecord(id: $0["id"]?.string ?? "", userId: $0["user_id"]?.string ?? "",
                          name: $0["name"]?.string ?? "", createdAt: $0["created_at"]?.double ?? 0)
        }
    }

    public func updatePasskeyCount(id: String, signCount: UInt32) async throws {
        try await db.execute("UPDATE passkeys SET sign_count=? WHERE id=?", [.int(Int64(signCount)), .text(id)])
    }

    public func deletePasskey(id: String, userId: String) async throws {
        try await db.execute("DELETE FROM passkeys WHERE id=? AND user_id=?", [.text(id), .text(userId)])
    }

    // MARK: - Devices (runner)

    public struct Device: Codable, Sendable {
        public var id: String
        public var userId: String
        public var name: String
        public var workspace: String?
        public var platform: String?
        public var createdAt: Double
        public var lastSeen: Double?
    }

    static func device(_ r: Row) -> Device {
        Device(id: r["id"]?.string ?? "", userId: r["user_id"]?.string ?? "", name: r["name"]?.string ?? "",
               workspace: r["workspace"]?.string, platform: r["platform"]?.string,
               createdAt: r["created_at"]?.double ?? 0, lastSeen: r["last_seen"]?.double)
    }

    public func addDevice(userId: String, name: String, tokenHash: String) async throws -> Device {
        let d = Device(id: newID(), userId: userId, name: name, workspace: nil, platform: nil, createdAt: now(), lastSeen: nil)
        try await db.execute("INSERT INTO devices(id,user_id,name,token_hash,created_at) VALUES(?,?,?,?,?)",
                             [.text(d.id), .text(userId), .text(name), .text(tokenHash), .double(d.createdAt)])
        return d
    }

    public func devices(userId: String) async throws -> [Device] {
        try await db.query("SELECT * FROM devices WHERE user_id=? ORDER BY created_at", [.text(userId)]).map(Store.device)
    }

    public func device(tokenHash: String) async throws -> Device? {
        try await db.queryOne("SELECT * FROM devices WHERE token_hash=?", [.text(tokenHash)]).map(Store.device)
    }

    public func device(id: String) async throws -> Device? {
        try await db.queryOne("SELECT * FROM devices WHERE id=?", [.text(id)]).map(Store.device)
    }

    public func touchDevice(id: String, workspace: String?, platform: String?) async throws {
        try await db.execute("UPDATE devices SET last_seen=?, workspace=COALESCE(?,workspace), platform=COALESCE(?,platform) WHERE id=?",
                             [.double(now()), .of(workspace), .of(platform), .text(id)])
    }

    public func deleteDevice(id: String, userId: String) async throws {
        try await db.execute("DELETE FROM devices WHERE id=? AND user_id=?", [.text(id), .text(userId)])
    }
}
