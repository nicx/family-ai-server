//go:build windows && tray

// Taskbar (notification area) variant of the runner: same program, but no console window.
// A small icon shows the connection state (green = connected, grey = connecting, red = error);
// the menu offers settings, the workspace folder, start at login and quit.
// Only the Win32 API through syscall – no extra packages.
package main

import (
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"unicode/utf16"
	"unsafe"
)

const trayBuild = true

var (
	shell32         = syscall.NewLazyDLL("shell32.dll")
	gdi32           = syscall.NewLazyDLL("gdi32.dll")
	shellNotifyIcon = shell32.NewProc("Shell_NotifyIconW")

	registerClassEx = user32.NewProc("RegisterClassExW")
	createWindowEx  = user32.NewProc("CreateWindowExW")
	defWindowProc   = user32.NewProc("DefWindowProcW")
	getMessage      = user32.NewProc("GetMessageW")
	translateMsg    = user32.NewProc("TranslateMessage")
	dispatchMessage = user32.NewProc("DispatchMessageW")
	postQuitMessage = user32.NewProc("PostQuitMessage")
	createPopupMenu = user32.NewProc("CreatePopupMenu")
	appendMenu      = user32.NewProc("AppendMenuW")
	trackPopupMenu  = user32.NewProc("TrackPopupMenu")
	destroyMenu     = user32.NewProc("DestroyMenu")
	setForeground   = user32.NewProc("SetForegroundWindow")
	getCursorPos    = user32.NewProc("GetCursorPos")
	postMessage     = user32.NewProc("PostMessageW")
	createIcon      = user32.NewProc("CreateIcon")
	getModuleHandle = kernel32.NewProc("GetModuleHandleW")
	createMutex     = kernel32.NewProc("CreateMutexW")
	waitForSingle   = kernel32.NewProc("WaitForSingleObject")
)

const (
	wmDestroy      = 0x0002
	wmNull         = 0x0000
	wmCommand      = 0x0111
	wmLButtonUp    = 0x0202
	wmRButtonUp    = 0x0205
	wmTray         = 0x8001 // WM_APP + 1
	nimAdd         = 0
	nimModify      = 1
	nimDelete      = 2
	nifMessage     = 1
	nifIcon        = 2
	nifTip         = 4
	mfString       = 0
	mfGrayed       = 1
	mfChecked      = 8
	mfSeparator    = 0x800
	tpmRightAlign  = 0x8
	tpmBottomAlign = 0x20
	idSettings     = 1
	idFolder       = 2
	idAutostart    = 3
	idQuit         = 4
	idStatus       = 5
	idUpdate       = 11
	idChat         = 10
	idLog          = 9
	idWrites       = 6
)

type wndClassEx struct {
	size       uint32
	style      uint32
	wndProc    uintptr
	clsExtra   int32
	wndExtra   int32
	instance   uintptr
	icon       uintptr
	cursor     uintptr
	background uintptr
	menuName   *uint16
	className  *uint16
	iconSm     uintptr
}

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	ptX     int32
	ptY     int32
}

type notifyIconData struct {
	size            uint32
	hwnd            uintptr
	id              uint32
	flags           uint32
	callbackMessage uint32
	icon            uintptr
	tip             [128]uint16
	state           uint32
	stateMask       uint32
	info            [256]uint16
	timeout         uint32
	infoTitle       [64]uint16
	infoFlags       uint32
	guid            [16]byte
	balloonIcon     uintptr
}

var (
	trayMu     sync.Mutex
	trayHwnd   uintptr
	trayText   = "Family AI Runner – startet …"
	trayState  = 0 // 0 grey, 1 green, 2 red
	trayIcons  [3]uintptr
	trayConfig Config
)

func u16(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(strings.ReplaceAll(s, "\x00", ""))
	return p
}

// iconFor builds the tray icon (logo + status dot, see trayPixels).
func iconFor(state int) uintptr {
	const n = 32
	xor := trayPixels(state)
	and := make([]byte, n*n/8)
	hInst, _, _ := getModuleHandle.Call(0)
	h, _, _ := createIcon.Call(hInst, n, n, 1, 32, uintptr(unsafe.Pointer(&and[0])), uintptr(unsafe.Pointer(&xor[0])))
	return h
}

func notify(op uintptr) {
	trayMu.Lock()
	defer trayMu.Unlock()
	if trayHwnd == 0 {
		return
	}
	nid := notifyIconData{hwnd: trayHwnd, id: 1, flags: nifMessage | nifIcon | nifTip, callbackMessage: wmTray, icon: trayIcons[trayState]}
	nid.size = uint32(unsafe.Sizeof(nid))
	tip := utf16.Encode([]rune(trayText))
	if len(tip) > 127 {
		tip = tip[:127]
	}
	copy(nid.tip[:], tip)
	shellNotifyIcon.Call(op, uintptr(unsafe.Pointer(&nid)))
}

func setTray(state int, text string) {
	trayMu.Lock()
	trayState, trayText = state, "Family AI Runner – "+text
	trayMu.Unlock()
	notify(nimModify)
}

// trayStatus is called by logf: map the runner's log lines to a state.
func trayStatus(line string) {
	switch {
	case strings.HasPrefix(line, "Verbunden"):
		setTray(1, "verbunden")
	case strings.HasPrefix(line, "Keine Verbindung"):
		setTray(0, "keine Verbindung, neuer Versuch …")
	case strings.HasPrefix(line, "Warte auf Aufgaben"):
		setTray(0, "verbinde …")
	case strings.HasPrefix(line, "Anfrage:"):
		setTray(1, "wartet auf deine Bestätigung")
	}
}

func trayError(msg string) {
	setTray(2, "Fehler")
	messageBox("Family AI Runner", msg, 0x10)
	os.Exit(1)
}

func messageBox(title, text string, flags uintptr) {
	messageBoxW.Call(0, uintptr(unsafe.Pointer(u16(text))), uintptr(unsafe.Pointer(u16(title))), flags|0x10000)
}

func validate(c Config) string {
	if !(strings.HasPrefix(c.Server, "https://") || strings.HasPrefix(c.Server, "http://")) || len(c.Server) < 10 {
		return "Die Adresse muss vollständig sein, z. B. https://ai.example.org"
	}
	if !strings.HasPrefix(c.Token, "fai_dev_") {
		return "Der Schlüssel beginnt mit fai_dev_"
	}
	if _, err := NewWorkspace(c.Workspace); err != nil {
		return err.Error()
	}
	return ""
}

// ---------- start at login (HKCU\...\Run) ----------

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

func autostartOn() bool {
	cmd := exec.Command("reg", "query", runKey, "/v", "FamilyAIRunner")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd.Run() == nil
}

func setAutostart(on bool) {
	exe, _ := os.Executable()
	var cmd *exec.Cmd
	if on {
		cmd = exec.Command("reg", "add", runKey, "/v", "FamilyAIRunner", "/t", "REG_SZ", "/d", `"`+exe+`"`, "/f")
	} else {
		cmd = exec.Command("reg", "delete", runKey, "/v", "FamilyAIRunner", "/f")
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	_ = cmd.Run()
}

// ---------- window + menu ----------

func showMenu(hwnd uintptr) {
	m, _, _ := createPopupMenu.Call()
	defer destroyMenu.Call(m)
	trayMu.Lock()
	status := trayText
	trayMu.Unlock()
	add := func(flags uintptr, id uintptr, text string) {
		appendMenu.Call(m, flags, id, uintptr(unsafe.Pointer(u16(text))))
	}
	checked := func(on bool) uintptr {
		if on {
			return mfString | mfChecked
		}
		return mfString
	}
	add(mfString|mfGrayed, idStatus, status)
	add(mfSeparator, 0, "")
	add(mfString, idSettings, "Einstellungen …")
	add(mfString, idFolder, "Arbeitsordner öffnen")
	add(mfString, idLog, "Protokoll anzeigen")
	add(mfString, idUpdate, "Nach Updates suchen")
	add(mfSeparator, 0, "")
	add(checked(!trayConfig.AllowWrites), idWrites, "Auch vor dem Schreiben von Dateien nachfragen")
	add(checked(trayConfig.ApproveInChat), idChat, "Freigabe im Chat statt als Popup")
	add(mfSeparator, 0, "")
	auto := uintptr(mfString)
	if autostartOn() {
		auto |= mfChecked
	}
	add(auto, idAutostart, "Beim Anmelden starten")
	add(mfSeparator, 0, "")
	add(mfString, idQuit, "Beenden")
	var pt struct{ x, y int32 }
	getCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	setForeground.Call(hwnd)
	trackPopupMenu.Call(m, tpmRightAlign|tpmBottomAlign, uintptr(pt.x), uintptr(pt.y), 0, hwnd, 0)
	postMessage.Call(hwnd, wmNull, 0, 0)
}

func wndProc(hwnd, message, wParam, lParam uintptr) uintptr {
	switch uint32(message) {
	case wmTray:
		if lParam == wmRButtonUp || lParam == wmLButtonUp {
			showMenu(hwnd)
		}
		return 0
	case wmCommand:
		switch wParam & 0xffff {
		case idSettings:
			go func() {
				if n, ok := editSettings(trayConfig); ok {
					_ = saveConfig(n)
					restart()
				}
			}()
		case idChat:
			n := trayConfig
			n.ApproveInChat = !n.ApproveInChat
			go func() { _ = saveConfig(n); restart() }()
		case idWrites:
			n := trayConfig
			n.AllowWrites = !n.AllowWrites
			go func() { _ = saveConfig(n); restart() }()
		case idUpdate:
			triggerUpdateCheck()
		case idLog:
			writeLog("Protokoll geöffnet") // makes sure the file exists
			_ = exec.Command("notepad.exe", logPath()).Start()
		case idFolder:
			_ = exec.Command("explorer.exe", trayConfig.Workspace).Start()
		case idAutostart:
			setAutostart(!autostartOn())
		case idQuit:
			go func() {
				setTray(0, "wird beendet …")
				trayMu.Lock()
				data := notifyIconData{hwnd: trayHwnd, id: 1}
				data.size = uint32(unsafe.Sizeof(data))
				trayMu.Unlock()
				shellNotifyIcon.Call(nimDelete, uintptr(unsafe.Pointer(&data)))
				shutdown()
			}()
		}
		return 0
	case wmDestroy:
		postQuitMessage.Call(0)
		return 0
	}
	r, _, _ := defWindowProc.Call(hwnd, message, wParam, lParam)
	return r
}

func init() {
	updateReport = func(msg string) { go messageBox("Family AI Runner", msg, 0x40) } // MB_ICONINFORMATION
}

// restart starts a fresh copy (it waits for the single-instance lock) and signs off this one.
func restart() {
	exe, err := os.Executable()
	if err == nil {
		_ = exec.Command(exe).Start()
	}
	shutdown()
}

func trayMain(c Config, forceSetup bool) {
	runtime.LockOSThread() // window and message loop must stay on one thread
	// Single instance: a second start (e.g. double-click while running) just ends.
	h, _, err := createMutex.Call(0, 1, uintptr(unsafe.Pointer(u16("Local\\FamilyAIRunnerTray"))))
	if err == syscall.Errno(183) { // ERROR_ALREADY_EXISTS
		// Restart case: the old copy releases the mutex when its process ends.
		r, _, _ := waitForSingle.Call(h, 6000)
		if r != 0 && r != 0x80 { // not signalled/abandoned → really running
			return
		}
	}

	needSetup := forceSetup || validate(c) != ""
	trayConfig = c
	writeLog("Tray-App gestartet (Einrichtung nötig: " + map[bool]string{true: "ja", false: "nein"}[needSetup] + ")")

	hInst, _, _ := getModuleHandle.Call(0)
	for i := range trayIcons {
		trayIcons[i] = iconFor(i)
	}
	class := u16("FamilyAIRunnerTray")
	wc := wndClassEx{wndProc: syscall.NewCallback(wndProc), instance: hInst, className: class}
	wc.size = uint32(unsafe.Sizeof(wc))
	if r, _, e := registerClassEx.Call(uintptr(unsafe.Pointer(&wc))); r == 0 {
		writeLog("RegisterClassEx fehlgeschlagen: " + e.Error())
	}
	hwnd, _, e := createWindowEx.Call(0, uintptr(unsafe.Pointer(class)), uintptr(unsafe.Pointer(u16("Family AI Runner"))), 0, 0, 0, 0, 0, 0, 0, hInst, 0)
	if hwnd == 0 {
		writeLog("CreateWindowEx fehlgeschlagen: " + e.Error())
	}
	trayMu.Lock()
	trayHwnd = hwnd
	trayMu.Unlock()
	if needSetup {
		setTray(0, "Einrichtung nötig – Rechtsklick, Einstellungen")
	}
	notify(nimAdd)

	if needSetup {
		// Das Symbol ist schon da; die Eingabefenster kommen im Hintergrund.
		go func() {
			n, ok := editSettings(c)
			if !ok {
				writeLog("Einrichtung abgebrochen")
				setTray(2, "nicht eingerichtet – Rechtsklick, Einstellungen")
				return
			}
			_ = saveConfig(n)
			restart()
		}()
	} else {
		go serve(c)
	}

	var m msg
	for {
		r, _, _ := getMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		translateMsg.Call(uintptr(unsafe.Pointer(&m)))
		dispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
	}
}

// trayReauth: the server no longer accepts the saved device key (device deleted, new server, key rotated).
// Instead of quitting with a hint about command-line options, open the settings window with the key cleared.
func trayReauth(c Config) bool {
	logf("Geräteschlüssel wird vom Server nicht akzeptiert – Einstellungen werden geöffnet.")
	setTray(2, "Schlüssel ungültig – Rechtsklick, Einstellungen")
	go func() {
		messageBox("Family AI Runner", "Der Server akzeptiert den gespeicherten Geräteschlüssel nicht (Gerät gelöscht oder Schlüssel erneuert).\n\nBitte einen neuen eintragen: Web-App → Einstellungen → Computer.", 0x30)
		c.Token = ""
		if n, ok := editSettings(c); ok {
			_ = saveConfig(n)
			restart()
		}
	}()
	return true
}
