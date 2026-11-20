//go:build !windows

package main

import (
	"errors"
	"os"
	"syscall"
)

const isWindows = false

// lockFile takes an exclusive, non-blocking flock on path (created if
// missing) and returns the open file that holds it. Another process
// holding it is ANY_SHIM_ERR_BUSY. flock belongs to the open file
// description, so a second open of the same path in this process is
// refused too; the registries refuse that case earlier, by name.
func lockFile(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	if err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, withCode(codeBusy, "%s is locked by another process", path)
		}
		return nil, err
	}
	return f, nil
}

// unlockFile releases the lock (closing the file releases it).
func unlockFile(f *os.File) error {
	if f == nil {
		return nil
	}
	return f.Close()
}
