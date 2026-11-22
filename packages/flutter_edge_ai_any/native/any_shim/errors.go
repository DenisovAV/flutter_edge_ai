package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"strings"
	"syscall"

	anystore "github.com/anyproto/any-store/v2"
	"github.com/anyproto/any-sync-sdk/space"
	"github.com/anyproto/any-sync/commonspace/object/acl/list"
	"github.com/anyproto/any-sync/commonspace/settings"
)

// Status codes; the values are the ANY_SHIM_* constants of any_shim.h
// (TestStatusCodesMatchHeader holds them together). The Dart side maps a
// code it does not know to INTERNAL.
const (
	codeOK              = 0
	codeInvalidArgument = 1
	codeNotFound        = 2
	codeDeleted         = 3
	codeClosed          = 4
	codeTimeout         = 5
	codeRefused         = 6
	codeInternal        = 7
	codePanic           = 8
	codeConflict        = 9
	codeCorrupt         = 10
	codeKeyMismatch     = 11
	codeBusy            = 12
	codePending         = 13
	codeKeyMissing      = 14
	codeIO              = 15
)

// shimError carries an explicit code. Errors without one are classified
// by codeOf from the SDK's and any-store's sentinels.
type shimError struct {
	code int
	err  error
}

func (e *shimError) Error() string { return e.err.Error() }
func (e *shimError) Unwrap() error { return e.err }

func withCode(code int, format string, args ...any) error {
	return &shimError{code: code, err: fmt.Errorf(format, args...)}
}

// wrapCode gives err an explicit code, keeping it reachable for errors.Is.
func wrapCode(code int, err error) error {
	if err == nil {
		return nil
	}
	return &shimError{code: code, err: err}
}

func invalid(format string, args ...any) error {
	return withCode(codeInvalidArgument, format, args...)
}

var errClosed = withCode(codeClosed, "handle is closed or was never issued")

// anystoreFullText is any-store v2.4.3's "database is full" error
// (btree.ErrFull, internal/btree/errors.go). Its sentinel lives in an
// internal package, so the text is the only handle. Matching it is a
// cheap extra: nothing tests it against a real full database, and a
// change of the text in a later any-store goes unnoticed (the errno path
// covers a full disk).
const anystoreFullText = "btree: database is full"

// isIOErrno reports a file-system refusal the caller can fix or retry:
// permission, a read-only file system, a full disk (by errno, which
// any-store and the SDK keep wrapped), or any-store's own "full".
func isIOErrno(err error) bool {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		switch errno {
		case syscall.EACCES, syscall.EPERM, syscall.ENOSPC, syscall.EROFS, syscall.EDQUOT, syscall.EIO:
			return true
		}
		if isPlatformIOErrno(errno) {
			return true
		}
	}
	if errors.Is(err, fs.ErrPermission) {
		return true
	}
	return err != nil && strings.Contains(err.Error(), anystoreFullText)
}

// storeErr classifies a failure of the local index's database: an error
// that already carries a code keeps it; a file-system refusal (errno, as
// isIOErrno) is ERR_IO; anystore.ErrCorrupt is ERR_CORRUPT; the rest
// INTERNAL.
func storeErr(err error) error {
	if err == nil {
		return nil
	}
	var se *shimError
	if errors.As(err, &se) {
		return err
	}
	switch {
	case isIOErrno(err):
		return wrapCode(codeIO, err)
	case errors.Is(err, anystore.ErrCorrupt):
		return wrapCode(codeCorrupt, err)
	}
	return wrapCode(codeInternal, err)
}

func codeOf(err error) int {
	if err == nil {
		return codeOK
	}
	var se *shimError
	if errors.As(err, &se) {
		return se.code
	}
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return codeTimeout
	case errors.Is(err, context.Canceled):
		// The account context is cancelled only by cancel and close.
		return codeClosed
	case isIOErrno(err):
		return codeIO
	case errors.Is(err, settings.ErrCantDeleteDerivedObject):
		// A derived (seeded) object's id can be derived again, so
		// any-sync never deletes its tree.
		return codeRefused
	case errors.Is(err, space.ErrReadOnlySpace),
		errors.Is(err, list.ErrInsufficientPermissions),
		errors.Is(err, space.ErrSpaceNotAccepted):
		return codeRefused
	case errors.Is(err, space.ErrObjectDeleted),
		errors.Is(err, space.ErrSpaceDeleted),
		errors.Is(err, space.ErrRecordDeleted):
		return codeDeleted
	case errors.Is(err, space.ErrNotFound),
		errors.Is(err, space.ErrObjectNotFound),
		errors.Is(err, space.ErrSpaceUnknown),
		errors.Is(err, anystore.ErrDocNotFound):
		return codeNotFound
	case errors.Is(err, space.ErrBadSpaceId),
		errors.Is(err, space.ErrTypeRequired),
		errors.Is(err, space.ErrInvalidFieldValue):
		return codeInvalidArgument
	}
	return codeInternal
}

// writeErr classifies the failure of a synced write: the codes a caller
// branches on (closed, timeout, deleted, not found, I/O) stay, and any
// other refusal of the SDK, a pre-flight error included, is
// ANY_SHIM_ERR_REFUSED. A permission refusal says "read-only".
func writeErr(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, space.ErrReadOnlySpace) || errors.Is(err, list.ErrInsufficientPermissions) {
		return withCode(codeRefused, "read-only: this account may not write to the space: %v", err)
	}
	switch codeOf(err) {
	case codeClosed, codeTimeout, codeDeleted, codeNotFound, codeIO, codeRefused, codePending, codeBusy:
		return err
	}
	return wrapCode(codeRefused, err)
}
