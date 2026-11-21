//go:build windows

package main

import (
	"context"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

const platformName = "Windows"

var (
	user32      = syscall.NewLazyDLL("user32.dll")
	messageBoxW = user32.NewProc("MessageBoxW")
	kernel32    = syscall.NewLazyDLL("kernel32.dll")
	getOEMCP    = kernel32.NewProc("GetOEMCP")
)

// shellCommand runs the command through cmd.exe. The command line is passed
// verbatim (/S /C "…"), because cmd does not follow the quoting rules Go uses
// for normal arguments.
func shellCommand(ctx context.Context, command string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "cmd.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `cmd.exe /S /C "` + command + `"`}
	return cmd
}

// confirmDialog shows a topmost Yes/No box with "No" as the default button.
func confirmDialog(title, text string) (bool, error) {
	clean := func(s string) string { return strings.ReplaceAll(s, "\x00", "") }
	t, err := syscall.UTF16PtrFromString(clean(title))
	if err != nil {
		return false, err
	}
	m, err := syscall.UTF16PtrFromString(clean(text))
	if err != nil {
		return false, err
	}
	const (
		mbYesNo         = 0x4
		mbIconWarning   = 0x30
		mbDefButton2    = 0x100
		mbSetForeground = 0x10000
		mbTopmost       = 0x40000
		idYes           = 6
	)
	ret, _, callErr := messageBoxW.Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)),
		mbYesNo|mbIconWarning|mbDefButton2|mbSetForeground|mbTopmost)
	if ret == 0 {
		return false, callErr
	}
	return ret == idYes, nil
}

// decodeLegacy converts output of console programs that do not write UTF-8.
// Console tools on German Windows usually write the OEM code page 850.
func decodeLegacy(b []byte) string {
	if cp, _, _ := getOEMCP.Call(); cp == 850 {
		return decodeTable(b, &cp850)
	}
	return decodeLatin1(b)
}

// cp850 maps bytes 0x80–0xFF of code page 850 to Unicode.
var cp850 = [128]rune{
	'Ç', 'ü', 'é', 'â', 'ä', 'à', 'å', 'ç', 'ê', 'ë', 'è', 'ï', 'î', 'ì', 'Ä', 'Å',
	'É', 'æ', 'Æ', 'ô', 'ö', 'ò', 'û', 'ù', 'ÿ', 'Ö', 'Ü', 'ø', '£', 'Ø', '×', 'ƒ',
	'á', 'í', 'ó', 'ú', 'ñ', 'Ñ', 'ª', 'º', '¿', '®', '¬', '½', '¼', '¡', '«', '»',
	'░', '▒', '▓', '│', '┤', 'Á', 'Â', 'À', '©', '╣', '║', '╗', '╝', '¢', '¥', '┐',
	'└', '┴', '┬', '├', '─', '┼', 'ã', 'Ã', '╚', '╔', '╩', '╦', '╠', '═', '╬', '¤',
	'ð', 'Ð', 'Ê', 'Ë', 'È', 'ı', 'Í', 'Î', 'Ï', '┘', '┌', '█', '▄', '¦', 'Ì', '▀',
	'Ó', 'ß', 'Ô', 'Ò', 'õ', 'Õ', 'µ', 'þ', 'Þ', 'Ú', 'Û', 'Ù', 'ý', 'Ý', '¯', '´',
	'­', '±', '‗', '¾', '¶', '§', '÷', '¸', '°', '¨', '·', '¹', '³', '²', '■', ' ',
}

func decodeTable(b []byte, table *[128]rune) string {
	var sb strings.Builder
	for _, c := range b {
		if c < 0x80 {
			sb.WriteByte(c)
		} else {
			sb.WriteRune(table[c-0x80])
		}
	}
	return sb.String()
}

// pauseOnExit keeps the console window open after a double-click start.
const pauseOnExit = true
