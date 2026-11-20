//go:build !ios

package main

import "time"

// beginBackgroundTask is iOS-only (bgtask_ios.go); elsewhere a process
// is not frozen right after it leaves the foreground.
func beginBackgroundTask(string) (end func()) { return func() {} }

// backgroundTimeRemaining: only iOS bounds a suspend's time.
func backgroundTimeRemaining() (time.Duration, bool) { return 0, false }

// observeBackground: only iOS reports a background deadline.
func observeBackground() {}
