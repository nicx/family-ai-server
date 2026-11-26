//go:build !windows

package main

import (
	"os"
	"os/signal"
	"runtime"
	"syscall"
)

// watchUpdateSignal: SIGUSR1 = "check for updates now" (sent by the macOS menu-bar app).
func watchUpdateSignal() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGUSR1)
	go func() {
		for range ch {
			triggerUpdateCheck()
		}
	}()
}

// restartAfterUpdate starts the new program. jobMu stays locked on purpose: nothing may start meanwhile.
func restartAfterUpdate(target string) {
	if shutdownHook != nil {
		shutdownHook()
	}
	if runtime.GOOS == "darwin" {
		os.Exit(exitUpdated) // the menu-bar app starts the runner again and picks the new file
	}
	if err := syscall.Exec(target, os.Args, os.Environ()); err != nil {
		logf("Neustart nach dem Update fehlgeschlagen: %v – bitte den Runner neu starten.", err)
		os.Exit(1)
	}
}
