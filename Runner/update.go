package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
)

// Self-update. The server ships the runner builds under /runner/ together with SHA256SUMS and a one-line file
// "runner-build" holding the build stamp (UTC, YYYYMMDDHHMMSS) that is also compiled into every binary
// (-X main.build=…). A runner with an older stamp downloads its own file, checks the SHA-256, test-runs it and
// swaps itself – between two jobs, never in the middle of one.

var build = "dev" // build stamp, set at build time

const (
	updateFirstCheck = 45 * time.Second
	updateInterval   = 6 * time.Hour
	maxUpdateSize    = 64 << 20
	exitUpdated      = 75 // macOS: the menu-bar app restarts the runner when it ends with this code
)

var (
	jobMu     sync.Mutex // held while a job runs; the update waits for it
	updateNow = make(chan struct{}, 1)
	// updateReport shows the result of a manual check (the Windows tray sets it to a message box).
	updateReport = func(string) {}
	stampRe      = regexp.MustCompile(`^\d{14}$`)
)

// triggerUpdateCheck asks the update loop for an immediate check (tray menu, SIGUSR1 on macOS/Linux).
func triggerUpdateCheck() {
	select {
	case updateNow <- struct{}{}:
	default:
	}
}

// updateAsset is the file on the server that matches this program, "" if there is none.
func updateAsset() string {
	arch := map[string]string{"amd64": "x64", "arm64": "arm64"}[runtime.GOARCH]
	if arch == "" {
		return ""
	}
	switch runtime.GOOS {
	case "windows":
		if trayBuild {
			return "family-ai-runner-tray-windows-" + arch + ".exe"
		}
	case "linux":
		return "family-ai-runner-linux-" + arch
	case "darwin":
		return "family-ai-runner-macos-" + arch
	}
	return ""
}

// updateTarget is the file that gets replaced. On macOS the runner inside the signed app bundle stays untouched;
// the update lives next to config.json and the menu-bar app prefers it when it is newer.
func updateTarget() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	if runtime.GOOS == "darwin" {
		dir := filepath.Dir(configPath())
		if !strings.Contains(exe, ".app/Contents/") && filepath.Dir(exe) != dir {
			return "", errors.New("läuft nicht als App")
		}
		return filepath.Join(dir, "family-ai-runner"), nil
	}
	return exe, nil
}

// parseSums finds the SHA-256 of one file in a SHA256SUMS listing.
func parseSums(text, file string) string {
	for _, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == file && len(f[0]) == 64 {
			return strings.ToLower(f[0])
		}
	}
	return ""
}

func download(client *Client, path string) ([]byte, error) {
	req, err := http.NewRequest("GET", client.base+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "FamilyAIRunner/"+version)
	hc := *client.http
	hc.Timeout = 3 * time.Minute
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxUpdateSize+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxUpdateSize {
		return nil, errors.New("Datei zu groß")
	}
	return data, nil
}

// swapFile puts tmp in place of target. Windows cannot overwrite a running .exe but can rename it.
func swapFile(target, tmp string) error {
	if runtime.GOOS != "windows" {
		return os.Rename(tmp, target)
	}
	old := target + ".old"
	_ = os.Remove(old)
	if err := os.Rename(target, old); err != nil {
		return err
	}
	if err := os.Rename(tmp, target); err != nil {
		_ = os.Rename(old, target)
		return err
	}
	return nil
}

// cleanupOldBinary removes the leftover of the previous update (Windows).
func cleanupOldBinary() {
	if runtime.GOOS != "windows" {
		return
	}
	if exe, err := os.Executable(); err == nil {
		_ = os.Remove(exe + ".old")
	}
}

// checkAndUpdate returns a message for the person; on a successful update it does not return (restarts).
func checkAndUpdate(client *Client) (string, error) {
	asset := updateAsset()
	if asset == "" {
		return "Automatische Updates gibt es für dieses Programm nicht.", nil
	}
	if build == "dev" {
		return "Entwicklungsversion – kein Update.", nil
	}
	target, err := updateTarget()
	if err != nil {
		return "Automatische Updates sind hier nicht möglich (" + err.Error() + ").", nil
	}
	status, data, err := client.do("GET", "/runner/runner-build", nil, 20*time.Second)
	if err != nil {
		return "", err
	}
	if status == http.StatusNotFound {
		return "Dieser Server bietet keine Runner-Updates an.", nil
	}
	remote := strings.TrimSpace(string(data))
	if status != http.StatusOK || !stampRe.MatchString(remote) {
		return "", fmt.Errorf("unverständliche Antwort des Servers (HTTP %d)", status)
	}
	if remote <= build {
		return "Der Runner ist auf dem neuesten Stand.", nil
	}
	_, sums, err := client.do("GET", "/runner/SHA256SUMS", nil, 20*time.Second)
	if err != nil {
		return "", err
	}
	want := parseSums(string(sums), asset)
	if want == "" {
		return "", fmt.Errorf("%s fehlt in SHA256SUMS", asset)
	}
	logf("Update: neuer Stand %s gefunden, lade %s …", remote, asset)
	bin, err := download(client, "/runner/"+asset)
	if err != nil {
		return "", fmt.Errorf("Download: %w", err)
	}
	sum := sha256.Sum256(bin)
	if hex.EncodeToString(sum[:]) != want {
		return "", errors.New("Prüfsumme stimmt nicht – Update verworfen")
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return "", err
	}
	tmp := target + ".new"
	if err := os.WriteFile(tmp, bin, 0o755); err != nil {
		return "", fmt.Errorf("Schreiben nicht möglich: %w", err)
	}
	defer os.Remove(tmp)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := exec.CommandContext(ctx, tmp, "--version").Run(); err != nil {
		return "", fmt.Errorf("neue Version startet nicht: %w", err)
	}
	jobMu.Lock() // wait until no job is running
	if err := swapFile(target, tmp); err != nil {
		jobMu.Unlock()
		return "", fmt.Errorf("Austausch nicht möglich: %w", err)
	}
	logf("Update: installiert (Stand %s), starte neu …", remote)
	restartAfterUpdate(target)
	return "", nil
}

// updateLoop checks once shortly after the start and then every few hours; a manual check comes in via updateNow.
func updateLoop(c Config, client *Client) {
	cleanupOldBinary()
	wait := updateFirstCheck
	for {
		manual := false
		select {
		case <-updateNow:
			manual = true
		case <-time.After(wait):
			if c.NoAutoUpdate {
				wait = updateInterval
				continue
			}
		}
		wait = updateInterval
		if manual {
			logf("Update: suche …")
		}
		msg, err := checkAndUpdate(client)
		switch {
		case err != nil:
			msg = "Update nicht möglich: " + err.Error()
			logf("%s", msg)
		case manual || !strings.HasPrefix(msg, "Der Runner ist auf"):
			logf("Update: %s", msg)
		}
		if manual {
			updateReport(msg)
		}
	}
}
