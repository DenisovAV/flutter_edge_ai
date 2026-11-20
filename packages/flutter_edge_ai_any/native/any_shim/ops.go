package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"context"
	"fmt"
	"runtime/debug"
	"time"
)

// maxWait is the longest any exported call waits: op_wait, events_poll
// and index_flush clamp their wait to it. A worker isolate blocked in a
// native call holds a Dart hot restart (and an isolate kill) until the
// call returns, so no call may wait for the network or for a close.
const maxWait = 250 * time.Millisecond

func clampWait(ms C.int32_t) time.Duration {
	d := time.Duration(ms) * time.Millisecond
	if d < 0 {
		return 0
	}
	return min(d, maxWait)
}

// op is one piece of work started by a *_start export and awaited in
// slices with any_shim_op_wait. It runs on its own goroutine with a
// context the op handle can cancel; account ops derive it from the
// account's, so cancelling or closing the account ends them too.
type op struct {
	done   chan struct{}
	cancel context.CancelFunc
	result any
	err    error
}

// startOp runs f on a goroutine and registers the op. A panic in f is
// recovered and becomes the op's ANY_SHIM_ERR_PANIC.
func startOp(parent context.Context, f func(ctx context.Context) (any, error)) uint64 {
	ctx, cancel := context.WithCancel(parent)
	o := &op{done: make(chan struct{}), cancel: cancel}
	h := handles.add(o)
	go func() {
		defer close(o.done)
		defer cancel()
		defer func() {
			if r := recover(); r != nil {
				o.result = nil
				o.err = &shimError{code: codePanic, err: fmt.Errorf("panic: %v\n%s", r, debug.Stack())}
			}
		}()
		o.result, o.err = f(ctx)
	}()
	return h
}

// wait returns errPending while the op runs. Once it has finished, the
// first caller takes the handle out of the registry and gets the
// result; every later call is ANY_SHIM_ERR_CLOSED.
func waitOp(h uint64, d time.Duration) (any, error) {
	o, err := lookup[*op](h, "an op")
	if err != nil {
		return nil, err
	}
	if d > 0 {
		t := time.NewTimer(d)
		select {
		case <-o.done:
		case <-t.C:
		}
		t.Stop()
	}
	select {
	case <-o.done:
	default:
		return nil, errPending
	}
	if _, ok := takeIf[*op](h); !ok {
		return nil, errClosed
	}
	if o.err != nil {
		return nil, o.err
	}
	if o.result == nil {
		return map[string]any{}, nil
	}
	return o.result, nil
}

var errPending = withCode(codePending, "the op has not finished; wait again")

//export any_shim_op_wait
func any_shim_op_wait(h C.uint64_t, waitMs C.int32_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		if outJSON == nil {
			return invalid("out_json is NULL")
		}
		r, err := waitOp(uint64(h), clampWait(waitMs))
		if err != nil {
			return err
		}
		return putJSON(outJSON, r)
	})
}

//export any_shim_op_cancel
func any_shim_op_cancel(h C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		o, err := take[*op](uint64(h), "an op")
		if err != nil {
			return err
		}
		o.cancel()
		return nil
	})
}

// putOp writes a started op's handle.
func putOp(out *C.uint64_t, h uint64) {
	*out = C.uint64_t(h)
}
