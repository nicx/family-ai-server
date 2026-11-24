// Family AI Runner – Menüleisten-App für macOS.
// Startet das mitgelieferte Runner-Programm im Hintergrund, zeigt den Verbindungsstatus an
// und fragt Adresse, Schlüssel und Arbeitsordner in einem Fenster ab (kein Terminal nötig).
import AppKit
import ServiceManagement

enum State { case stopped, connecting, connected, waiting, failed }

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
    let autostartItem = NSMenuItem(title: "Beim Anmelden starten", action: #selector(toggleAutostart), keyEquivalent: "")
    var process: Process?
    var state = State.stopped
    var detail = "Angehalten"
    var wantsRun = true
    var buffer = Data()

    // Wie der Runner selbst: $HOME/Library/Application Support/FamilyAIRunner/config.json
    let configURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/FamilyAIRunner/config.json")

    // Menüleisten-Apps haben kein Hauptmenü – ohne Bearbeiten-Menü gehen Cmd+C/V/X/A in Textfeldern nicht.
    func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Family AI Runner beenden", action: #selector(quit), keyEquivalent: "q").target = self
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Bearbeiten"); editItem.submenu = edit
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        installEditMenu()
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        let settings = NSMenuItem(title: "Einstellungen …", action: #selector(editSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let log = NSMenuItem(title: "Protokoll anzeigen", action: #selector(showLog), keyEquivalent: "l")
        log.target = self
        menu.addItem(log)
        let folder = NSMenuItem(title: "Arbeitsordner im Finder zeigen", action: #selector(showFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        autostartItem.target = self
        menu.addItem(autostartItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Family AI Runner beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        refresh()
        if config() == nil { editSettings() } else { start() }
    }

    // MARK: Konfiguration

    func config() -> [String: Any]? {
        guard let d = try? Data(contentsOf: configURL),
              let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = c["server"] as? String, s.hasPrefix("http"),
              (c["token"] as? String)?.hasPrefix("fai_dev_") == true,
              let w = c["workspace"] as? String, FileManager.default.fileExists(atPath: w) else { return nil }
        return c
    }

    func save(server: String, token: String, workspace: String, confirmWrites: Bool, approveInChat: Bool) {
        var c = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]) ?? [:]
        c["server"] = server; c["token"] = token; c["workspace"] = workspace
        c.removeValue(forKey: "confirmWrites") // alter Schlüssel
        if confirmWrites { c.removeValue(forKey: "allowWrites") } else { c["allowWrites"] = true }
        if approveInChat { c["approveInChat"] = true } else { c.removeValue(forKey: "approveInChat") }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let d = try? JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: configURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
    }

    // MARK: Runner-Prozess

    func start() {
        guard process == nil, config() != nil,
              let exe = Bundle.main.resourceURL?.appendingPathComponent("family-ai-runner") else { return }
        wantsRun = true
        let p = Process()
        p.executableURL = exe
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.ended(proc) }
        }
        do { try p.run() } catch {
            set(.failed, "Start nicht möglich: \(error.localizedDescription)"); return
        }
        process = p
        set(.connecting, "Verbinde …")
    }

    func stop() {
        wantsRun = false
        process?.terminate() // SIGTERM: der Runner meldet sich beim Server ab
        if process == nil { set(.stopped, "Angehalten") }
    }

    func ended(_ p: Process) {
        guard p === process else { return }
        process = nil
        if wantsRun && state != .failed {
            set(.failed, "Runner beendet (Code \(p.terminationStatus))")
        } else if !wantsRun {
            set(.stopped, "Angehalten")
        }
    }

    func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    func handle(_ raw: String) {
        // Zeitstempel "15:04:05 " vorn abschneiden
        let line = raw.range(of: #"^\d\d:\d\d:\d\d "#, options: .regularExpression).map { String(raw[$0.upperBound...]) } ?? raw
        if line.hasPrefix("Verbunden") { set(.connected, "Verbunden") }
        else if line.hasPrefix("Keine Verbindung") { set(.connecting, "Keine Verbindung – neuer Versuch …") }
        else if line.hasPrefix("Anfrage:") { set(.waiting, "Wartet auf deine Bestätigung") }
        else if line.hasPrefix("Fehler:") { set(.failed, String(line.dropFirst(8))) }
        else if state == .waiting, line.hasPrefix("→") { set(.connected, "Verbunden") }
    }

    func set(_ s: State, _ text: String) { state = s; detail = text; refresh() }

    func refresh() {
        let symbol: String
        switch state {
        case .connected: symbol = "chevron.left.forwardslash.chevron.right"
        case .waiting: symbol = "exclamationmark.bubble"
        case .failed: symbol = "exclamationmark.triangle"
        case .connecting: symbol = "arrow.triangle.2.circlepath"
        case .stopped: symbol = "pause.circle"
        }
        if let b = item.button {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Family AI Runner")
            b.image?.isTemplate = true
            b.toolTip = "Family AI Runner – \(detail)"
        }
        statusLine.title = "Family AI Runner – \(detail)"
        toggleItem.title = process == nil ? "Starten" : "Anhalten"
    }

    func menuWillOpen(_ menu: NSMenu) {
        autostartItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Aktionen

    @objc func toggle() {
        if process == nil {
            if config() == nil { editSettings() } else { start() }
        } else { stop() }
    }

    @objc func showLog() {
        let url = configURL.deletingLastPathComponent().appendingPathComponent("runner.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(url)
    }

    @objc func showFolder() {
        if let w = config()?["workspace"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: w)) }
    }

    @objc func toggleAutostart() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Autostart nicht möglich"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    @objc func quit() {
        wantsRun = false
        if let p = process {
            p.terminationHandler = { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
            p.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.terminate(nil) }
        } else { NSApp.terminate(nil) }
    }

    var fields: [NSTextField] = []
    var checks: [NSButton] = []

    @objc func editSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let c = config() ?? (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]) ?? [:]
        let labels = ["Adresse des Servers", "Geräteschlüssel", "Arbeitsordner"]
        let values = [c["server"], c["token"], c["workspace"]].map { $0 as? String ?? "" }
        let hints = ["https://ai.example.org", "fai_dev_…", "/Users/…/Projekte/spiel"]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 236))
        fields = []
        for i in 0..<3 {
            let y = CGFloat(196 - i * 50)
            let l = NSTextField(labelWithString: labels[i]); l.frame = NSRect(x: 0, y: y + 22, width: 380, height: 17)
            let f = NSTextField(frame: NSRect(x: 0, y: y, width: i == 2 ? 290 : 380, height: 24))
            f.stringValue = values[i]; f.placeholderString = hints[i]
            box.addSubview(l); box.addSubview(f); fields.append(f)
        }
        let pick = NSButton(title: "Wählen …", target: self, action: #selector(pickFolder))
        pick.frame = NSRect(x: 295, y: 94, width: 85, height: 28)
        pick.bezelStyle = .rounded
        box.addSubview(pick)
        let writes = NSButton(checkboxWithTitle: "Auch vor dem Schreiben von Dateien nachfragen", target: nil, action: nil)
        writes.frame = NSRect(x: 0, y: 56, width: 380, height: 20)
        writes.state = (c["allowWrites"] as? Bool) == true ? .off : .on
        box.addSubview(writes)
        let chat = NSButton(checkboxWithTitle: "Freigabe im Chat statt als Popup", target: nil, action: nil)
        chat.frame = NSRect(x: 0, y: 30, width: 380, height: 20)
        chat.state = (c["approveInChat"] as? Bool) == true ? .on : .off
        box.addSubview(chat)
        checks = [writes, chat]
        let a = NSAlert()
        a.messageText = "Family AI Runner einrichten"
        a.informativeText = "Die Werte stehen in der Web-App unter Einstellungen → Computer."
        a.accessoryView = box
        a.addButton(withTitle: "Speichern")
        a.addButton(withTitle: "Abbrechen")
        a.window.initialFirstResponder = fields[0]
        while a.runModal() == .alertFirstButtonReturn {
            let s = fields[0].stringValue.trimmingCharacters(in: .whitespaces)
            let t = fields[1].stringValue.trimmingCharacters(in: .whitespaces)
            let w = fields[2].stringValue.trimmingCharacters(in: .whitespaces)
            var isDir: ObjCBool = false
            var problem: String?
            if URL(string: s)?.host == nil || !s.hasPrefix("http") { problem = "Die Adresse muss vollständig sein, z. B. https://ai.example.org" }
            else if !t.hasPrefix("fai_dev_") { problem = "Der Schlüssel beginnt mit fai_dev_" }
            else if !FileManager.default.fileExists(atPath: w, isDirectory: &isDir) || !isDir.boolValue { problem = "Den Arbeitsordner gibt es nicht." }
            if let problem {
                let e = NSAlert(); e.messageText = problem; e.runModal()
                continue
            }
            save(server: s, token: t, workspace: w, confirmWrites: checks[0].state == .on, approveInChat: checks[1].state == .on)
            if let p = process {
                p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.process = nil; self?.start() } }
                p.terminate()
            } else { start() }
            return
        }
        if process == nil && config() == nil { set(.stopped, "Nicht eingerichtet") }
    }

    @objc func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Wählen"
        if p.runModal() == .OK, let u = p.url { fields[2].stringValue = u.path }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
