//go:build !windows

package main

import (
	"context"
	"os/exec"
	"runtime"
	"strings"
)

var platformName = map[string]string{"darwin": "macOS", "linux": "Linux"}[runtime.GOOS]

func shellCommand(ctx context.Context, command string) *exec.Cmd {
	return exec.CommandContext(ctx, "/bin/sh", "-c", command)
}

// confirmDialog uses an AppleScript dialog on macOS ("Ablehnen" is the default
// button, the dialog gives up after 5 minutes). Elsewhere the terminal is used.
func confirmDialog(title, text string) (bool, error) {
	if runtime.GOOS != "darwin" {
		return confirmTerminal(title, text), nil
	}
	if len(text) > 3000 {
		text = strings.ToValidUTF8(text[:3000], "") + "\n…"
	}
	script := `on run argv
display dialog (item 2 of argv) with title (item 1 of argv) buttons {"Ablehnen", "Erlauben"} default button "Ablehnen" cancel button "Ablehnen" with icon caution giving up after 300
return button returned of result
end run`
	out, err := exec.Command("/usr/bin/osascript", "-e", script, title, text).Output()
	if err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			return false, nil // "Ablehnen" or timeout
		}
		return false, err
	}
	return strings.TrimSpace(string(out)) == "Erlauben", nil
}

func decodeLegacy(b []byte) string { return decodeLatin1(b) }

const pauseOnExit = false
