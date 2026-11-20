//go:build !ios

package main

// beginBackgroundTask is iOS-only (bgtask_ios.go); elsewhere a process
// is not frozen right after it leaves the foreground.
func beginBackgroundTask(string) (end func()) { return func() {} }
