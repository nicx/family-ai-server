// Family AI Runner lets Family AI Server work in one folder on this computer.
//
// Only outgoing connections: the runner asks the Family AI Server for work (long
// polling) and sends the results back. No port is opened on this computer.
//
// The AI can list, read and write files inside the workspace folder without asking;
// nothing outside it is reachable through the file tools. Every command the AI
// wants to run must be confirmed in a dialog first (--confirm-writes also asks
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
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

var version = "dev" // set at build time (-ldflags "-X main.version=…")

type Config struct {
	Server        string `json:"server"`
	Token         string `json:"token"`
	Workspace     string `json:"workspace"`
	ConfirmWrites bool   `json:"confirmWrites,omitempty"`
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
	fmt.Printf("%s %s\n", time.Now().Format("15:04:05"), fmt.Sprintf(format, a...))
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "Fehler: "+format+"\n", a...)
	if pauseOnExit {
		fmt.Print("\nEnter drücken zum Schließen … ")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	os.Exit(1)
}

var stdin = bufio.NewReader(os.Stdin)

func ask(prompt string) string {
	fmt.Print(prompt)
	line, _ := stdin.ReadString('\n')
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
	case "write_file":
		return c.ConfirmWrites
	default:
		return false
	}
}

func run(job Job, ws *Workspace, c Config) (bool, string) {
	title, text := describe(job, ws)
	if needsConfirmation(job.Tool, c) {
		logf("Anfrage: %s – warte auf Bestätigung", title)
		if !confirm("Family AI: "+title, text) {
			logf("→ abgelehnt")
			return false, "Die Person am Computer hat die Aktion abgelehnt."
		}
	} else {
		logf("%s: %s", title, firstNonEmpty(job.Args["path"], job.Args["command"], "."))
	}
	tools := map[string]func(map[string]string) (string, error){
		"list_files": ws.ListFiles, "read_file": ws.ReadFile,
		"write_file": ws.WriteFile, "run_command": ws.RunCommand,
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
	confirmWrites := fs.Bool("confirm-writes", false, "auch vor dem Schreiben von Dateien nachfragen")
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
	if set["confirm-writes"] {
		c.ConfirmWrites = *confirmWrites
	}
	if set["allow-all"] {
		c.AllowAll = *allowAll
	}
	if set["insecure"] {
		c.Insecure = *insecure
	}
	if *doSetup || c.Server == "" || c.Token == "" || c.Workspace == "" {
		c = setup(c)
	} else if set["server"] || set["token"] || set["workspace"] {
		_ = saveConfig(c)
	}

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
	case c.ConfirmWrites:
		logf("Nachfrage vor Befehlen und vor dem Schreiben von Dateien.")
	default:
		logf("Nachfrage vor jedem Befehl. Dateien im Arbeitsordner darf die KI ohne Nachfrage lesen und schreiben.")
	}
	logf("Warte auf Aufgaben von %s … (Beenden: Fenster schließen oder Strg+C)", client.base)

	backoff := 2 * time.Second
	connected := false
	for {
		status, data, err := client.do("GET", "/api/runner/poll"+q, nil, 70*time.Second)
		if errors.Is(err, errUnauthorized) {
			fatal("Geräteschlüssel ungültig, Gerät gelöscht oder Programmieren für diese Person ausgeschaltet. Neu einrichten mit --setup.")
		}
		if err != nil || status >= 400 {
			if err == nil {
				err = fmt.Errorf("HTTP %d", status)
			}
			logf("Keine Verbindung (%v), neuer Versuch in %d s", err, int(backoff.Seconds()))
			connected = false
			time.Sleep(backoff)
			backoff = min(backoff*2, 60*time.Second)
			continue
		}
		backoff = 2 * time.Second
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
		ok, out := run(job, ws, c)
		for attempt := 0; attempt < 3; attempt++ {
			if _, _, err := client.do("POST", "/api/runner/result", map[string]any{"jobId": job.ID, "ok": ok, "output": out}, 30*time.Second); err == nil {
				break
			}
			time.Sleep(2 * time.Second)
		}
	}
}
