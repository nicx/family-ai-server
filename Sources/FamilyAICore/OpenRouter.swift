import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenRouterError: Error, CustomStringConvertible {
    public let status: Int
    public let message: String
    public var description: String { status > 0 ? "OpenRouter \(status): \(message)" : message }
}

/// One accumulated tool call from a streamed response.
public struct ToolCall: Sendable {
    public var id: String
    public var name: String
    public var arguments: String
}

/// Events produced while streaming a chat completion.
public enum StreamEvent: Sendable {
    case text(String)
    case reasoning(String)
    case image(String)            // data URL
    case source(Source)
    case finished(toolCalls: [ToolCall], finishReason: String?, usage: Usage?)
}

public struct Usage: Sendable, Codable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var cost: Double?
    public var webSearchRequests: Int?
}

public struct ModelInfo: Codable, Sendable {
    public var id: String
    public var name: String
    public var contextLength: Int?
    public var inputModalities: [String]
    public var outputModalities: [String]
    public var supportsTools: Bool
    public var promptPrice: Double?
    public var completionPrice: Double?
    /// Gültige Stimmen (nur Sprachmodelle, `supported_voices`).
    public var voices: [String] = []
}

/// Thin client for the OpenRouter HTTP API (chat, images, speech, transcription,
/// embeddings, key status, model catalog).
public final class OpenRouter: Sendable {
    public let baseURL: URL
    let session: URLSession
    let appTitle: String

    public init(baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!, appTitle: String = "Family AI Server") {
        self.baseURL = baseURL
        self.appTitle = appTitle
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 1800
        session = URLSession(configuration: cfg)
    }

    private func request(_ path: String, key: String, method: String = "POST", json: Any? = nil) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue(appTitle, forHTTPHeaderField: "X-Title")
        r.setValue("https://github.com/nicx/family-ai-server", forHTTPHeaderField: "HTTP-Referer")
        if var body = json as? [String: Any] {
            // Datenschutz: JEDE Anfrage verlangt Zero Data Retention und keine Datensammlung beim Anbieter – zusätzlich zur
            // Guardrail im OpenRouter-Konto (zweite Absicherung; wirkt nur verschärfend). Zentral hier, damit kein Aufruf fehlt.
            var provider = (body["provider"] as? [String: Any]) ?? [:]
            provider["zdr"] = true
            provider["data_collection"] = "deny"
            body["provider"] = provider
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any] {
            var msg = (err["message"] as? String) ?? "Fehler"
            if let meta = err["metadata"] as? [String: Any], let raw = meta["raw"] as? String {
                msg += " (\(raw.prefix(300)))"
            }
            return msg
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "Fehler"
    }

    private func checked(_ data: Data, _ resp: URLResponse) throws -> Data {
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OpenRouterError(status: status, message: Self.errorMessage(data))
        }
        return data
    }

    // MARK: - Chat (streaming)

    /// Streams a chat completion. `body` is the full OpenAI-style request (without `stream`).
    public func streamChat(key: String, body: [String: Any]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var b = body
                    b["stream"] = true
                    let req = try request("chat/completions", key: key, json: b)
                    let (status, lines) = try await openLineStream(req)
                    if !(200..<300).contains(status) {
                        var text = ""
                        for try await line in lines { text += line + "\n"; if text.utf8.count > 20000 { break } }
                        throw OpenRouterError(status: status, message: Self.errorMessage(Data(text.utf8)))
                    }
                    var calls: [Int: ToolCall] = [:]
                    var finish: String?
                    var usage: Usage?
                    var seenImages = Set<String>()
                    var seenSources = Set<String>()
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let err = obj["error"] as? [String: Any] {
                            throw OpenRouterError(status: (err["code"] as? Int) ?? 0, message: (err["message"] as? String) ?? "Stream-Fehler")
                        }
                        if let u = obj["usage"] as? [String: Any] { usage = Self.parseUsage(u) }
                        guard let choices = obj["choices"] as? [[String: Any]], let choice = choices.first else { continue }
                        if let fr = choice["finish_reason"] as? String { finish = fr }
                        let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
                        if let text = delta["content"] as? String, !text.isEmpty { continuation.yield(.text(text)) }
                        if let r = delta["reasoning"] as? String, !r.isEmpty { continuation.yield(.reasoning(r)) }
                        if let images = delta["images"] as? [[String: Any]] {
                            for img in images {
                                if let url = (img["image_url"] as? [String: Any])?["url"] as? String, !seenImages.contains(url) {
                                    seenImages.insert(url)
                                    continuation.yield(.image(url))
                                }
                            }
                        }
                        if let anns = delta["annotations"] as? [[String: Any]] {
                            for a in anns {
                                let c = (a["url_citation"] as? [String: Any]) ?? a
                                if let url = c["url"] as? String, !seenSources.contains(url) {
                                    seenSources.insert(url)
                                    continuation.yield(.source(Source(url: url, title: c["title"] as? String)))
                                }
                            }
                        }
                        if let tcs = delta["tool_calls"] as? [[String: Any]] {
                            for tc in tcs {
                                let idx = (tc["index"] as? Int) ?? calls.count
                                var cur = calls[idx] ?? ToolCall(id: "", name: "", arguments: "")
                                if let id = tc["id"] as? String, !id.isEmpty { cur.id = id }
                                if let f = tc["function"] as? [String: Any] {
                                    if let n = f["name"] as? String, !n.isEmpty { cur.name += n }
                                    if let a = f["arguments"] as? String { cur.arguments += a }
                                }
                                calls[idx] = cur
                            }
                        }
                    }
                    let ordered = calls.keys.sorted().compactMap { calls[$0] }.map { c -> ToolCall in
                        var c = c
                        if c.id.isEmpty { c.id = "call_" + newID().prefix(8) }
                        return c
                    }
                    continuation.yield(.finished(toolCalls: ordered, finishReason: finish, usage: usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens a streaming request and returns the HTTP status and the response body line by line.
    /// macOS uses `URLSession.bytes`; swift-corelibs-foundation (Linux) has no such API, so a delegate feeds the lines.
    func openLineStream(_ req: URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        #if canImport(FoundationNetworking)
        return try await LineStreamLoader.open(req, configuration: session.configuration)
        #else
        let (bytes, resp) = try await session.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, Error> { c in
            let t = Task {
                do { for try await l in bytes.lines { c.yield(l) }; c.finish() } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in t.cancel() }
        }
        return (status, lines)
        #endif
    }

    static func parseUsage(_ u: [String: Any]) -> Usage {
        var usage = Usage()
        usage.promptTokens = u["prompt_tokens"] as? Int
        usage.completionTokens = u["completion_tokens"] as? Int
        usage.cost = (u["cost"] as? NSNumber)?.doubleValue
        if let s = u["server_tool_use_details"] as? [String: Any] {
            usage.webSearchRequests = s["web_search_requests"] as? Int
        }
        return usage
    }

    /// Non-streaming completion returning only the text (used for chat titles).
    public func complete(key: String, model: String, messages: [[String: Any]], maxTokens: Int = 60, user: String? = nil) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": messages, "max_tokens": maxTokens]
        if let user { body["user"] = user }
        let req = try request("chat/completions", key: key, json: body)
        let (data, resp) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: checked(data, resp)) as? [String: Any]
        let msg = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        return (msg?["content"] as? String) ?? ""
    }

    // MARK: - Images

    public struct GeneratedImage: Sendable { public var data: Data; public var mime: String }

    public func generateImage(key: String, model: String, prompt: String, aspectRatio: String? = nil) async throws -> (GeneratedImage, Double?) {
        var body: [String: Any] = ["model": model, "prompt": prompt, "n": 1]
        if let aspectRatio { body["aspect_ratio"] = aspectRatio }
        let req = try request("images", key: key, json: body)
        let (data, resp) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: checked(data, resp)) as? [String: Any]
        guard let first = (obj?["data"] as? [[String: Any]])?.first else {
            throw OpenRouterError(status: 0, message: "Keine Bilddaten in der Antwort")
        }
        let mime = (first["media_type"] as? String) ?? "image/png"
        var imgData: Data?
        if let b64 = first["b64_json"] as? String { imgData = Data(base64Encoded: b64) }
        else if let url = first["url"] as? String, let u = URL(string: url) {
            imgData = try await session.data(from: u).0
        }
        guard let imgData else { throw OpenRouterError(status: 0, message: "Bild konnte nicht gelesen werden") }
        let cost = ((obj?["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue
        return (GeneratedImage(data: imgData, mime: mime), cost)
    }

    // MARK: - Speech

    public func speech(key: String, model: String, voice: String, text: String) async throws -> Data {
        let req = try request("audio/speech", key: key, json: [
            "model": model, "voice": voice, "input": text, "response_format": "mp3",
        ])
        let (data, resp) = try await session.data(for: req)
        return try checked(data, resp)
    }

    public func transcribe(key: String, model: String, audio: Data, format: String, language: String?) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio.base64EncodedString(), "format": format],
        ]
        if let language { body["language"] = language }
        let req = try request("audio/transcriptions", key: key, json: body)
        let (data, resp) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: checked(data, resp)) as? [String: Any]
        return (obj?["text"] as? String) ?? ""
    }

    // MARK: - Embeddings

    public func embed(key: String, model: String, inputs: [String], inputType: String? = nil) async throws -> [[Float]] {
        var body: [String: Any] = ["model": model, "input": inputs]
        if let inputType { body["input_type"] = inputType }
        let req = try request("embeddings", key: key, json: body)
        let (data, resp) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: checked(data, resp)) as? [String: Any]
        guard let arr = obj?["data"] as? [[String: Any]] else {
            throw OpenRouterError(status: 0, message: "Keine Embeddings in der Antwort")
        }
        let sorted = arr.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return sorted.map { ($0["embedding"] as? [NSNumber] ?? []).map { $0.floatValue } }
    }

    // MARK: - Key & models

    public struct KeyStatus: Codable, Sendable {
        public var limit: Double?
        public var remaining: Double?
        public var usage: Double?
        public var reset: String?
        public var label: String?
    }

    public func keyStatus(key: String) async throws -> KeyStatus {
        let req = try request("key", key: key, method: "GET")
        let (data, resp) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: checked(data, resp)) as? [String: Any]
        let d = (obj?["data"] as? [String: Any]) ?? [:]
        return KeyStatus(limit: (d["limit"] as? NSNumber)?.doubleValue,
                         remaining: (d["limit_remaining"] as? NSNumber)?.doubleValue,
                         usage: (d["usage"] as? NSNumber)?.doubleValue,
                         reset: d["limit_reset"] as? String,
                         label: d["label"] as? String)
    }

    /// Public model catalog (no key needed). Ohne `output_modalities=all` liefert OpenRouter nur Modelle mit Text-Ausgabe –
    /// reine Bild-, Sprach- und Transkriptionsmodelle (z. B. MAI-Image, Whisper) fehlten dann in den Auswahllisten.
    /// Embedding-Modelle stehen nur im eigenen Endpunkt `/embeddings/models` (Ausgabe „embeddings“).
    public func models() async throws -> [ModelInfo] {
        let main = try await fetchModels(path: "models", query: [URLQueryItem(name: "output_modalities", value: "all")])
        let embeddings = (try? await fetchModels(path: "embeddings/models", query: [])) ?? []
        let known = Set(main.map(\.id))   // `all` enthält Embedding-Modelle teils schon
        return main + embeddings.filter { !known.contains($0.id) }
    }

    private func fetchModels(path: String, query: [URLQueryItem]) async throws -> [ModelInfo] {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.setValue(appTitle, forHTTPHeaderField: "X-Title")
        let (data, resp) = try await session.data(for: r)
        let obj = try JSONSerialization.jsonObject(with: checked(data, resp)) as? [String: Any]
        let list = (obj?["data"] as? [[String: Any]]) ?? []
        return list.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let arch = (m["architecture"] as? [String: Any]) ?? [:]
            let pricing = (m["pricing"] as? [String: Any]) ?? [:]
            let params = (m["supported_parameters"] as? [String]) ?? []
            return ModelInfo(id: id, name: (m["name"] as? String) ?? id,
                             contextLength: m["context_length"] as? Int,
                             inputModalities: (arch["input_modalities"] as? [String]) ?? ["text"],
                             outputModalities: (arch["output_modalities"] as? [String]) ?? ["text"],
                             supportsTools: params.contains("tools"),
                             promptPrice: Double((pricing["prompt"] as? String) ?? ""),
                             completionPrice: Double((pricing["completion"] as? String) ?? ""),
                             voices: (m["supported_voices"] as? [String]) ?? [])
        }
    }
}
