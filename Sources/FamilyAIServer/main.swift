import Foundation
import FamilyAICore

/// `FamilyAIServer --serve [--port N] [--host H] [--data DIR] [--web DIR] [--keys-file FILE]` runs the
/// server headless (development, tests, Docker). Without `--serve` the macOS menu-bar app starts;
/// on Linux the server always runs headless and reads FAMILY_AI_PORT / FAMILY_AI_HOST from the environment.
let args = CommandLine.arguments

func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func envValue(_ name: String) -> String? {
    let v = ProcessInfo.processInfo.environment[name] ?? ""
    return v.isEmpty ? nil : v
}

#if os(macOS)
let headless = args.contains("--serve")
#else
let headless = true
#endif

if headless {
    let port = Int(arg("--port") ?? envValue("FAMILY_AI_PORT") ?? "") ?? 8097
    let data = URL(fileURLWithPath: arg("--data") ?? AppPaths.dataDir.path)
    let web = URL(fileURLWithPath: arg("--web") ?? AppPaths.webRoot.path)
    #if os(macOS)
    let keyStore: KeyStore = arg("--keys-file").map { FileKeyStore(url: URL(fileURLWithPath: $0)) } ?? KeychainKeyStore()
    #else
    // Docker: keys live encrypted in the data volume; the master key comes from a secret or the environment.
    guard let master = EncryptedKeyStore.masterKey() else {
        FileHandle.standardError.write(Data("""
        Fehler: kein Master-Schlüssel. Setze FAMILY_AI_MASTER_KEY_FILE (Docker Secret) oder FAMILY_AI_MASTER_KEY.
        Einen neuen erzeugen: openssl rand -base64 32  (und sicher aufbewahren, getrennt von den Daten)

        """.utf8))
        exit(1)
    }
    let encrypted: EncryptedKeyStore
    do { encrypted = try EncryptedKeyStore(url: data.appendingPathComponent("keys.enc"), masterKey: master) }
    catch { FileHandle.standardError.write(Data("Fehler: \(error)\n".utf8)); exit(1) }
    if encrypted.isLocked {
        FileHandle.standardError.write(Data("""
        Fehler: keys.enc lässt sich mit diesem Master-Schlüssel nicht entschlüsseln (falscher oder geänderter Schlüssel).
        Mit dem richtigen Schlüssel neu starten. Ist er verloren: keys.enc löschen und die OpenRouter-Schlüssel neu eintragen.

        """.utf8))
        exit(1)
    }
    let keyStore: KeyStore = encrypted
    #endif
    let host = arg("--host") ?? envValue("FAMILY_AI_HOST") ?? "0.0.0.0"
    var trusted: [IPRange] = []
    if let t = envValue("FAMILY_AI_TRUSTED_PROXIES") {
        guard let list = IPRange.list(t) else {
            FileHandle.standardError.write(Data("Fehler: FAMILY_AI_TRUSTED_PROXIES enthält eine ungültige Adresse (erlaubt: IP oder CIDR, z. B. 172.18.0.0/16)\n".utf8))
            exit(1)
        }
        trusted = list
    }
    #if os(macOS)
    let requireSetupCode = false
    #else
    let requireSetupCode = true
    #endif
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let server = try await FamilyServer(config: .init(dataDir: data, webRoot: web, host: host, port: port, keyStore: keyStore, trustedProxies: trusted, requireSetupCode: requireSetupCode),
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
    #if os(macOS)
    FamilyAIMenuBarApp.main()
    #endif
}
