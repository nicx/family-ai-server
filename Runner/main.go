// Family AI Runner lets Family AI Server work in one folder on this computer.
//
// Only outgoing connections: the runner asks the Family AI Server for work (long
// polling) and sends the results back. No port is opened on this computer.
//
// The AI can list and read files inside the workspace folder without asking;
// nothing outside it is reachable through the file tools. Every command the AI
// wants to run, and every file it wants to write, must be confirmed in a dialog first (--allow-writes skips the
// before writing files, --allow-all asks for nothing).
//
// Start by double-click: on the first start the runner asks for the server address,
// the device key and the workspace folder and remembers them.
//
// License: MIT – https://github.com/nicx/family-ai-server
package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

var shutdownHook func() // set by serve(): tells the server this computer goes offline

// shutdown signs off from the server and ends the process.
func shutdown() {
	if shutdownHook != nil {
		shutdownHook()
	}
	os.Exit(0)
}

var version = "dev" // set at build time (-ldflags "-X main.version=…")

type Config struct {
	Server        string `json:"server"`
	Token         string `json:"token"`
	Workspace     string `json:"workspace"`
	AllowWrites   bool   `json:"allowWrites,omitempty"`   // write files without asking (default: ask)
	ApproveInChat bool   `json:"approveInChat,omitempty"` // ask in the web chat instead of a popup (set here, never by the server)
	AllowAll      bool   `json:"allowAll,omitempty"`
	Insecure      bool   `json:"insecure,omitempty"`
}

type Job struct {
	ID        string            `json:"id"`
	Tool      string            `json:"tool"`
	Args      map[string]string `json:"args"`
	ChatTitle string            `json:"chatTitle"`
}

func logf(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	fmt.Printf("%s %s\n", time.Now().Format("15:04:05"), msg)
	writeLog(msg)
	trayStatus(msg)
}

// ---------- log file (FamilyAIRunner/runner.log, the apps open it from their menu) ----------

var (
	logMu   sync.Mutex
	logFile *os.File
	logSize int64
)

const logMax = 1 << 20 // 1 MB per file, plus one older file: at most ~2 MB on disk

func logPath() string { return filepath.Join(filepath.Dir(configPath()), "runner.log") }

// writeLog appends one line with date to runner.log. At 1 MB (also while the runner keeps running
// for weeks) the file becomes runner.log.1 (replacing the older one) and a fresh file starts.
func writeLog(msg string) {
	logMu.Lock()
	defer logMu.Unlock()
	p := logPath()
	if logFile != nil && logSize > logMax {
		logFile.Close()
		logFile = nil
		_ = os.Rename(p, p+".1")
	}
	if logFile == nil {
		_ = os.MkdirAll(filepath.Dir(p), 0o700)
		if st, err := os.Stat(p); err == nil && st.Size() > logMax {
			_ = os.Rename(p, p+".1")
		}
		f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			return
		}
		logFile = f
		logSize = 0
		if st, err := f.Stat(); err == nil {
			logSize = st.Size()
		}
	}
	n, _ := fmt.Fprintf(logFile, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
	logSize += int64(n)
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "Fehler: "+format+"\n", a...)
	writeLog("Fehler: " + fmt.Sprintf(format, a...))
	trayError(fmt.Sprintf(format, a...))
	if pauseOnExit {
		fmt.Print("\nEnter drücken zum Schließen … ")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	os.Exit(1)
}

var stdin = bufio.NewReader(os.Stdin)

func ask(prompt string) string {
	fmt.Print(prompt)
	line, err := stdin.ReadString('\n')
	if err != nil && line == "" {
		fatal("Keine Eingabe möglich (kein Terminal). Zuerst mit --setup einrichten.")
	}
	return strings.TrimSpace(line)
}

// confirmTerminal is the fallback when no dialog can be shown.
func confirmTerminal(title, text string) bool {
	bar := strings.Repeat("=", 60)
	fmt.Printf("\n%s\n%s\n%s\n%s\n", bar, title, text, bar)
	a := strings.ToLower(ask("Erlauben? [j/N] "))
	return a == "j" || a == "ja" || a == "y" || a == "yes"
}

func confirm(title, text string) bool {
	ok, err := confirmDialog(title, text)
	if err != nil {
		logf("Dialog nicht möglich (%v), frage im Terminal.", err)
		return confirmTerminal(title, text)
	}
	return ok
}

// ---------- configuration ----------

func configPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = "."
	}
	return filepath.Join(dir, "FamilyAIRunner", "config.json")
}

func loadConfig() Config {
	var c Config
	if b, err := os.ReadFile(configPath()); err == nil {
		_ = json.Unmarshal(b, &c)
	}
	return c
}

func saveConfig(c Config) error {
	p := configPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(c, "", "  ")
	return os.WriteFile(p, b, 0o600)
}

func setup(c Config) Config {
	fmt.Println("Family AI Runner einrichten – die Werte stehen in der Web-App unter Einstellungen → Computer.")
	fmt.Println()
	for {
		in := ask(fmt.Sprintf("Adresse des Servers%s: ", hintFor(c.Server)))
		if in != "" {
			c.Server = in
		}
		if u, err := url.Parse(c.Server); err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Host != "" {
			break
		}
		fmt.Println("  Bitte vollständig angeben, z. B. https://ai.example.org")
	}
	for {
		in := ask(fmt.Sprintf("Geräteschlüssel%s: ", hintFor(mask(c.Token))))
		if in != "" {
			c.Token = in
		}
		if strings.HasPrefix(c.Token, "fai_dev_") {
			break
		}
		fmt.Println("  Der Schlüssel beginnt mit fai_dev_")
	}
	for {
		in := ask(fmt.Sprintf("Arbeitsordner%s: ", hintFor(c.Workspace)))
		if in != "" {
			c.Workspace = strings.Trim(in, `"`)
		}
		if _, err := NewWorkspace(c.Workspace); err == nil {
			break
		} else {
			fmt.Println(" ", err)
		}
	}
	if err := saveConfig(c); err != nil {
		logf("Einstellungen nicht gespeichert: %v", err)
	} else {
		logf("Gespeichert in %s", configPath())
	}
	return c
}

func hintFor(v string) string {
	if v == "" {
		return ""
	}
	return " [" + v + "]"
}

func mask(token string) string {
	if len(token) < 14 {
		return token
	}
	return token[:12] + "…"
}

// ---------- server connection ----------

type Client struct {
	base  string
	token string
	http  *http.Client
}

var errUnauthorized = errors.New("unauthorized")

func (c *Client) do(method, path string, body any, timeout time.Duration) (int, []byte, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+path, rd)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "FamilyAIRunner/"+version)
	client := *c.http
	client.Timeout = timeout
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode == http.StatusUnauthorized {
		return resp.StatusCode, data, errUnauthorized
	}
	return resp.StatusCode, data, nil
}

// ---------- jobs ----------

// askInChat lets the person answer in the web chat. The second result tells whether the chat was used
// (false: the server cannot do it, e.g. an older version – then the popup is shown instead).
func askInChat(client *Client, job Job, title string) (allowed, used bool) {
	logf("Anfrage: %s – warte auf Freigabe im Chat", title)
	deadline := time.Now().Add(5 * time.Minute)
	failed := false
	for time.Now().Before(deadline) {
		status, data, err := client.do("POST", "/api/runner/ask", map[string]any{"jobId": job.ID}, 25*time.Second)
		if status == http.StatusNotFound {
			logf("Freigabe im Chat nicht möglich (Server zu alt), frage per Popup")
			return false, false
		}
		if err != nil || status >= 400 {
			if !failed { // log the first failure of a series only
				logf("Freigabe im Chat: Anfrage fehlgeschlagen (%v, HTTP %d), neuer Versuch", err, status)
				failed = true
			}
			time.Sleep(2 * time.Second)
			continue
		}
		failed = false
		var r struct {
			State string `json:"state"`
		}
		_ = json.Unmarshal(data, &r)
		switch r.State {
		case "allow":
			logf("Freigabe im Chat: erlaubt")
			return true, true
		case "deny":
			logf("Freigabe im Chat: abgelehnt")
			return false, true
		}
	}
	logf("Freigabe im Chat: keine Antwort innerhalb von 5 Minuten")
	return false, true
}

func describe(job Job, ws *Workspace) (string, string) {
	a := job.Args
	head := "Die KI möchte im Ordner\n" + ws.Root + "\n"
	if job.ChatTitle != "" {
		head += "(Chat: " + job.ChatTitle + ")\n"
	}
	switch job.Tool {
	case "run_command":
		return "Befehl ausführen", head + "\nBefehl:\n" + a["command"]
	case "write_file":
		content := a["content"]
		preview := content
		if len(preview) > 1500 {
			preview = strings.ToValidUTF8(preview[:1500], "") + "\n…"
		}
		return "Datei schreiben", head + "\nDatei: " + a["path"] + "\n\n" + preview
	case "save_image":
		return "Bild speichern", head + "\nDatei: " + a["path"] + fmt.Sprintf("\nGröße: ca. %d KB", len(a["data"])*3/4/1024)
	case "read_file":
		return "Datei lesen", head + "\nDatei: " + a["path"]
	default:
		p := a["path"]
		if p == "" {
			p = "."
		}
		return "Dateien auflisten", head + "\nOrdner: " + p
	}
}

func needsConfirmation(tool string, c Config) bool {
	if c.AllowAll {
		return false
	}
	switch tool {
	case "run_command":
		return true
	case "write_file", "save_image":
		return !c.AllowWrites
	default:
		return false
	}
}

func run(job Job, ws *Workspace, c Config, client *Client) (bool, string) {
	title, text := describe(job, ws)
	if needsConfirmation(job.Tool, c) {
		allowed, viaChat := false, false
		if c.ApproveInChat && client != nil {
			allowed, viaChat = askInChat(client, job, title)
		}
		if !viaChat {
			logf("Anfrage: %s – warte auf Bestätigung", title)
			allowed = confirm("Family AI: "+title, text)
		}
		if !allowed {
			logf("→ abgelehnt")
			return false, "Die Person hat die Aktion abgelehnt."
		}
	} else {
		logf("%s: %s", title, firstNonEmpty(job.Args["path"], job.Args["command"], "."))
	}
	tools := map[string]func(map[string]string) (string, error){
		"list_files": ws.ListFiles, "read_file": ws.ReadFile,
		"write_file": ws.WriteFile, "run_command": ws.RunCommand, "save_image": ws.SaveImage,
	}
	fn, ok := tools[job.Tool]
	if !ok {
		return false, "Unbekanntes Werkzeug: " + job.Tool
	}
	out, err := fn(job.Args)
	if err != nil {
		logf("→ Fehler: %v", err)
		return false, err.Error()
	}
	logf("→ erledigt")
	return true, out
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if s != "" {
			return s
		}
	}
	return ""
}

// query encodes with %20 for spaces (the server does not decode "+").
func query(v url.Values) string { return strings.ReplaceAll(v.Encode(), "+", "%20") }

func main() {
	fs := flag.NewFlagSet("family-ai-runner", flag.ExitOnError)
	server := fs.String("server", "", "Adresse von Family AI Server, z. B. https://ai.example.org")
	token := fs.String("token", os.Getenv("FAMILY_AI_RUNNER_TOKEN"), "Geräteschlüssel (oder Umgebungsvariable FAMILY_AI_RUNNER_TOKEN)")
	workspace := fs.String("workspace", "", "Arbeitsordner, in dem die KI arbeiten darf")
	allowWrites := fs.Bool("allow-writes", false, "Dateien im Arbeitsordner ohne Nachfrage schreiben (Standard: nachfragen)")
	allowAll := fs.Bool("allow-all", false, "NICHTS nachfragen, auch keine Befehle (nicht empfohlen)")
	insecure := fs.Bool("insecure", false, "TLS-Zertifikat nicht prüfen (nur zum Testen)")
	doSetup := fs.Bool("setup", false, "Einrichtung erneut durchlaufen")
	showVersion := fs.Bool("version", false, "Version anzeigen")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "Family AI Runner %s – lokale Werkzeuge für Family AI Server\n\nOhne Angaben fragt der Runner beim ersten Start nach und merkt sich alles.\n\n", version)
		fs.PrintDefaults()
	}
	_ = fs.Parse(os.Args[1:])
	if *showVersion {
		fmt.Println(version)
		return
	}

	c := loadConfig()
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	if *server != "" {
		c.Server = *server
	}
	if *token != "" {
		c.Token = *token
	}
	if *workspace != "" {
		c.Workspace = *workspace
	}
	if set["allow-writes"] {
		c.AllowWrites = *allowWrites
	}
	if set["allow-all"] {
		c.AllowAll = *allowAll
	}
	if set["insecure"] {
		c.Insecure = *insecure
	}
	if trayBuild {
		trayMain(c, *doSetup) // never returns; calls serve() once the settings are complete
		return
	}
	if *doSetup || c.Server == "" || c.Token == "" || c.Workspace == "" {
		c = setup(c)
	} else if set["server"] || set["token"] || set["workspace"] {
		_ = saveConfig(c)
	}
	serve(c)
}

// serve connects to the server and works through jobs until the process ends.
func serve(c Config) {
	ws, err := NewWorkspace(c.Workspace)
	if err != nil {
		fatal("%v", err)
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if c.Insecure {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}
	client := &Client{base: strings.TrimRight(c.Server, "/"), token: c.Token, http: &http.Client{Transport: transport}}
	q := "?" + query(url.Values{"workspace": {ws.Root}, "platform": {platformName + " (" + runtime.GOARCH + ")"}})

	logf("Family AI Runner %s – Arbeitsordner: %s", version, ws.Root)
	switch {
	case c.AllowAll:
		logf("Achtung: --allow-all – die KI darf alles ohne Nachfrage.")
	case c.AllowWrites:
		logf("Nachfrage vor jedem Befehl. Dateien im Arbeitsordner darf die KI ohne Nachfrage schreiben.")
	default:
		logf("Nachfrage vor jedem Befehl und vor dem Schreiben von Dateien.")
	}
	logf("Warte auf Aufgaben von %s … (Beenden: Fenster schließen oder Strg+C)", client.base)
	shutdownHook = func() { _, _, _ = client.do("POST", "/api/runner/bye", map[string]any{}, 3*time.Second) }

	// Beim Beenden (Strg+C, Fenster schließen) dem Server Bescheid geben: der Computer gilt sofort als offline.
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
		<-sig
		logf("Beende …")
		shutdown()
	}()

	backoff := 2 * time.Second
	connected := false
	warned := false
	for {
		status, data, err := client.do("GET", "/api/runner/poll"+q, nil, 70*time.Second)
		if errors.Is(err, errUnauthorized) {
			fatal("Geräteschlüssel ungültig, Gerät gelöscht oder Programmieren für diese Person ausgeschaltet. Neu einrichten mit --setup.")
		}
		if err != nil || status >= 400 {
			if err == nil {
				err = fmt.Errorf("HTTP %d", status)
			}
			if !warned { // once per outage, otherwise the log fills up while the server is away
				logf("Keine Verbindung (%v), neue Versuche alle paar Sekunden", err)
				warned = true
			}
			connected = false
			time.Sleep(backoff)
			backoff = min(backoff*2, 10*time.Second)
			continue
		}
		backoff = 2 * time.Second
		warned = false
		if !connected {
			logf("Verbunden.")
			connected = true
		}
		if status == http.StatusNoContent || len(data) == 0 {
			continue
		}
		var job Job
		if err := json.Unmarshal(data, &job); err != nil || job.ID == "" {
			logf("Unverständliche Antwort vom Server, ignoriert.")
			continue
		}
		ok, out := run(job, ws, c, client)
		for attempt := 0; attempt < 3; attempt++ {
			if _, _, err := client.do("POST", "/api/runner/result", map[string]any{"jobId": job.ID, "ok": ok, "output": out}, 30*time.Second); err == nil {
				break
			}
			time.Sleep(2 * time.Second)
		}
	}
}
