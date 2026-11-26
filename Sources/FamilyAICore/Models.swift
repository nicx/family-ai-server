import Foundation

public enum Role: String, Codable, Sendable, CaseIterable {
    case admin, parent, child
}

/// Per-person settings, set by the admin only.
public struct Profile: Codable, Sendable, Equatable {
    /// Additional models for this person, on top of the default and escalation models.
    public var allowedModels: [String] = []
    /// Model preselected for new chats.
    public var defaultModel: String?
    /// Additional system prompt for this person (e.g. "Lernhelfer").
    public var systemPrompt: String = ""
    public var images: Bool = true
    public var voice: Bool = true
    public var webSearch: Bool = true
    public var memory: Bool = true
    public var documents: Bool = true
    public var code: Bool = false
    /// Children only: parents may read this child's chats.
    public var parentalView: Bool = false
    /// "" = family default, "off" = no escalation button, otherwise a model id.
    public var escalationModel: String = ""

    public init() {}

    public static func defaults(for role: Role) -> Profile {
        var p = Profile()
        if role == .child {
            p.code = false
            p.webSearch = true
        }
        return p
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Profile()
        allowedModels = try c.decodeIfPresent([String].self, forKey: .allowedModels) ?? d.allowedModels
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
        images = try c.decodeIfPresent(Bool.self, forKey: .images) ?? d.images
        voice = try c.decodeIfPresent(Bool.self, forKey: .voice) ?? d.voice
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? d.webSearch
        memory = try c.decodeIfPresent(Bool.self, forKey: .memory) ?? d.memory
        documents = try c.decodeIfPresent(Bool.self, forKey: .documents) ?? d.documents
        code = try c.decodeIfPresent(Bool.self, forKey: .code) ?? d.code
        parentalView = try c.decodeIfPresent(Bool.self, forKey: .parentalView) ?? d.parentalView
        escalationModel = try c.decodeIfPresent(String.self, forKey: .escalationModel) ?? d.escalationModel
    }
}

public struct User: Codable, Sendable, Equatable {
    public var id: String
    public var username: String
    public var displayName: String
    public var role: Role
    public var profile: Profile
    public var createdAt: Double
    public var disabled: Bool
}

public struct Chat: Codable, Sendable {
    public var id: String
    public var userId: String
    public var title: String
    public var model: String
    public var mode: String          // "chat" | "code"
    public var deviceId: String?
    public var createdAt: Double
    public var updatedAt: Double
}

public struct Attachment: Codable, Sendable, Equatable {
    public var fileId: String
    public var name: String
    public var mime: String
    public var kind: String          // "image" | "document" | "audio" | "generated"
}

public struct Source: Codable, Sendable, Equatable {
    public var url: String
    public var title: String?
}

public struct MessageMeta: Codable, Sendable, Equatable {
    public var model: String?
    public var cost: Double?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var sources: [Source]?
    public var tools: [String]?
    /// Werkzeugaufrufe mit gekürzten Argumenten und Ergebnissen – nur zur Fehlersuche (Admin), nicht fürs Modell.
    public var toolLog: [ToolLogEntry]?
    public var error: String?
}

public struct ToolLogEntry: Codable, Sendable, Equatable {
    public var name: String
    public var args: String
    public var result: String
}

public struct Message: Codable, Sendable {
    public var id: String
    public var chatId: String
    public var role: String          // "user" | "assistant"
    public var content: String
    public var attachments: [Attachment]
    public var meta: MessageMeta
    public var createdAt: Double
}

/// Global, admin-managed settings.
public struct GlobalSettings: Codable, Sendable, Equatable {
    public var aiName: String = "Lumi"
    public var familyName: String = ""
    public var language: String = "de"
    public var imageModel: String = "microsoft/mai-image-2.7-flash"
    public var ttsModel: String = "microsoft/mai-voice-2.1-flash"
    public var ttsVoice: String = "de-DE-Mia:MAI-Voice-2.1-Flash"
    public var sttModel: String = "openai/whisper-large-v3-turbo"
    public var embedModel: String = "openai/text-embedding-3-large"
    public var titleModel: String = ""
    /// Delete chats older than N days; 0 = never.
    public var retentionDays: Int = 0
    /// Show children a notice that a parent can read along.
    public var kidNoticeVisible: Bool = false
    /// Restrict the admin area to LAN/VPN client addresses.
    public var adminLocalOnly: Bool = true
    public var budgetThreshold: Int = 80
    public var notifyOnBudget: Bool = false
    public var mailRecipient: String = ""
    public var mailSender: String = ""
    public var smtpHost: String = ""
    public var smtpPort: Int = 25
    /// "none" (local relay), "starttls" (usually 587) or "tls" (usually 465).
    public var smtpSecurity: String = "none"
    /// SMTP login; the password lives in the key store under `smtpPasswordAccount`.
    public var smtpUser: String = ""
    /// Public origin, e.g. https://ai.example.org — needed for passkeys.
    public var publicURL: String = ""
    public var webSearchMaxResults: Int = 5
    /// Preselected model for people without their own default.
    public var defaultModel: String = "anthropic/claude-haiku-5.5"
    /// Model for "answer with a stronger model" (empty = feature off). Overridable per person.
    public var escalationModel: String = "anthropic/claude-sonnet-5.5"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlobalSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        aiName = try v(.aiName, d.aiName)
        familyName = try v(.familyName, d.familyName)
        language = try v(.language, d.language)
        imageModel = try v(.imageModel, d.imageModel)
        ttsModel = try v(.ttsModel, d.ttsModel)
        ttsVoice = try v(.ttsVoice, d.ttsVoice)
        sttModel = try v(.sttModel, d.sttModel)
        embedModel = try v(.embedModel, d.embedModel)
        titleModel = try v(.titleModel, d.titleModel)
        retentionDays = try v(.retentionDays, d.retentionDays)
        kidNoticeVisible = try v(.kidNoticeVisible, d.kidNoticeVisible)
        adminLocalOnly = try v(.adminLocalOnly, d.adminLocalOnly)
        budgetThreshold = try v(.budgetThreshold, d.budgetThreshold)
        notifyOnBudget = try v(.notifyOnBudget, d.notifyOnBudget)
        mailRecipient = try v(.mailRecipient, d.mailRecipient)
        mailSender = try v(.mailSender, d.mailSender)
        smtpHost = try v(.smtpHost, d.smtpHost)
        smtpPort = try v(.smtpPort, d.smtpPort)
        smtpSecurity = try v(.smtpSecurity, d.smtpSecurity)
        smtpUser = try v(.smtpUser, d.smtpUser)
        publicURL = try v(.publicURL, d.publicURL)
        webSearchMaxResults = try v(.webSearchMaxResults, d.webSearchMaxResults)
        defaultModel = try v(.defaultModel, d.defaultModel)
        escalationModel = try v(.escalationModel, d.escalationModel)
    }
}

extension GlobalSettings {
    /// Key-store account for the SMTP password (cannot collide with user ids, which are UUIDs).
    public static let smtpPasswordAccount = "smtp-password"

    public var mailFrom: String { mailSender.isEmpty ? mailRecipient : mailSender }

    public func mailAccount(keys: KeyStore) -> Mailer.Account {
        Mailer.Account(host: smtpHost, port: smtpPort,
                       security: Mailer.Security(rawValue: smtpSecurity) ?? .none,
                       user: smtpUser,
                       password: smtpUser.isEmpty ? nil : keys.get(GlobalSettings.smtpPasswordAccount))
    }
}

public func now() -> Double { Date().timeIntervalSince1970 }
public func newID() -> String { UUID().uuidString.lowercased() }

let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
}()
let jsonDecoder = JSONDecoder()

func encodeJSON<T: Encodable>(_ v: T) -> String {
    (try? String(data: jsonEncoder.encode(v), encoding: .utf8)) ?? "{}"
}
func decodeJSON<T: Decodable>(_ t: T.Type, _ s: String?) -> T? {
    guard let s, let d = s.data(using: .utf8) else { return nil }
    return try? jsonDecoder.decode(t, from: d)
}
