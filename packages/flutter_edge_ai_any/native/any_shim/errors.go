package main

import (
	"context"
	"errors"
	"fmt"

	anystore "github.com/anyproto/any-store/v2"
	"github.com/anyproto/any-sync-sdk/space"
	"github.com/anyproto/any-sync/commonspace/settings"
)

// Status codes; the values are the ANY_SHIM_* constants of any_shim.h
// (TestStatusCodesMatchHeader holds them together).
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

func invalid(format string, args ...any) error {
	return withCode(codeInvalidArgument, format, args...)
}

var errClosed = withCode(codeClosed, "handle is closed or was never issued")

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
		// The account context is cancelled only by close.
		return codeClosed
	case errors.Is(err, settings.ErrCantDeleteDerivedObject):
		// A derived (seeded) object's id can be derived again, so
		// any-sync never deletes its tree.
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
