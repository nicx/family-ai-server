import Foundation

/// Runs a helper program and returns its exit status. Used where macOS has a system framework
/// (PDFKit, ImageIO, afconvert) and Linux (Docker) needs a command-line tool instead.
enum ExternalTool {
    /// Searches the usual locations and `PATH` for `name`.
    static func find(_ name: String) -> String? {
        var dirs = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] { dirs += path.split(separator: ":").map(String.init) }
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `name args…`, returning (exit status, stdout). Output is read to the end before waiting,
    /// so large results cannot block the child.
    static func run(_ name: String, _ args: [String]) -> (status: Int32, output: Data)? {
        guard let exe = find(name) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Writes `data` to a temporary file with the given extension and passes its path to `body`.
    static func withTempFile<T>(_ data: Data, ext: String, _ body: (String) -> T) -> T? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("family-ai-\(newID()).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        do { try data.write(to: url) } catch { return nil }
        return body(url.path)
    }
}
