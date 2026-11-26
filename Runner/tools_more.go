package main

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

const (
	maxMatches    = 200
	maxSearchFile = 2 << 20 // bigger files are skipped by the content search
	maxLineShown  = 240
)

// SearchFiles finds files by name (glob in args["name"], e.g. *.go) and/or text inside files (args["query"],
// case-insensitive). Reads only; skips the usual build/vendor folders and binary files.
func (w *Workspace) SearchFiles(args map[string]string) (string, error) {
	base, err := w.Resolve(args["path"])
	if err != nil {
		return "", err
	}
	query := strings.ToLower(args["query"])
	name := strings.TrimSpace(args["name"])
	if query == "" && name == "" {
		return "", errors.New("Weder Suchtext (query) noch Dateimuster (name) angegeben")
	}
	if name != "" {
		if _, err := path.Match(strings.ToLower(name), ""); err != nil {
			return "", fmt.Errorf("Ungültiges Dateimuster: %s", name)
		}
	}
	var out []string
	truncated := false
	add := func(s string) bool {
		out = append(out, s)
		if len(out) >= maxMatches {
			truncated = true
			return false
		}
		return true
	}
	_ = filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if p != base && skipDirs[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		if name != "" {
			if ok, _ := path.Match(strings.ToLower(name), strings.ToLower(d.Name())); !ok {
				return nil
			}
		}
		if query == "" {
			if !add(w.display(p)) {
				return filepath.SkipAll
			}
			return nil
		}
		if info, e := d.Info(); e != nil || info.Size() > maxSearchFile {
			return nil
		}
		data, e := os.ReadFile(p)
		if e != nil || bytes.IndexByte(data[:min(len(data), 8000)], 0) >= 0 {
			return nil // unreadable or binary
		}
		for i, line := range strings.Split(string(data), "\n") {
			if !strings.Contains(strings.ToLower(line), query) {
				continue
			}
			line = strings.TrimRight(line, "\r")
			if len(line) > maxLineShown {
				line = strings.ToValidUTF8(line[:maxLineShown], "") + "…"
			}
			if !add(fmt.Sprintf("%s:%d: %s", w.display(p), i+1, strings.TrimSpace(line))) {
				return filepath.SkipAll
			}
		}
		return nil
	})
	if len(out) == 0 {
		return "Keine Treffer.", nil
	}
	sort.Strings(out)
	if truncated {
		out = append(out, "… (nach 200 Treffern abgebrochen, Suche eingrenzen)")
	}
	return strings.Join(out, "\n"), nil
}

// MakeDir creates a folder (and missing parents) inside the workspace.
func (w *Workspace) MakeDir(args map[string]string) (string, error) {
	p, err := w.Resolve(args["path"])
	if err != nil {
		return "", err
	}
	if p == w.Root {
		return "", errors.New("Kein Ordnername angegeben")
	}
	if err := os.MkdirAll(p, 0o755); err != nil {
		return "", err
	}
	return "Ordner angelegt: " + w.display(p), nil
}

// MoveFile moves or renames a file or folder inside the workspace. It never overwrites.
func (w *Workspace) MoveFile(args map[string]string) (string, error) {
	from, err := w.Resolve(args["from"])
	if err != nil {
		return "", err
	}
	to, err := w.Resolve(args["to"])
	if err != nil {
		return "", err
	}
	if from == w.Root || to == w.Root {
		return "", errors.New("Der Arbeitsordner selbst kann nicht verschoben werden")
	}
	if _, err := os.Lstat(from); err != nil {
		return "", fmt.Errorf("Quelle existiert nicht: %s", w.display(from))
	}
	if _, err := os.Lstat(to); err == nil {
		return "", fmt.Errorf("Ziel existiert schon: %s (wird nicht überschrieben)", w.display(to))
	}
	if within(from, to) {
		return "", errors.New("Ein Ordner kann nicht in sich selbst verschoben werden")
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return "", err
	}
	if err := os.Rename(from, to); err != nil {
		return "", err
	}
	return fmt.Sprintf("Verschoben: %s → %s", w.display(from), w.display(to)), nil
}

// DeleteFile removes one file or one empty folder. Never recursive, never the workspace itself.
func (w *Workspace) DeleteFile(args map[string]string) (string, error) {
	p, err := w.Resolve(args["path"])
	if err != nil {
		return "", err
	}
	if p == w.Root {
		return "", errors.New("Der Arbeitsordner selbst kann nicht gelöscht werden")
	}
	info, err := os.Lstat(p)
	if err != nil {
		return "", fmt.Errorf("Existiert nicht: %s", w.display(p))
	}
	if info.IsDir() {
		entries, _ := os.ReadDir(p)
		if len(entries) > 0 {
			return "", fmt.Errorf("Ordner ist nicht leer: %s (nur einzelne Dateien und leere Ordner löschbar)", w.display(p))
		}
	}
	if err := os.Remove(p); err != nil {
		return "", err
	}
	return "Gelöscht: " + w.display(p), nil
}
