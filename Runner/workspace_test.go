package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newWS(t *testing.T) *Workspace {
	t.Helper()
	dir := t.TempDir()
	ws, err := NewWorkspace(dir)
	if err != nil {
		t.Fatal(err)
	}
	return ws
}

func TestResolveStaysInside(t *testing.T) {
	ws := newWS(t)
	outside := t.TempDir()
	for _, p := range []string{"../x", "a/../../x", outside, filepath.Join(outside, "y"), "/etc/passwd"} {
		if _, err := ws.Resolve(p); err == nil {
			t.Errorf("%q should be rejected", p)
		}
	}
	for _, p := range []string{"", ".", "a/b.txt", "a/../b.txt", filepath.Join(ws.Root, "c.txt")} {
		if _, err := ws.Resolve(p); err != nil {
			t.Errorf("%q should be allowed: %v", p, err)
		}
	}
}

func TestSymlinkEscapeRejected(t *testing.T) {
	ws := newWS(t)
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(ws.Root, "link")); err != nil {
		t.Skip("symlinks not available:", err)
	}
	if _, err := ws.WriteFile(map[string]string{"path": "link/evil.txt", "content": "x"}); err == nil {
		t.Fatal("write through symlink to outside must fail")
	}
	if _, err := os.Stat(filepath.Join(outside, "evil.txt")); err == nil {
		t.Fatal("file was written outside the workspace")
	}
}

func TestWriteReadList(t *testing.T) {
	ws := newWS(t)
	if _, err := ws.WriteFile(map[string]string{"path": "src/main.py", "content": "print('hallo ä')\n"}); err != nil {
		t.Fatal(err)
	}
	if _, err := ws.WriteFile(map[string]string{"path": "node_modules/x.js", "content": "x"}); err != nil {
		t.Fatal(err)
	}
	got, err := ws.ReadFile(map[string]string{"path": "src/main.py"})
	if err != nil || got != "print('hallo ä')\n" {
		t.Fatalf("read: %q %v", got, err)
	}
	list, _ := ws.ListFiles(map[string]string{})
	if !strings.Contains(list, "src/main.py") || strings.Contains(list, "node_modules") {
		t.Fatalf("list: %s", list)
	}
	if _, err := ws.WriteFile(map[string]string{"path": "", "content": "x"}); err == nil {
		t.Fatal("writing the workspace root itself must fail")
	}
}

func TestRunCommand(t *testing.T) {
	ws := newWS(t)
	out, err := ws.RunCommand(map[string]string{"command": "echo hallo welt"})
	if err != nil || !strings.HasPrefix(out, "Exit-Code 0") || !strings.Contains(out, "hallo welt") {
		t.Fatalf("%q %v", out, err)
	}
	out, _ = ws.RunCommand(map[string]string{"command": "exit 3"})
	if !strings.HasPrefix(out, "Exit-Code 3") {
		t.Fatalf("%q", out)
	}
}

func TestConfirmationPolicy(t *testing.T) {
	def := Config{}
	if !needsConfirmation("run_command", def) || !needsConfirmation("write_file", def) || needsConfirmation("read_file", def) {
		t.Fatal("default: commands and writes need confirmation, reading does not")
	}
	if needsConfirmation("write_file", Config{AllowWrites: true}) || !needsConfirmation("run_command", Config{AllowWrites: true}) {
		t.Fatal("allow-writes")
	}
	if needsConfirmation("run_command", Config{AllowAll: true}) {
		t.Fatal("allow-all")
	}
}

func TestQueryUsesPercent20(t *testing.T) {
	q := query(map[string][]string{"platform": {"Windows (amd64)"}, "workspace": {`C:\Users\A B\x+y`}})
	if strings.Contains(q, "+") && !strings.Contains(q, "%2B") || strings.Contains(q, "A+B") {
		t.Fatalf("%s", q)
	}
}

func TestShorten(t *testing.T) {
	s := strings.Repeat("ä", maxOutput)
	out := shorten(s)
	if len(out) > maxOutput+100 || !strings.Contains(out, "gekürzt") {
		t.Fatalf("len %d", len(out))
	}
}

func TestLogRotates(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Setenv("XDG_CONFIG_HOME", dir)
	logFile, logSize = nil, 0
	line := strings.Repeat("x", 1000)
	for i := 0; i < 2600; i++ { // ~2.6 MB
		writeLog(line)
	}
	logMu.Lock()
	logFile.Close()
	logFile = nil
	logMu.Unlock()
	st, err := os.Stat(logPath())
	if err != nil || st.Size() > logMax+2000 {
		t.Fatalf("current log too big: %v %v", st, err)
	}
	if _, err := os.Stat(logPath() + ".1"); err != nil {
		t.Fatal("no rotated file")
	}
	if _, err := os.Stat(logPath() + ".2"); err == nil {
		t.Fatal("old logs pile up")
	}
}

func TestSaveImage(t *testing.T) {
	ws, err := NewWorkspace(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	png := []byte("\x89PNG\r\n\x1a\n" + strings.Repeat("x", 50))
	enc := base64.StdEncoding.EncodeToString(png)
	if _, err := ws.SaveImage(map[string]string{"path": "img/header.png", "data": enc}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(ws.Root, "img", "header.png")); !bytes.Equal(b, png) {
		t.Fatal("content differs")
	}
	for name, args := range map[string]map[string]string{
		"not an image":  {"path": "a.png", "data": base64.StdEncoding.EncodeToString([]byte("#!/bin/sh\nrm -rf ~"))},
		"script suffix": {"path": "a.sh", "data": enc},
		"outside":       {"path": "../a.png", "data": enc},
		"bad base64":    {"path": "a.png", "data": "***"},
	} {
		if _, err := ws.SaveImage(args); err == nil {
			t.Fatalf("%s must fail", name)
		}
	}
	if !needsConfirmation("save_image", Config{}) || needsConfirmation("save_image", Config{AllowWrites: true}) {
		t.Fatal("save_image is confirmed like write_file")
	}
}
