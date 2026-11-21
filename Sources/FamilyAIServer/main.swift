import Foundation
import FamilyAICore

/// `FamilyAIServer --serve [--port N] [--data DIR] [--web DIR] [--keys-file FILE]` runs the
/// server headless (development, tests). Without `--serve` the menu-bar app starts.
let args = CommandLine.arguments

func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--serve") {
    let port = Int(arg("--port") ?? "") ?? 8097
    let data = URL(fileURLWithPath: arg("--data") ?? AppPaths.dataDir.path)
    let web = URL(fileURLWithPath: arg("--web") ?? AppPaths.webRoot.path)
    let keyStore: KeyStore = arg("--keys-file").map { FileKeyStore(url: URL(fileURLWithPath: $0)) } ?? KeychainKeyStore()
    let host = arg("--host") ?? "0.0.0.0"
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let server = try await FamilyServer(config: .init(dataDir: data, webRoot: web, host: host, port: port, keyStore: keyStore),
                                              version: AppPaths.version)
            print("Family AI Server \(AppPaths.version) auf http://\(host):\(port) – Daten: \(data.path)")
            try await server.run()
        } catch {
            FileHandle.standardError.write(Data("Fehler: \(error)\n".utf8))
            exit(1)
        }
        sem.signal()
    }
    sem.wait()
} else {
    FamilyAIMenuBarApp.main()
}
