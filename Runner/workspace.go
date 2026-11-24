package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	maxOutput   = 60_000
	maxRead     = 400_000
	maxListed   = 500
	maxDepth    = 5
	cmdTimeout  = 180 * time.Second
	captureSize = 4 << 20
)

var skipDirs = map[string]bool{
	".git": true, "node_modules": true, "__pycache__": true, ".venv": true, "venv": true,
	".build": true, "dist": true, "build": true, ".idea": true, ".vs": true,
}

// Workspace is the one folder the AI may work in. The file tools never leave it.
type Workspace struct{ Root string }

func NewWorkspace(path string) (*Workspace, error) {
	p, err := expandHome(path)
	if err != nil {
		return nil, err
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return nil, err
	}
	real, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return nil, fmt.Errorf("Arbeitsordner existiert nicht: %s", abs)
	}
	if st, err := os.Stat(real); err != nil || !st.IsDir() {
		return nil, fmt.Errorf("Arbeitsordner ist kein Ordner: %s", real)
	}
	return &Workspace{Root: real}, nil
}

func expandHome(p string) (string, error) {
	if p == "~" || strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`) {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		return filepath.Join(home, p[1:]), nil
	}
	return p, nil
}

// within reports whether p is root or below it (case-insensitive on Windows,
// because filepath.Rel compares path elements that way there).
func within(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

// evalExisting resolves symlinks in the longest existing prefix of p, so a path to a
// file that does not exist yet still cannot escape through a symlinked parent.
func evalExisting(p string) (string, error) {
	rest := []string{}
	cur := p
	for {
		real, err := filepath.EvalSymlinks(cur)
		if err == nil {
			for i := len(rest) - 1; i >= 0; i-- {
				real = filepath.Join(real, rest[i])
			}
			return real, nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p, nil
		}
		rest = append(rest, filepath.Base(cur))
		cur = parent
	}
}

func (w *Workspace) Resolve(rel string) (string, error) {
	rel = strings.TrimSpace(rel)
	var p string
	if filepath.IsAbs(rel) {
		p = filepath.Clean(rel)
	} else {
		p = filepath.Join(w.Root, rel)
	}
	real, err := evalExisting(p)
	if err != nil {
		return "", err
	}
	if !within(w.Root, real) {
		return "", errors.New("Pfad liegt außerhalb des Arbeitsordners")
	}
	return real, nil
}

func (w *Workspace) display(p string) string {
	rel, err := filepath.Rel(w.Root, p)
	if err != nil {
		return p
	}
	return filepath.ToSlash(rel)
}

func (w *Workspace) ListFiles(args map[string]string) (string, error) {
	base, err := w.Resolve(args["path"])
	if err != nil {
		return "", err
	}
	var out []string
	truncated := false
	err = filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries are skipped
		}
		if d.IsDir() {
			if p == base {
				return nil
			}
			rel, _ := filepath.Rel(base, p)
			if skipDirs[d.Name()] || len(strings.Split(rel, string(filepath.Separator))) > maxDepth {
				return filepath.SkipDir
			}
			return nil
		}
		var size int64
		if info, e := d.Info(); e == nil {
			size = info.Size()
		}
		out = append(out, fmt.Sprintf("%s  (%d B)", w.display(p), size))
		if len(out) >= maxListed {
			truncated = true
			return filepath.SkipAll
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Strings(out)
	if truncated {
		out = append(out, "… (gekürzt)")
	}
	if len(out) == 0 {
		return "(leer)", nil
	}
	return strings.Join(out, "\n"), nil
}

func (w *Workspace) ReadFile(args map[string]string) (string, error) {
	p, err := w.Resolve(args["path"])
	if err != nil {
		return "", err
	}
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	buf := make([]byte, maxRead+1)
	n, _ := readFull(f, buf)
	text := strings.ToValidUTF8(string(buf[:min(n, maxRead)]), "�")
	if n > maxRead {
		text += "\n… (gekürzt)"
	}
	return text, nil
}

func readFull(f *os.File, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := f.Read(buf[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

func (w *Workspace) WriteFile(args map[string]string) (string, error) {
	p, err := w.Resolve(args["path"])
	if err != nil {
		return "", err
	}
	if p == w.Root {
		return "", errors.New("Kein Dateiname angegeben")
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return "", err
	}
	content := args["content"]
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		return "", err
	}
	return fmt.Sprintf("Geschrieben: %s (%d B)", w.display(p), len(content)), nil
}

// imageExts are the only file types save_image may create.
var imageExts = map[string]bool{".png": true, ".jpg": true, ".jpeg": true, ".webp": true, ".gif": true}

const maxImageBytes = 6 << 20

// looksLikeImage checks the first bytes, so the AI cannot smuggle other data in under an image name.
func looksLikeImage(b []byte) bool {
	switch {
	case bytes.HasPrefix(b, []byte("\x89PNG\r\n\x1a\n")), bytes.HasPrefix(b, []byte{0xff, 0xd8, 0xff}),
		bytes.HasPrefix(b, []byte("GIF87a")), bytes.HasPrefix(b, []byte("GIF89a")):
		return true
	case len(b) > 12 && string(b[:4]) == "RIFF" && string(b[8:12]) == "WEBP":
		return true
	}
	return false
}

// SaveImage writes a picture sent by the server (base64 in args["data"]) into the workspace.
func (w *Workspace) SaveImage(args map[string]string) (string, error) {
	p, err := w.Resolve(args["path"])
	if err != nil {
		return "", err
	}
	if !imageExts[strings.ToLower(filepath.Ext(p))] {
		return "", errors.New("Nur Bilddateien (png, jpg, jpeg, webp, gif) erlaubt")
	}
	data, err := base64.StdEncoding.DecodeString(args["data"])
	if err != nil || len(data) == 0 {
		return "", errors.New("Bilddaten unlesbar")
	}
	if len(data) > maxImageBytes {
		return "", errors.New("Bild zu groß")
	}
	if !looksLikeImage(data) {
		return "", errors.New("Die Daten sind kein Bild")
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(p, data, 0o644); err != nil {
		return "", err
	}
	return fmt.Sprintf("Bild gespeichert: %s (%d B)", w.display(p), len(data)), nil
}

// capped keeps at most n bytes; the rest is counted but dropped.
type capped struct {
	buf     bytes.Buffer
	n       int
	dropped bool
}

func (c *capped) Write(p []byte) (int, error) {
	if room := c.n - c.buf.Len(); room > 0 {
		if len(p) > room {
			c.buf.Write(p[:room])
			c.dropped = true
		} else {
			c.buf.Write(p)
		}
	} else if len(p) > 0 {
		c.dropped = true
	}
	return len(p), nil
}

func decodeOutput(b []byte) string {
	if utf8.Valid(b) {
		return string(b)
	}
	return decodeLegacy(b)
}

func shorten(s string) string {
	if len(s) <= maxOutput {
		return s
	}
	head, tail := s[:maxOutput/2], s[len(s)-maxOutput/2:]
	return strings.ToValidUTF8(head, "") + "\n… (gekürzt) …\n" + strings.ToValidUTF8(tail, "")
}

func (w *Workspace) RunCommand(args map[string]string) (string, error) {
	command := strings.TrimSpace(args["command"])
	if command == "" {
		return "", errors.New("Kein Befehl angegeben")
	}
	ctx, cancel := context.WithTimeout(context.Background(), cmdTimeout)
	defer cancel()
	cmd := shellCommand(ctx, command)
	cmd.Dir = w.Root
	cmd.WaitDelay = 5 * time.Second // do not hang on pipes held open by grandchildren
	var stdout, stderr = &capped{n: captureSize}, &capped{n: captureSize}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return "", fmt.Errorf("Zeitüberschreitung (Befehl lief länger als %d s)", int(cmdTimeout.Seconds()))
	}
	code := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			code = ee.ExitCode()
		} else {
			return "", err
		}
	}
	out := decodeOutput(stdout.buf.Bytes())
	if stderr.buf.Len() > 0 {
		out += "\n[stderr]\n" + decodeOutput(stderr.buf.Bytes())
	}
	if stdout.dropped || stderr.dropped {
		out += "\n… (Ausgabe sehr lang, gekürzt)"
	}
	return fmt.Sprintf("Exit-Code %d\n%s", code, shorten(out)), nil
}
