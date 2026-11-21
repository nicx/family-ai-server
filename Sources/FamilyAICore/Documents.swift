import Foundation
import PDFKit

/// Text extraction, chunking and embedding search for uploaded documents.
public enum Documents {
    static let textTypes: Set<String> = ["txt", "md", "markdown", "csv", "json", "xml", "html", "htm", "log",
                                         "swift", "py", "js", "ts", "java", "c", "h", "cpp", "cs", "go", "rs",
                                         "rb", "php", "sh", "yaml", "yml", "toml", "ini", "css", "sql"]

    /// Extracts plain text from a file, nil if the type is not supported.
    public static func extractText(data: Data, name: String, mime: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        if mime == "application/pdf" || ext == "pdf" {
            guard let doc = PDFDocument(data: data) else { return nil }
            var parts: [String] = []
            for i in 0..<doc.pageCount {
                if let s = doc.page(at: i)?.string { parts.append(s) }
            }
            let text = parts.joined(separator: "\n\n")
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        if ["docx", "doc", "rtf", "odt", "pages"].contains(ext) || mime.contains("wordprocessingml") || mime == "application/rtf" {
            let types: [String: NSAttributedString.DocumentType] = ["docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "odt": .openDocument]
            var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let t = types[ext] { opts[.documentType] = t }
            if let s = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) { return s.string }
            return nil
        }
        if mime.hasPrefix("text/") || textTypes.contains(ext) || mime == "application/json" {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        return nil
    }

    /// Splits text into overlapping chunks of roughly `size` characters, on paragraph/sentence boundaries.
    public static func chunk(_ text: String, size: Int = 1500, overlap: Int = 200) -> [String] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard clean.count > size else { return clean.isEmpty ? [] : [clean] }
        var chunks: [String] = []
        var start = clean.startIndex
        while start < clean.endIndex {
            var end = clean.index(start, offsetBy: size, limitedBy: clean.endIndex) ?? clean.endIndex
            if end < clean.endIndex {
                let window = clean[start..<end]
                if let p = window.range(of: "\n\n", options: .backwards), clean.distance(from: start, to: p.lowerBound) > size / 2 {
                    end = p.upperBound
                } else if let p = window.range(of: ". ", options: .backwards), clean.distance(from: start, to: p.lowerBound) > size / 2 {
                    end = p.upperBound
                }
            }
            let piece = String(clean[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            if end >= clean.endIndex { break }
            start = clean.index(end, offsetBy: -overlap, limitedBy: clean.startIndex) ?? end
            if start <= clean.startIndex { start = end }
        }
        return chunks
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na.squareRoot() * nb.squareRoot())
        return d > 0 ? dot / d : -1
    }

    /// Embeds and stores all chunks of a document.
    public static func index(fileId: String, userId: String, text: String, store: Store, router: OpenRouter, key: String, model: String) async throws {
        let pieces = chunk(text)
        guard !pieces.isEmpty else { return }
        var result: [(String, [Float])] = []
        var i = 0
        while i < pieces.count {
            let batch = Array(pieces[i..<min(i + 64, pieces.count)])
            let vectors = try await router.embed(key: key, model: model, inputs: batch, inputType: "search_document")
            for (t, v) in zip(batch, vectors) { result.append((t, v)) }
            i += 64
        }
        try await store.replaceChunks(fileId: fileId, userId: userId, chunks: result)
    }

    /// Top matching chunks for a query: semantic search over embedded chunks, plus a
    /// keyword search over all documents (works without embeddings, e.g. when the
    /// embedding model is not available for the key).
    public static func search(query: String, userId: String, fileIds: [String]?, store: Store, router: OpenRouter, key: String, model: String, limit: Int = 6) async throws -> [(fileId: String, text: String, score: Float)] {
        var results: [(fileId: String, text: String, score: Float)] = []
        let chunks = try await store.chunks(userId: userId, fileIds: fileIds)
        if !chunks.isEmpty, let q = try? await router.embed(key: key, model: model, inputs: [query], inputType: "search_query").first {
            results = chunks.map { ($0.fileId, $0.text, cosine(q, $0.vector)) }.sorted { $0.2 > $1.2 }.prefix(limit).map { $0 }
        }
        if results.count < limit {
            let docs = try await store.documents(userId: userId).filter { fileIds == nil || fileIds!.contains($0.id) }
            var kw: [(fileId: String, text: String, score: Float)] = []
            let terms = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
            for d in docs {
                guard let text = try await store.fileText(id: d.id) else { continue }
                for piece in chunk(text, size: 1200, overlap: 150) {
                    let lower = piece.lowercased()
                    let score = terms.reduce(Float(0)) { acc, t in acc + (lower.contains(t) ? 1 : 0) }
                    if score > 0 { kw.append((d.id, piece, score / Float(max(1, terms.count)))) }
                }
            }
            let seen = Set(results.map(\.text))
            results += kw.filter { !seen.contains($0.text) }.sorted { $0.score > $1.score }.prefix(limit - results.count)
        }
        return results
    }
}
