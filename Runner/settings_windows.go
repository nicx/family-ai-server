//go:build windows && tray

// Settings window of the Windows tray app: a real window with fields for address, device key and
// workspace folder, the two safety switches and a "test connection" button.
// Pure Win32 through syscall (no PowerShell, no extra packages).
package main

import (
	"crypto/tls"
	"errors"
	"fmt"
	"net/http"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"unsafe"
)

var (
	ole32  = syscall.NewLazyDLL("ole32.dll")
	coInit = ole32.NewProc("CoInitializeEx")
	coFree = ole32.NewProc("CoTaskMemFree")

	browseForFolder = shell32.NewProc("SHBrowseForFolderW")
	pathFromIDList  = shell32.NewProc("SHGetPathFromIDListW")

	createFont      = gdi32.NewProc("CreateFontW")
	deleteObject    = gdi32.NewProc("DeleteObject")
	sendMessage     = user32.NewProc("SendMessageW")
	getWindowText   = user32.NewProc("GetWindowTextW")
	getTextLength   = user32.NewProc("GetWindowTextLengthW")
	setWindowText   = user32.NewProc("SetWindowTextW")
	destroyWindow   = user32.NewProc("DestroyWindow")
	showWindow      = user32.NewProc("ShowWindow")
	isDialogMessage = user32.NewProc("IsDialogMessageW")
	enableWindow    = user32.NewProc("EnableWindow")
	getSystemMetric = user32.NewProc("GetSystemMetrics")
	adjustWindow    = user32.NewProc("AdjustWindowRectEx")
	loadCursor      = user32.NewProc("LoadCursorW")
	setFocus        = user32.NewProc("SetFocus")
)

const (
	wsChild       = 0x40000000
	wsVisible     = 0x10000000
	wsTabstop     = 0x00010000
	wsCaptionSys  = 0x00C00000 | 0x00080000 // WS_CAPTION | WS_SYSMENU
	wsExTopmost   = 0x00000008
	wsExClient    = 0x00000200
	esAutoHScroll = 0x80
	bsDefPush     = 1
	bsAutoCheck   = 3
	wmSetFont     = 0x0030
	wmClose       = 0x0010
	bmGetCheck    = 0x00F0
	bmSetCheck    = 0x00F1
	wmTestDone    = 0x8002 // WM_APP + 2

	idOK     = 1 // Speichern (Standardknopf: Enter)
	idCancel = 2 // Abbrechen (Esc)
	idBrowse = 101
	idTest   = 102
)

// settingsUI is the state of the one settings window (only one can be open).
type settingsUI struct {
	hwnd                                                 uintptr
	server, token, folder, chkWrites, chkChat, chkUpdate uintptr
	status, btnTest                                      uintptr
	font                                                 uintptr
	base, result                                         Config
	ok                                                   bool
	testText                                             string
}

var (
	sui          *settingsUI
	settingsMu   sync.Mutex
	settingsOpen bool
	settingsOnce sync.Once
	settingsProc = syscall.NewCallback(settingsWndProc)
	browseProc   = syscall.NewCallback(browseCallback)
	browseStart  *uint16
)

// editSettings opens the settings window and returns the new values (ok = saved).
// It runs its own message loop on its own thread, so it can be called from any goroutine.
func editSettings(c Config) (Config, bool) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	settingsMu.Lock()
	if settingsOpen {
		h := uintptr(0)
		if sui != nil {
			h = sui.hwnd
		}
		settingsMu.Unlock()
		if h != 0 {
			setForeground.Call(h)
		}
		return c, false
	}
	settingsOpen = true
	settingsMu.Unlock()
	defer func() {
		settingsMu.Lock()
		settingsOpen, sui = false, nil
		settingsMu.Unlock()
	}()

	hInst, _, _ := getModuleHandle.Call(0)
	class := u16("FamilyAIRunnerSettings")
	settingsOnce.Do(func() {
		cursor, _, _ := loadCursor.Call(0, 32512)                                                                  // IDC_ARROW
		wc := wndClassEx{wndProc: settingsProc, instance: hInst, className: class, cursor: cursor, background: 16, // COLOR_BTNFACE + 1
			icon: trayIcons[1], iconSm: trayIcons[1]}
		wc.size = uint32(unsafe.Sizeof(wc))
		if r, _, e := registerClassEx.Call(uintptr(unsafe.Pointer(&wc))); r == 0 {
			writeLog("RegisterClassEx (Einstellungen) fehlgeschlagen: " + e.Error())
		}
	})

	ui := &settingsUI{base: c}
	settingsMu.Lock()
	sui = ui
	settingsMu.Unlock()

	// Segoe UI 9 pt
	ui.font, _, _ = createFont.Call(^uintptr(11), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, uintptr(unsafe.Pointer(u16("Segoe UI"))))
	defer deleteObject.Call(ui.font)

	// Window sized so that the client area is 480 x 322, centred on the screen.
	const cw, ch = 480, 348
	style := uintptr(wsCaptionSys)
	rc := struct{ l, t, r, b int32 }{0, 0, cw, ch}
	adjustWindow.Call(uintptr(unsafe.Pointer(&rc)), style, 0, wsExTopmost)
	w, h := int(rc.r-rc.l), int(rc.b-rc.t)
	sx, _, _ := getSystemMetric.Call(0)
	sy, _, _ := getSystemMetric.Call(1)
	x, y := (int(sx)-w)/2, (int(sy)-h)/2
	if x < 0 {
		x = 0
	}
	if y < 0 {
		y = 0
	}
	hwnd, _, e := createWindowEx.Call(wsExTopmost, uintptr(unsafe.Pointer(class)), uintptr(unsafe.Pointer(u16("Family AI Runner – Einstellungen"))),
		style, uintptr(x), uintptr(y), uintptr(w), uintptr(h), 0, 0, hInst, 0)
	if hwnd == 0 {
		writeLog("CreateWindowEx (Einstellungen) fehlgeschlagen: " + e.Error())
		return c, false
	}
	ui.hwnd = hwnd

	label := func(text string, x, y, w, h int) uintptr {
		return ui.control("STATIC", text, 0, 0, x, y, w, h, 0)
	}
	label("Adresse des Servers, z. B. https://ai.example.org", 16, 14, 448, 18)
	ui.server = ui.control("EDIT", c.Server, wsTabstop|esAutoHScroll, wsExClient, 16, 34, 448, 24, 111)
	label("Geräteschlüssel (Web-App: Einstellungen → Computer, beginnt mit fai_dev_)", 16, 68, 448, 18)
	ui.token = ui.control("EDIT", c.Token, wsTabstop|esAutoHScroll, wsExClient, 16, 88, 448, 24, 112)
	label("Arbeitsordner (nur hier darf die KI arbeiten)", 16, 122, 448, 18)
	ui.folder = ui.control("EDIT", c.Workspace, wsTabstop|esAutoHScroll, wsExClient, 16, 142, 340, 24, 113)
	ui.control("BUTTON", "Durchsuchen …", wsTabstop, 0, 364, 141, 100, 26, idBrowse)
	ui.chkWrites = ui.control("BUTTON", "Auch vor dem Schreiben von Dateien nachfragen", wsTabstop|bsAutoCheck, 0, 16, 182, 448, 20, 121)
	ui.chkChat = ui.control("BUTTON", "Freigabe im Chat statt als Popup auf diesem Computer", wsTabstop|bsAutoCheck, 0, 16, 206, 448, 20, 122)
	ui.chkUpdate = ui.control("BUTTON", "Automatisch aktualisieren (neue Version vom Server holen)", wsTabstop|bsAutoCheck, 0, 16, 230, 448, 20, 123)
	setCheck(ui.chkWrites, !c.AllowWrites)
	setCheck(ui.chkChat, c.ApproveInChat)
	setCheck(ui.chkUpdate, !c.NoAutoUpdate)
	ui.btnTest = ui.control("BUTTON", "Verbindung testen", wsTabstop, 0, 16, 266, 140, 26, idTest)
	ui.status = ui.control("STATIC", "", 0, 0, 168, 264, 296, 34, 0)
	ui.control("BUTTON", "Speichern", wsTabstop|bsDefPush, 0, 284, 310, 88, 28, idOK)
	ui.control("BUTTON", "Abbrechen", wsTabstop, 0, 376, 310, 88, 28, idCancel)

	showWindow.Call(hwnd, 5) // SW_SHOW
	setForeground.Call(hwnd)
	setFocus.Call(ui.server)

	var m msg
	for {
		r, _, _ := getMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		if handled, _, _ := isDialogMessage.Call(hwnd, uintptr(unsafe.Pointer(&m))); handled != 0 {
			continue
		}
		translateMsg.Call(uintptr(unsafe.Pointer(&m)))
		dispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
	}
	if !ui.ok {
		return c, false
	}
	return ui.result, true
}

func (ui *settingsUI) control(class, text string, style, exStyle uintptr, x, y, w, h int, id uintptr) uintptr {
	hInst, _, _ := getModuleHandle.Call(0)
	hwnd, _, _ := createWindowEx.Call(exStyle, uintptr(unsafe.Pointer(u16(class))), uintptr(unsafe.Pointer(u16(text))),
		style|wsChild|wsVisible, uintptr(x), uintptr(y), uintptr(w), uintptr(h), ui.hwnd, id, hInst, 0)
	sendMessage.Call(hwnd, wmSetFont, ui.font, 1)
	return hwnd
}

func setCheck(h uintptr, on bool) {
	v := uintptr(0)
	if on {
		v = 1
	}
	sendMessage.Call(h, bmSetCheck, v, 0)
}

func isChecked(h uintptr) bool {
	r, _, _ := sendMessage.Call(h, bmGetCheck, 0, 0)
	return r == 1
}

func getText(h uintptr) string {
	n, _, _ := getTextLength.Call(h)
	buf := make([]uint16, n+1)
	getWindowText.Call(h, uintptr(unsafe.Pointer(&buf[0])), n+1)
	return strings.TrimSpace(syscall.UTF16ToString(buf))
}

func setText(h uintptr, s string) {
	setWindowText.Call(h, uintptr(unsafe.Pointer(u16(s))))
}

// values collects the fields into a Config.
func (ui *settingsUI) values() Config {
	n := ui.base
	n.Server, n.Token, n.Workspace = getText(ui.server), getText(ui.token), getText(ui.folder)
	n.AllowWrites = !isChecked(ui.chkWrites)
	n.ApproveInChat = isChecked(ui.chkChat)
	n.NoAutoUpdate = !isChecked(ui.chkUpdate)
	return n
}

func settingsWndProc(hwnd, message, wParam, lParam uintptr) uintptr {
	settingsMu.Lock()
	ui := sui
	settingsMu.Unlock()
	switch uint32(message) {
	case wmCommand:
		if ui == nil {
			break
		}
		switch wParam & 0xffff {
		case idOK:
			n := ui.values()
			if problem := validate(n); problem != "" {
				messageBoxW.Call(hwnd, uintptr(unsafe.Pointer(u16(problem))), uintptr(unsafe.Pointer(u16("Family AI Runner"))), 0x30)
				return 0
			}
			ui.result, ui.ok = n, true
			destroyWindow.Call(hwnd)
		case idCancel:
			destroyWindow.Call(hwnd)
		case idBrowse:
			if dir := chooseFolder(hwnd, getText(ui.folder)); dir != "" {
				setText(ui.folder, dir)
			}
		case idTest:
			ui.startTest()
		}
		return 0
	case wmTestDone:
		if ui != nil {
			settingsMu.Lock()
			text := ui.testText
			settingsMu.Unlock()
			setText(ui.status, text)
			enableWindow.Call(ui.btnTest, 1)
		}
		return 0
	case wmClose:
		destroyWindow.Call(hwnd)
		return 0
	case wmDestroy:
		postQuitMessage.Call(0)
		return 0
	}
	r, _, _ := defWindowProc.Call(hwnd, message, wParam, lParam)
	return r
}

// ---------- test connection ----------

func (ui *settingsUI) startTest() {
	n := ui.values()
	switch {
	case !(strings.HasPrefix(n.Server, "https://") || strings.HasPrefix(n.Server, "http://")) || len(n.Server) < 10:
		setText(ui.status, "Die Adresse muss vollständig sein, z. B. https://ai.example.org")
		return
	case !strings.HasPrefix(n.Token, "fai_dev_"):
		setText(ui.status, "Der Schlüssel beginnt mit fai_dev_")
		return
	}
	setText(ui.status, "Prüfe …")
	enableWindow.Call(ui.btnTest, 0)
	hwnd := ui.hwnd
	go func() {
		text := testConnection(n)
		settingsMu.Lock()
		ui.testText = text
		settingsMu.Unlock()
		postMessage.Call(hwnd, wmTestDone, 0, 0)
	}()
}

// testConnection asks the server's side-effect-free ping route (GET /api/runner/ping).
func testConnection(c Config) string {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if c.Insecure {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}
	client := &Client{base: strings.TrimRight(c.Server, "/"), token: c.Token, http: &http.Client{Transport: transport}}
	status, _, err := client.do("GET", "/api/runner/ping", nil, 8*1e9)
	switch {
	case errors.Is(err, errUnauthorized):
		return "Schlüssel ungültig, Gerät gelöscht oder Programmieren für diese Person ausgeschaltet."
	case err != nil:
		msg := err.Error()
		if len(msg) > 120 {
			msg = msg[:120] + " …"
		}
		return "Server nicht erreichbar: " + msg
	case status == http.StatusOK:
		return "Verbindung steht, der Schlüssel ist gültig."
	case status == http.StatusNotFound:
		return "Dort antwortet kein Family AI Server – oder er ist älter und kennt die Prüfung noch nicht."
	default:
		return fmt.Sprintf("Unerwartete Antwort vom Server (HTTP %d).", status)
	}
}

// ---------- folder picker ----------

type browseInfo struct {
	owner    uintptr
	root     uintptr
	display  *uint16
	title    *uint16
	flags    uint32
	callback uintptr
	lParam   uintptr
	image    int32
}

// browseCallback preselects the current folder when the picker opens.
func browseCallback(hwnd, msg, lParam, data uintptr) uintptr {
	if uint32(msg) == 1 && browseStart != nil { // BFFM_INITIALIZED
		sendMessage.Call(hwnd, 0x467, 1, uintptr(unsafe.Pointer(browseStart))) // BFFM_SETSELECTIONW
	}
	return 0
}

func chooseFolder(owner uintptr, current string) string {
	coInit.Call(0, 2) // COINIT_APARTMENTTHREADED; S_FALSE if already initialised is fine
	browseStart = nil
	if current != "" {
		browseStart = u16(current)
	}
	var display [260]uint16
	bi := browseInfo{owner: owner, display: &display[0], title: u16("Arbeitsordner, in dem die KI arbeiten darf"),
		flags: 0x1 | 0x40, callback: browseProc} // BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE
	pidl, _, _ := browseForFolder.Call(uintptr(unsafe.Pointer(&bi)))
	if pidl == 0 {
		return ""
	}
	defer coFree.Call(pidl)
	var path [260]uint16
	if r, _, _ := pathFromIDList.Call(pidl, uintptr(unsafe.Pointer(&path[0]))); r == 0 {
		return ""
	}
	return syscall.UTF16ToString(path[:])
}
