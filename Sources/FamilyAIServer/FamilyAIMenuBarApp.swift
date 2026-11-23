#if canImport(SwiftUI)
import SwiftUI
import ServiceManagement
import FamilyAICore

/// Menu-bar settings (stored in UserDefaults; everything family-related lives in the web admin).
@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("port") var port: Int = 8097
    @AppStorage("host") var host: String = "0.0.0.0"
    @AppStorage("autoStartServer") var autoStartServer: Bool = true
    @AppStorage("backupEnabled") var backupEnabled: Bool = true
    @AppStorage("backupKeep") var backupKeep: Int = 14
    @AppStorage("backupDir") var backupDir: String = ""
    @Published var loginItem: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard loginItem != (SMAppService.mainApp.status == .enabled) else { return }
            do { if loginItem { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { loginItem = SMAppService.mainApp.status == .enabled }
        }
    }

    var backupURL: URL {
        backupDir.trimmingCharacters(in: .whitespaces).isEmpty ? AppPaths.backupsDir : URL(fileURLWithPath: backupDir)
    }
}

@MainActor
final class ServerController: ObservableObject {
    enum Status: Equatable { case stopped, starting, running, failed(String) }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastBackup: Date?
    @Published private(set) var lastBackupError: String?
    private var task: Task<Void, Never>?
    let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    var url: URL { URL(string: "http://localhost:\(settings.port)")! }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: AppPaths.logFile) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: AppPaths.logFile, atomically: true, encoding: .utf8)
        }
    }

    func start() {
        guard task == nil else { return }
        status = .starting
        let port = settings.port, host = settings.host
        log("Starte Server auf \(host):\(port)")
        task = Task {
            do {
                let server = try await FamilyServer(config: .init(dataDir: AppPaths.dataDir, webRoot: AppPaths.webRoot,
                                                                host: host, port: port, keyStore: KeychainKeyStore()),
                                                  version: AppPaths.version)
                status = .running
                try await server.run()
                status = .stopped
            } catch is CancellationError {
                status = .stopped
            } catch {
                log("Serverfehler: \(error)")
                status = .failed("\(error)")
            }
            task = nil
        }
    }

    func stop() async {
        guard let t = task else { return }
        log("Stoppe Server")
        t.cancel()
        _ = await t.value
        task = nil
        status = .stopped
    }

    func restart() { Task { await stop(); start() } }

    /// For targets under /Volumes/<name>: that volume must really be mounted. Otherwise
    /// creating the folder would put a local directory at the mount point (filling the
    /// boot disk, and the share would later mount as "<name>-1").
    nonisolated static func volumeProblem(_ url: URL) -> String? {
        let comps = url.standardizedFileURL.pathComponents
        guard comps.count >= 3, comps[0] == "/", comps[1] == "Volumes" else { return nil }
        let volume = "/Volumes/" + comps[2]
        var st = statfs()
        guard statfs(volume, &st) == 0 else { return "\(volume) ist nicht eingehängt" }
        let mountedOn = withUnsafeBytes(of: &st.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return mountedOn == volume ? nil : "\(volume) ist nicht eingehängt"
    }

    /// Copies the data folder (server stopped for a consistent SQLite snapshot).
    func backup() async -> Bool {
        let fm = FileManager.default
        let dir = settings.backupURL
        if let problem = Self.volumeProblem(dir) {
            log("Backup übersprungen: \(problem)")
            lastBackupError = problem
            return false
        }
        let wasRunning = task != nil
        if wasRunning { await stop() }
        defer { if wasRunning { start() } }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            log("Backup fehlgeschlagen: \(error)"); lastBackupError = "Ordner nicht anlegbar"; return false
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm"
        let dest = dir.appendingPathComponent("family-ai-\(df.string(from: Date()))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [AppPaths.dataDir.path, dest.path]
        do { try p.run(); p.waitUntilExit() } catch {
            log("Backup fehlgeschlagen: \(error)"); lastBackupError = "\(error)"; return false
        }
        guard p.terminationStatus == 0 else {
            log("Backup fehlgeschlagen (ditto \(p.terminationStatus))"); lastBackupError = "Kopieren fehlgeschlagen"; return false
        }
        // Rotate
        let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("family-ai-") }.sorted()
        for old in all.dropLast(max(1, settings.backupKeep)) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        lastBackup = Date()
        lastBackupError = nil
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastBackupAt")
        log("Backup erstellt: \(dest.path)")
        return true
    }

    /// Daily backup in the 3 o'clock hour; checks every 10 minutes, so a failed run
    /// (e.g. NAS not mounted yet) is retried a few times within that hour.
    func scheduleBackups() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                let last = UserDefaults.standard.double(forKey: "lastBackupAt")
                if settings.backupEnabled, Date().timeIntervalSince1970 - last > 20 * 3600,
                   Calendar.current.component(.hour, from: Date()) == 3 {
                    _ = await backup()
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var server = ServerController(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if settings.autoStartServer { server.start() }
        server.scheduleBackups()
    }

    func applicationWillTerminate(_ notification: Notification) {}
}

struct FamilyAIMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(server: delegate.server, settings: delegate.settings)
        } label: {
            if case .failed = delegate.server.status {
                Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Family AI Server")
            } else {
                Image(nsImage: AppMark.image(filled: delegate.server.status == .running)).accessibilityLabel("Family AI Server")
            }
        }
        Settings {
            SettingsView(server: delegate.server, settings: delegate.settings)
        }
    }
}

/// Menu bar mark: two overlapping circles (the app icon as a template image).
/// Filled overlap = server running, outlines only = stopped/starting.
enum AppMark {
    static func image(filled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 14), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let r: CGFloat = 5.2, y: CGFloat = 7
            let left = NSBezierPath(ovalIn: NSRect(x: 10 - 3.4 - r, y: y - r, width: r * 2, height: r * 2))
            let right = NSBezierPath(ovalIn: NSRect(x: 10 + 3.4 - r, y: y - r, width: r * 2, height: r * 2))
            if filled {
                NSGraphicsContext.saveGraphicsState()
                left.addClip(); right.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            for p in [left, right] { p.lineWidth = 1.5; p.stroke() }
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct MenuContent: View {
    @ObservedObject var server: ServerController
    @ObservedObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusText)
        if let e = server.lastBackupError { Text("Sicherung: \(e)") }
        else if let d = server.lastBackup { Text("Letzte Sicherung: \(d.formatted(date: .abbreviated, time: .shortened)) → \(settings.backupURL.path)") }
        Divider()
        Button("Family AI Server öffnen") { NSWorkspace.shared.open(server.url) }
            .disabled(server.status != .running)
        Divider()
        if server.status == .running || server.status == .starting {
            Button("Server stoppen") { Task { await server.stop() } }
            Button("Server neu starten") { server.restart() }
        } else {
            Button("Server starten") { server.start() }
        }
        Button("Jetzt sichern") { Task { _ = await server.backup() } }
        Button("Protokoll anzeigen") { NSWorkspace.shared.open(AppPaths.logFile) }
        Divider()
        Button("Einstellungen …") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button("Beenden") {
            Task { await server.stop(); NSApp.terminate(nil) }
        }
    }

    var statusText: String {
        switch server.status {
        case .running: return "Läuft auf Port \(settings.port)"
        case .starting: return "Startet …"
        case .stopped: return "Gestoppt"
        case .failed(let e): return "Fehler: \(e.prefix(60))"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var server: ServerController
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Server") {
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                TextField("Adresse (0.0.0.0 = alle Netzwerke)", text: $settings.host)
                Toggle("Server beim App-Start starten", isOn: $settings.autoStartServer)
                Toggle("Beim Anmelden starten", isOn: $settings.loginItem)
                Button("Übernehmen und neu starten") { server.restart() }
            }
            Section("Sicherung") {
                Toggle("Täglich um 3 Uhr sichern", isOn: $settings.backupEnabled)
                Stepper("Aufbewahren: \(settings.backupKeep)", value: $settings.backupKeep, in: 1...90)
                TextField("Ordner (leer = Standard)", text: $settings.backupDir)
                Text("Standard: \(AppPaths.backupsDir.path). Netzlaufwerke unter /Volumes werden nur beschrieben, wenn sie eingehängt sind.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hinweis") {
                Text("Personen, Schlüssel, Modelle und alle Familien-Einstellungen verwaltest du in der Web-Oberfläche unter „Verwaltung“.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
#endif
