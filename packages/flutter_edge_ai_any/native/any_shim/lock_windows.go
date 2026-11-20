//go:build windows

package main

import (
	"errors"
	"os"

	"golang.org/x/sys/windows"
)

const isWindows = true

// lockFile takes an exclusive, non-blocking LockFileEx on path (created
// if missing) and returns the open file that holds it. Another process
// holding it is ANY_SHIM_ERR_BUSY.
func lockFile(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	ol := new(windows.Overlapped)
	err = windows.LockFileEx(windows.Handle(f.Fd()),
		windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, ol)
	if err != nil {
		f.Close()
		if errors.Is(err, windows.ERROR_LOCK_VIOLATION) || errors.Is(err, windows.ERROR_IO_PENDING) {
			return nil, withCode(codeBusy, "%s is locked by another process", path)
		}
		return nil, err
	}
	return f, nil
}

// unlockFile releases the lock and closes the file.
func unlockFile(f *os.File) error {
	if f == nil {
		return nil
	}
	ol := new(windows.Overlapped)
	_ = windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, ol)
	return f.Close()
}
