import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Cached OpenRouter model catalog.
public actor ModelCatalog {
    private var cache: [ModelInfo] = []
    private var fetched: Double = 0
    let router: OpenRouter

    public init(router: OpenRouter) { self.router = router }

    public func all() async -> [ModelInfo] {
        if cache.isEmpty || now() - fetched > 3600 {
            if let fresh = try? await router.models(), !fresh.isEmpty {
                // Sorted by name ("Anthropic: Claude …"), so models group by provider; numbers compare naturally (5.5 before 10).
                cache = fresh.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                fetched = now()
            }
        }
        return cache
    }

    public func info(_ id: String) async -> ModelInfo? { await all().first { $0.id == id } }

    /// Chat-capable models (text output).
    public func chatModels() async -> [ModelInfo] {
        await all().filter { $0.outputModalities.contains("text") }
    }
}

/// Events streamed to the browser while an answer is generated.
public enum ChatEvent: Sendable {
    case text(String)
    case status(String)
    case image(fileId: String)
    case approval(id: String, tool: String, title: String, text: String)
    case source(Source)
    case done(Message)
    case error(String)

    public var json: [String: Any] {
        switch self {
        case .text(let s): return ["t": "text", "v": s]
        case .status(let s): return ["t": "status", "v": s]
        case .image(let id): return ["t": "image", "fileId": id]
        case .approval(let id, let tool, let title, let text): return ["t": "approval", "id": id, "tool": tool, "title": title, "text": text]
        case .source(let s): return ["t": "source", "url": s.url, "title": s.title ?? ""]
        case .done(let m): return ["t": "done", "message": (try? JSONSerialization.jsonObject(with: jsonEncoder.encode(m))) ?? [:]]
        case .error(let s): return ["t": "error", "v": s]
        }
    }
}

/// Builds requests, runs the tool loop and stores the result.
public final class ChatEngine: Sendable {
    let store: Store
    let router: OpenRouter
    let keys: KeyStore
    let catalog: ModelCatalog
    let runner: RunnerHub

    public init(store: Store, router: OpenRouter, keys: KeyStore, catalog: ModelCatalog, runner: RunnerHub) {
        self.store = store
        self.router = router
        self.keys = keys
        self.catalog = catalog
        self.runner = runner
    }

    static let maxRounds = 8
    static let inlineTextLimit = 40_000

    // MARK: - Prompt

    /// Erstes Wort des Anzeigenamens (bei leerem Namen unverändert).
    public static func firstName(_ displayName: String) -> String {
        displayName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? displayName
    }

    /// Pseudonyme, stabile Kennung für OpenRouters `user`-Feld (Missbrauchs-Isolierung), ohne Namen oder interne ID.
    public static func pseudonym(_ userId: String) -> String {
        "u_" + SHA256.hash(data: Data(("family-ai:" + userId).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func systemPrompt(user: User, settings: GlobalSettings, memories: [Store.Memory], hasDocs: Bool, codeDevice: Store.Device?) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: settings.language == "en" ? "en_US" : "de_DE")
        df.dateFormat = settings.language == "en" ? "EEEE, MMMM d, yyyy, HH:mm" : "EEEE, d. MMMM yyyy, HH:mm 'Uhr'"
        var lines: [String] = []
        // Datenschutz: Familienname und Nachname gehen nie an das Modell – nur der Vorname.
        let family = settings.familyName.isEmpty ? "" : (settings.language == "en" ? " of the family" : " der Familie")
        let name = Self.firstName(user.displayName)
        if settings.language == "en" {
            lines.append("You are \(settings.aiName), the AI assistant\(family). You are talking with \(name).")
            lines.append("Today is \(df.string(from: Date())). Answer in the language the person writes in. Use Markdown where it helps.")
        } else {
            lines.append("Du bist \(settings.aiName), die KI\(family). Du sprichst mit \(name).")
            lines.append("Heute ist \(df.string(from: Date())). Antworte in der Sprache, in der die Person schreibt. Nutze Markdown, wo es hilft.")
        }
        if user.role == .child {
            lines.append("Die Person ist ein Kind. Sprich verständlich, freundlich und respektvoll – nicht kindisch, nicht übertrieben begeistert. Keine Inhalte, die für Kinder ungeeignet sind. Bei Hausaufgaben hilfst du beim Verstehen und beim Lösungsweg, ohne die fertige Lösung zu verraten.")
        }
        if !user.profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(user.profile.systemPrompt)
        }
        if user.profile.memory {
            if memories.isEmpty {
                lines.append("Gedächtnis: Noch nichts gespeichert. Wenn die Person dich bittet, dir etwas zu merken, oder dauerhaft nützliche Fakten über sich nennt (Klasse, Vorlieben, Wohnort), speichere sie mit dem Werkzeug `remember`.")
            } else {
                lines.append("Gedächtnis (was du über die Person weißt; mit `forget` und der ID löschen, mit `remember` ergänzen):")
                for m in memories { lines.append("- [\(m.id.prefix(8))] \(m.content)") }
            }
        }
        if user.profile.images {
            lines.append("Wenn die Person ein Bild möchte, nutze das Werkzeug `generate_image` mit einer ausführlichen englischen Bildbeschreibung.")
        }
        if hasDocs {
            lines.append("Die Person hat Dokumente hochgeladen. Nutze `search_documents`, wenn eine Frage sich auf ihre Dokumente beziehen könnte.")
        }
        if user.profile.webSearch {
            lines.append("Für aktuelle Informationen kannst du im Web suchen. Nenne dann die Quellen.")
        }
        if let codeDevice {
            lines.append("""
            Du arbeitest als Programmier-Assistent auf dem Computer „\(codeDevice.name)“ der Person (Arbeitsordner: \(codeDevice.workspace ?? "unbekannt"), System: \(codeDevice.platform ?? "unbekannt")).
            Werkzeuge: list_files, read_file, search_files (Dateinamen und Text in Dateien suchen), write_file, make_dir, move_file (verschiebt/benennt um, überschreibt nie), delete_file (nur einzelne Dateien und leere Ordner), run_command, save_image (legt ein erzeugtes oder hochgeladenes Bild als Datei im Arbeitsordner ab; write_file kann nur Text). Pfade sind relativ zum Arbeitsordner. Jede Aktion muss die Person am Computer freigeben; wird sie abgelehnt, frag nach, statt es erneut zu versuchen.
            Arbeite in kleinen, nachvollziehbaren Schritten und erkläre kurz, was du tust.
            """)
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Tools

    func tools(user: User, settings: GlobalSettings, hasDocs: Bool, codeDevice: Store.Device?, modelSupportsTools: Bool) -> [[String: Any]] {
        var t: [[String: Any]] = []
        if user.profile.webSearch {
            // Datenschutz: feste Engine "native" = Suche des Modellanbieters selbst (kein zusätzlicher Drittanbieter wie Exa);
            // Modelle ohne eingebaute Suche weichen laut OpenRouter auf Exa aus. Firecrawl scheitert an der ZDR-Guardrail.
            t.append(["type": "openrouter:web_search", "parameters": ["engine": "native", "max_results": settings.webSearchMaxResults]])
        }
        guard modelSupportsTools else { return t }
        func fn(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": desc,
                                              "parameters": ["type": "object", "properties": props, "required": required]]]
        }
        if user.profile.images {
            t.append(fn("generate_image", "Erzeugt ein Bild aus einer Beschreibung und zeigt es der Person.",
                        ["prompt": ["type": "string", "description": "Ausführliche Bildbeschreibung, am besten auf Englisch"],
                         "aspect_ratio": ["type": "string", "description": "Optional, z.B. 1:1, 16:9, 9:16"]], ["prompt"]))
        }
        if user.profile.memory {
            t.append(fn("remember", "Speichert einen dauerhaften Fakt über die Person im Gedächtnis.",
                        ["fact": ["type": "string", "description": "Kurzer Fakt in einem Satz"]], ["fact"]))
            t.append(fn("forget", "Löscht einen Eintrag aus dem Gedächtnis.",
                        ["id": ["type": "string", "description": "Die ID aus der Gedächtnisliste (8 Zeichen)"]], ["id"]))
        }
        if hasDocs {
            t.append(fn("search_documents", "Durchsucht die hochgeladenen Dokumente der Person nach passenden Textstellen.",
                        ["query": ["type": "string", "description": "Suchanfrage"]], ["query"]))
        }
        if codeDevice != nil {
            t.append(fn("list_files", "Listet Dateien und Ordner im Arbeitsordner auf.",
                        ["path": ["type": "string", "description": "Relativer Pfad, leer für den Arbeitsordner"]], []))
            t.append(fn("read_file", "Liest eine Textdatei aus dem Arbeitsordner.",
                        ["path": ["type": "string"]], ["path"]))
            t.append(fn("write_file", "Schreibt (erstellt oder überschreibt) eine Datei im Arbeitsordner.",
                        ["path": ["type": "string"], "content": ["type": "string"]], ["path", "content"]))
            t.append(fn("search_files", "Sucht im Arbeitsordner nach Dateinamen (name, z. B. *.swift) und/oder nach Text in Dateien (query, Groß-/Kleinschreibung egal). Liefert Datei:Zeile: Text.",
                        ["query": ["type": "string", "description": "Gesuchter Text, optional"],
                         "name": ["type": "string", "description": "Dateinamen-Muster, z. B. *.py, optional"],
                         "path": ["type": "string", "description": "Unterordner, leer für den ganzen Arbeitsordner"]], []))
            t.append(fn("make_dir", "Legt einen Ordner (samt fehlender Elternordner) im Arbeitsordner an.",
                        ["path": ["type": "string"]], ["path"]))
            t.append(fn("move_file", "Verschiebt oder benennt eine Datei oder einen Ordner im Arbeitsordner um. Überschreibt nie; existiert das Ziel, schlägt es fehl.",
                        ["from": ["type": "string"], "to": ["type": "string"]], ["from", "to"]))
            t.append(fn("delete_file", "Löscht eine einzelne Datei oder einen leeren Ordner im Arbeitsordner. Nicht rückgängig zu machen; frag vorher nach, wenn nicht eindeutig gewünscht.",
                        ["path": ["type": "string"]], ["path"]))
            t.append(fn("run_command", "Führt einen Shell-Befehl im Arbeitsordner aus und liefert die Ausgabe.",
                        ["command": ["type": "string"]], ["command"]))
            t.append(fn("save_image", "Speichert ein Bild aus diesem Chat (erzeugt oder hochgeladen) als Datei im Arbeitsordner, z. B. header.jpg. Ohne file_id wird das neueste Bild genommen. Erlaubt: png, jpg, jpeg, webp, gif, höchstens 5 MB.",
                        ["path": ["type": "string", "description": "Relativer Dateiname mit Endung"],
                         "file_id": ["type": "string", "description": "Bild-ID, optional"]], ["path"]))
        }
        return t
    }

    // MARK: - Messages

    func buildMessages(system: String, history: [Message]) async -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in history {
            if m.role == "assistant" {
                var text = m.content
                let generated = m.attachments.filter { $0.kind == "generated" }
                if !generated.isEmpty { text += "\n\n[\(generated.count) Bild(er) wurden erzeugt und angezeigt.]" }
                if text.isEmpty { text = "…" }
                out.append(["role": "assistant", "content": text])
                continue
            }
            var parts: [[String: Any]] = []
            var text = m.content
            for a in m.attachments {
                if a.kind == "image", let data = try? Data(contentsOf: store.filePath(id: a.fileId)) {
                    parts.append(["type": "image_url", "image_url": ["url": "data:\(a.mime);base64,\(data.base64EncodedString())"]])
                } else if a.kind == "document" {
                    if let t = try? await store.fileText(id: a.fileId), !t.isEmpty {
                        let clipped = t.count > Self.inlineTextLimit
                            ? String(t.prefix(Self.inlineTextLimit)) + "\n[… gekürzt; weitere Stellen über search_documents]"
                            : t
                        text += "\n\n--- Datei: \(a.name) ---\n\(clipped)\n--- Ende \(a.name) ---"
                    } else {
                        text += "\n\n[Datei \(a.name) angehängt, Text konnte nicht gelesen werden.]"
                    }
                }
            }
            if parts.isEmpty {
                out.append(["role": "user", "content": text])
            } else {
                parts.insert(["type": "text", "text": text.isEmpty ? "(Bild)" : text], at: 0)
                out.append(["role": "user", "content": parts])
            }
        }
        return out
    }

    // MARK: - Run

    /// Generates the assistant answer for the last user message of `chat`.
    public func respond(user: User, chat: Chat, emit: @escaping @Sendable (ChatEvent) async -> Void) async -> Message? {
        var meta = MessageMeta(model: chat.model)
        var content = ""
        var attachments: [Attachment] = []
        var sources: [Source] = []
        var toolNames: [String] = []
        var toolLog: [ToolLogEntry] = []
        var totalCost = 0.0
        do {
            guard let key = keys.get(user.id), !key.isEmpty else {
                throw OpenRouterError(status: 0, message: "Für dich ist noch kein OpenRouter-Schlüssel hinterlegt. Bitte wende dich an den Admin.")
            }
            let settings = try await store.settings()
            let history = try await store.messages(chatId: chat.id)
            let memories = user.profile.memory ? try await store.memories(userId: user.id) : []
            let docs = user.profile.documents ? try await store.documents(userId: user.id) : []
            var codeDevice: Store.Device?
            if chat.mode == "code", user.profile.code, let did = chat.deviceId,
               let d = try await store.device(id: did), d.userId == user.id {
                codeDevice = d
                var online = await runner.isOnline(did)
                for _ in 0..<12 where !online { // a moment of grace, e.g. while the runner reconnects
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    online = await runner.isOnline(did)
                }
                if !online {
                    await emit(.status("Gerät „\(d.name)“ ist nicht verbunden – Code-Werkzeuge stehen erst zur Verfügung, wenn Family AI Runner läuft."))
                    codeDevice = nil
                }
            }
            let info = await catalog.info(chat.model)
            let supportsTools = info?.supportsTools ?? true
            let system = systemPrompt(user: user, settings: settings, memories: memories, hasDocs: !docs.isEmpty, codeDevice: codeDevice)
            var messages = await buildMessages(system: system, history: history)
            let toolDefs = tools(user: user, settings: settings, hasDocs: !docs.isEmpty, codeDevice: codeDevice, modelSupportsTools: supportsTools)
            let imageOut = info?.outputModalities.contains("image") ?? false

            var round = 0
            while round < Self.maxRounds {
                round += 1
                var body: [String: Any] = ["model": chat.model, "messages": messages, "user": Self.pseudonym(user.id)]
                if !toolDefs.isEmpty { body["tools"] = toolDefs }
                if imageOut { body["modalities"] = ["image", "text"] }
                var roundText = ""
                var calls: [ToolCall] = []
                for try await ev in router.streamChat(key: key, body: body) {
                    switch ev {
                    case .text(let s):
                        roundText += s
                        content += s
                        await emit(.text(s))
                    case .reasoning:
                        break
                    case .image(let url):
                        if let (data, mime) = Self.decodeDataURL(url) {
                            let rec = try await store.saveFile(userId: user.id, name: "bild.\(mime.split(separator: "/").last ?? "png")", mime: mime, kind: "generated", data: data)
                            attachments.append(Attachment(fileId: rec.id, name: rec.name, mime: mime, kind: "generated"))
                            await emit(.image(fileId: rec.id))
                        }
                    case .source(let s):
                        if !sources.contains(s) { sources.append(s); await emit(.source(s)) }
                    case .finished(let tc, _, let usage):
                        calls = tc
                        if let usage {
                            totalCost += usage.cost ?? 0
                            meta.promptTokens = (meta.promptTokens ?? 0) + (usage.promptTokens ?? 0)
                            meta.completionTokens = (meta.completionTokens ?? 0) + (usage.completionTokens ?? 0)
                        }
                    }
                }
                let functionCalls = calls.filter { !$0.name.hasPrefix("openrouter:") && !$0.name.isEmpty }
                if functionCalls.isEmpty { break }

                messages.append([
                    "role": "assistant",
                    "content": roundText,
                    "tool_calls": functionCalls.map { ["id": $0.id, "type": "function",
                                                       "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]] },
                ])
                if !roundText.isEmpty { content += "\n\n" }
                for call in functionCalls {
                    toolNames.append(call.name)
                    let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                    let result = await runTool(call.name, args: args, user: user, chat: chat, key: key, settings: settings,
                                               codeDevice: codeDevice, emit: emit, attachments: &attachments, cost: &totalCost)
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
                    toolLog.append(ToolLogEntry(name: call.name, args: String(call.arguments.prefix(600)),
                                                result: String(result.prefix(1500))))
                }
            }
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty {
                content = "(Keine Antwort erhalten.)"
            }
        } catch is CancellationError {
            meta.error = "Abgebrochen"
        } catch {
            meta.error = "\(error)"
            await emit(.error("\(error)"))
        }
        meta.cost = totalCost > 0 ? totalCost : nil
        meta.sources = sources.isEmpty ? nil : sources
        meta.tools = toolNames.isEmpty ? nil : toolNames
        meta.toolLog = toolLog.isEmpty ? nil : toolLog
        if content.isEmpty && attachments.isEmpty && meta.error == nil { return nil }
        let msg = Message(id: newID(), chatId: chat.id, role: "assistant", content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                          attachments: attachments, meta: meta, createdAt: now())
        try? await store.addMessage(msg)
        return msg
    }

    static func decodeDataURL(_ url: String) -> (Data, String)? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let mime = header.split(separator: ";").first.map(String.init) ?? "image/png"
        guard let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return (data, mime)
    }

    func runTool(_ name: String, args: [String: Any], user: User, chat: Chat, key: String, settings: GlobalSettings,
                 codeDevice: Store.Device?, emit: @escaping @Sendable (ChatEvent) async -> Void,
                 attachments: inout [Attachment], cost: inout Double) async -> String {
        do {
            switch name {
            case "generate_image":
                guard user.profile.images else { return "Bilderzeugung ist für diese Person nicht freigegeben." }
                let prompt = (args["prompt"] as? String) ?? ""
                await emit(.status("Erzeuge Bild …"))
                let (img, c) = try await router.generateImage(key: key, model: settings.imageModel, prompt: prompt,
                                                              aspectRatio: args["aspect_ratio"] as? String)
                cost += c ?? 0
                let ext = img.mime.split(separator: "/").last.map(String.init) ?? "png"
                let rec = try await store.saveFile(userId: user.id, name: "bild.\(ext)", mime: img.mime, kind: "generated", data: img.data)
                attachments.append(Attachment(fileId: rec.id, name: rec.name, mime: img.mime, kind: "generated"))
                await emit(.image(fileId: rec.id))
                let hint = codeDevice != nil ? " Mit save_image kannst du es im Arbeitsordner speichern (Bild-ID: \(rec.id))." : ""
                return "Das Bild wurde erzeugt und der Person angezeigt. Beschreibe es nicht erneut ausführlich." + hint
            case "save_image":
                guard let dev = codeDevice else { return "Kein Gerät verbunden." }
                let path = ((args["path"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return "FEHLER: Kein Dateiname angegeben." }
                var rec: Store.FileRecord?
                if let id = args["file_id"] as? String, !id.isEmpty {
                    rec = try await store.file(id: id)
                } else {
                    let history = try await store.messages(chatId: chat.id)
                    let all = history.flatMap(\.attachments) + attachments
                    if let a = all.last(where: { $0.mime.hasPrefix("image/") }) { rec = try await store.file(id: a.fileId) }
                }
                guard let file = rec, file.userId == user.id, file.mime.hasPrefix("image/") else {
                    return "FEHLER: Kein passendes Bild in diesem Chat gefunden."
                }
                guard file.size <= 5_000_000 else { return "FEHLER: Das Bild ist größer als 5 MB." }
                let data = try Data(contentsOf: store.filePath(id: file.id))
                await emit(.status("Speichere Bild \(path) – wartet auf Freigabe an „\(dev.name)“ …"))
                let r = await runner.execute(deviceId: dev.id, tool: "save_image",
                                             args: ["path": path, "data": data.base64EncodedString()], chatTitle: chat.title,
                                             onAsk: Self.askCard(emit))
                await emit(.status(r.ok ? "Bild \(path) gespeichert ✓" : "Bild \(path) ✗"))
                return (r.ok ? "" : "FEHLER: ") + r.output
            case "remember":
                guard user.profile.memory else { return "Gedächtnis ist deaktiviert." }
                let fact = ((args["fact"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fact.isEmpty else { return "Kein Fakt angegeben." }
                let m = try await store.addMemory(userId: user.id, content: String(fact.prefix(500)))
                await emit(.status("Gemerkt: \(fact)"))
                return "Gespeichert mit ID \(m.id.prefix(8))."
            case "forget":
                let id = (args["id"] as? String) ?? ""
                let all = try await store.memories(userId: user.id)
                guard let m = all.first(where: { $0.id.hasPrefix(id) && !id.isEmpty }) else { return "Kein Eintrag mit dieser ID." }
                _ = try await store.deleteMemory(userId: user.id, id: m.id)
                await emit(.status("Vergessen: \(m.content)"))
                return "Gelöscht."
            case "search_documents":
                let q = (args["query"] as? String) ?? ""
                await emit(.status("Durchsuche Dokumente …"))
                let hits = try await Documents.search(query: q, userId: user.id, fileIds: nil, store: store, router: router,
                                                      key: key, model: settings.embedModel)
                if hits.isEmpty { return "Keine passenden Stellen gefunden." }
                var names: [String: String] = [:]
                for h in hits where names[h.fileId] == nil { names[h.fileId] = try await store.file(id: h.fileId)?.name ?? "Dokument" }
                return hits.map { "[\(names[$0.fileId] ?? "Dokument")]\n\($0.text)" }.joined(separator: "\n\n---\n\n")
            case "list_files", "read_file", "write_file", "run_command", "search_files", "make_dir", "move_file", "delete_file":
                guard let dev = codeDevice else { return "Kein Gerät verbunden." }
                var sargs: [String: String] = [:]
                for (k, v) in args { sargs[k] = (v as? String) ?? "\(v)" }
                let label: String
                switch name {
                case "run_command": label = "Befehl: \(sargs["command"] ?? "")"
                case "write_file": label = "Schreibe \(sargs["path"] ?? "")"
                case "read_file": label = "Lese \(sargs["path"] ?? "")"
                case "search_files": label = "Suche \(sargs["query"] ?? sargs["name"] ?? "")"
                case "make_dir": label = "Lege Ordner \(sargs["path"] ?? "") an"
                case "move_file": label = "Verschiebe \(sargs["from"] ?? "") → \(sargs["to"] ?? "")"
                case "delete_file": label = "Lösche \(sargs["path"] ?? "")"
                default: label = "Liste \(sargs["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "Arbeitsordner")"
                }
                await emit(.status("\(label) – wartet auf Freigabe an „\(dev.name)“ …"))
                let r = await runner.execute(deviceId: dev.id, tool: name, args: sargs, chatTitle: chat.title, onAsk: Self.askCard(emit))
                await emit(.status(r.ok ? "\(label) ✓" : "\(label) ✗"))
                let out = r.output.count > 30_000 ? String(r.output.prefix(30_000)) + "\n[… gekürzt]" : r.output
                return (r.ok ? "" : "FEHLER: ") + out
            default:
                return "Unbekanntes Werkzeug \(name)."
            }
        } catch {
            return "Fehler: \(error)"
        }
    }

    /// Card with Allow / Deny in the chat, shown when the runner asks for approval there.
    static func askCard(_ emit: @escaping @Sendable (ChatEvent) async -> Void) -> @Sendable (RunnerHub.Job) async -> Void {
        { job in
            let d = RunnerHub.describe(job)
            await emit(.approval(id: job.id, tool: job.tool, title: d.title, text: d.text))
        }
    }

    // MARK: - Titles

    public func makeTitle(user: User, chat: Chat, firstMessage: String) async -> String? {
        guard let key = keys.get(user.id) else { return nil }
        let settings = try? await store.settings()
        let model = (settings?.titleModel.isEmpty ?? true) ? chat.model : settings!.titleModel
        let prompt = "Gib diesem Chat einen sehr kurzen Titel (2–5 Wörter, ohne Anführungszeichen, ohne Satzzeichen am Ende) in der Sprache der Nachricht. Nachricht:\n\n\(firstMessage.prefix(1500))"
        guard let t = try? await router.complete(key: key, model: model, messages: [["role": "user", "content": prompt]], maxTokens: 30, user: Self.pseudonym(user.id)) else { return nil }
        let clean = t.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'„“*#"))
        return clean.isEmpty ? nil : String(clean.prefix(80))
    }
}
