//go:build !ios

package main

import (
	"fmt"
	"os"
	"time"
)

// bgTask: only iOS freezes a process right after it leaves the
// foreground; elsewhere the background task is a no-op.
type bgTask struct{}

func beginBackgroundTask(string) *bgTask { return nil }

func (t *bgTask) end() {}

// remaining: no background time bound outside iOS.
func (t *bgTask) remaining(time.Duration) (left time.Duration, ok, refreshed bool) {
	return 0, false, false
}

func observedRemaining() (time.Duration, bool) { return 0, false }

func observeBackground() {}

func platformLog(msg string) { fmt.Fprintln(os.Stderr, msg) }
