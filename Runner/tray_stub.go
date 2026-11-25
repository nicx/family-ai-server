//go:build !(windows && tray)

package main

// The tray build (Windows, -tags tray) replaces these.
const trayBuild = false

func trayMain(Config, bool)  {}
func trayStatus(string)      {}
func trayError(string)       {}
func trayReauth(Config) bool { return false }
