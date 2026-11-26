//go:build windows

package main

import (
	"os"
	"os/exec"
)

func watchUpdateSignal() {}

// restartAfterUpdate starts the new exe (it waits for the single-instance lock) and signs off this copy.
func restartAfterUpdate(target string) {
	if err := exec.Command(target).Start(); err != nil {
		logf("Neustart nach dem Update fehlgeschlagen: %v – bitte den Runner neu starten.", err)
		os.Exit(1)
	}
	shutdown()
}
