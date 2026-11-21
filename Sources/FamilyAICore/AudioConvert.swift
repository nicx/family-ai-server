import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AudioConvert {
    /// Normalises browser recordings for the transcription API.
    /// Safari records MP4/AAC, which is converted to 16 kHz mono WAV with the system's
    /// `afconvert`; WebM/Ogg (Chrome/Firefox) are passed through.
    static func prepare(data: Data, mime: String) -> (Data, String) {
        let m = mime.lowercased()
        if m.contains("webm") { return (data, "webm") }
        if m.contains("ogg") { return (data, "ogg") }
        if m.contains("wav") { return (data, "wav") }
        if m.contains("mpeg") || m.contains("mp3") { return (data, "mp3") }
        // mp4 / m4a / aac → wav
        let tmp = FileManager.default.temporaryDirectory
        let input = tmp.appendingPathComponent("family-ai-\(newID()).m4a")
        let output = tmp.appendingPathComponent("family-ai-\(newID()).wav")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        do {
            try data.write(to: input)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, output.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0, let wav = try? Data(contentsOf: output) { return (wav, "wav") }
        } catch {}
        return (data, "m4a")
    }

    static func heicToJPEG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
