import Foundation

enum AppPaths {
    #if os(macOS)
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Family AI Server", isDirectory: true)
    }()
    static var dataDir: URL { supportDir.appendingPathComponent("data", isDirectory: true) }
    static var backupsDir: URL { supportDir.appendingPathComponent("backups", isDirectory: true) }
    static var logFile: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/Family AI Server", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("family-ai-server.log")
    }

    /// Web app: bundled under Contents/Resources/Web, else ./Web next to the package (swift run).
    static var webRoot: URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Web"), FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Web")
    }

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0-dev"
    }
    #else
    // Linux / Docker: everything comes from the environment (see docker/ in the repository).
    private static func env(_ name: String) -> String? {
        let v = ProcessInfo.processInfo.environment[name] ?? ""
        return v.isEmpty ? nil : v
    }
    static var dataDir: URL { URL(fileURLWithPath: env("FAMILY_AI_DATA") ?? "/data") }
    static var webRoot: URL { URL(fileURLWithPath: env("FAMILY_AI_WEB") ?? "/app/Web") }
    static var version: String { env("FAMILY_AI_VERSION") ?? "0.1.0-dev" }
    #endif
}
