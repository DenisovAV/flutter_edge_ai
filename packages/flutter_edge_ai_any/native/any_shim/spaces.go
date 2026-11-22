package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"runtime/debug"
	"time"

	"github.com/anyproto/any-sync-sdk/space"
)

// spaceFastWait is how long a call that needs a space waits for its load
// before it answers ANY_SHIM_ERR_PENDING. A space stored on this device
// loads in milliseconds; a space a joining device has to fetch can take
// a minute (the known first-open stall), and that is what
// space_resolve_start is for.
const spaceFastWait = 150 * time.Millisecond

// spaceLoad is one detached Spaces().Get of a space: one per space at a
// time, on the account's context (only cancel and close end it), never
// holding the account's call lock. A failed load leaves the map, so the
// next call starts a fresh one; a successful one stays as the cache.
type spaceLoad struct {
	done chan struct{}
	sp   space.Space
	err  error
}

func (l *spaceLoad) finished() bool {
	select {
	case <-l.done:
		return true
	default:
		return false
	}
}

func (a *account) startLoad(id string) (*spaceLoad, error) {
	if id == "" {
		return nil, invalid("space id is empty")
	}
	a.loadsMu.Lock()
	defer a.loadsMu.Unlock()
	if l, ok := a.loads[id]; ok {
		return l, nil
	}
	if a.loadsClosed || a.ctx.Err() != nil {
		return nil, errClosed
	}
	l := &spaceLoad{done: make(chan struct{})}
	a.loads[id] = l
	a.loadWG.Add(1)
	go func() {
		defer a.loadWG.Done()
		defer close(l.done)
		defer func() {
			if r := recover(); r != nil {
				l.err = &shimError{code: codePanic, err: fmt.Errorf("panic loading space %s: %v\n%s", id, r, debug.Stack())}
				a.dropLoad(id, l)
			}
		}()
		sp, err := a.sdk.Spaces().Get(a.ctx, id)
		if err != nil {
			l.err = err
			a.dropLoad(id, l)
			return
		}
		l.sp = sp
	}()
	return l, nil
}

func (a *account) dropLoad(id string, l *spaceLoad) {
	a.loadsMu.Lock()
	defer a.loadsMu.Unlock()
	if a.loads[id] == l {
		delete(a.loads, id)
	}
}

// loadErr reports a failed load: an id the account does not know is
// NOT_FOUND (the SDK says so in microseconds, from the local list).
func loadErr(id string, err error) error {
	if errors.Is(err, space.ErrSpaceUnknown) {
		return withCode(codeNotFound, "space %s is not known to this account: %v", id, err)
	}
	return err
}

// space returns the loaded space, starting its load if none runs. A load
// still running after spaceFastWait is ANY_SHIM_ERR_PENDING: the caller
// starts space_resolve_start and waits for it.
func (a *account) space(id string) (space.Space, error) {
	l, err := a.startLoad(id)
	if err != nil {
		return nil, err
	}
	if !l.finished() {
		t := time.NewTimer(spaceFastWait)
		select {
		case <-l.done:
		case <-t.C:
		case <-a.ctx.Done():
		}
		t.Stop()
	}
	if !l.finished() {
		if a.ctx.Err() != nil {
			return nil, errClosed
		}
		return nil, withCode(codePending, "space %s is still loading; wait for any_shim_space_resolve_start", id)
	}
	if l.err != nil {
		return nil, loadErr(id, l.err)
	}
	return l.sp, nil
}

func (a *account) loading(id string) bool {
	a.loadsMu.Lock()
	defer a.loadsMu.Unlock()
	l, ok := a.loads[id]
	return ok && !l.finished()
}

// resolve waits for the space's load (starting one), or for ctx.
// Cancelling ctx (op_cancel) leaves the load running.
func (a *account) resolve(ctx context.Context, id string) (map[string]any, error) {
	l, err := a.startLoad(id)
	if err != nil {
		return nil, err
	}
	select {
	case <-l.done:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if l.err != nil {
		return nil, loadErr(id, l.err)
	}
	return map[string]any{"spaceId": id}, nil
}

func timeOrNil(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC().Format(time.RFC3339Nano)
}

func spaceStatusJSON(st space.SpaceSyncStatus) map[string]any {
	return map[string]any{
		"spaceId": st.SpaceId, "state": st.State.String(), "p2p": st.P2P.String(),
		"localPeers": st.LocalPeers, "networkPeers": st.NetworkPeers,
		"globalPeers": st.GlobalPeers, "synced": st.Synced, "total": st.Total,
		"lastSyncedAt": timeOrNil(st.LastSyncedAt),
	}
}

func (a *account) spaceListJSON(ctx context.Context) ([]map[string]any, error) {
	list, err := a.sdk.Spaces().List(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(list))
	for _, i := range list {
		out = append(out, map[string]any{"id": i.Id, "name": i.Name, "status": i.Status.String()})
	}
	return out, nil
}

func (a *account) knows(id string) (bool, error) {
	list, err := a.sdk.Spaces().List(a.ctx)
	if err != nil {
		return false, err
	}
	for _, i := range list {
		if i.Id == id {
			return true, nil
		}
	}
	return false, nil
}

// spaceStatus refuses an id the account does not know: the SDK answers
// "unknown" for any string, so a typo would read as "not synced yet".
func (a *account) spaceStatus(id string) (map[string]any, error) {
	if id == "" {
		return nil, invalid("space id is empty")
	}
	known, err := a.knows(id)
	if err != nil {
		return nil, err
	}
	if !known {
		return nil, withCode(codeNotFound, "space %s is not known to this account", id)
	}
	st := a.sdk.Spaces().Status(id)
	if !st.LastSyncedAt.IsZero() {
		_ = a.markPeerSynced(id, false)
	}
	out := spaceStatusJSON(st)
	out["spaceId"] = id
	ps := a.state.get(id)
	out["loading"] = a.loading(id)
	out["everPeerSynced"] = ps.EverPeerSynced || !st.LastSyncedAt.IsZero()
	out["createdHere"] = ps.CreatedHere
	out["stateSaveError"] = nil
	if err := a.state.saveError(); err != nil {
		out["stateSaveError"] = err.Error()
	}
	return out, nil
}

func (a *account) createSpace(name string) (map[string]any, error) {
	sp, err := a.sdk.Spaces().Create(a.ctx, space.CreateRequest{Name: name})
	if err != nil {
		return nil, err
	}
	// Recorded before the call returns: the creator exception of the
	// publish gate reads it.
	out := map[string]any{"id": sp.Id()}
	if err := a.state.update(sp.Id(), true, func(st *spaceState) { st.CreatedHere = true }); err != nil {
		// The space exists: never make the caller create a second one.
		out["stateSaveError"] = err.Error()
	}
	a.loadsMu.Lock()
	if _, ok := a.loads[sp.Id()]; !ok && !a.loadsClosed {
		l := &spaceLoad{done: make(chan struct{}), sp: sp}
		close(l.done)
		a.loads[sp.Id()] = l
	}
	a.loadsMu.Unlock()
	return out, nil
}

// syncHeads runs one head-sync round with a deadline. A network failure
// is the result, not the status; only a cancelled account is an error.
func (a *account) syncHeads(ctx context.Context, sp space.Space, timeout time.Duration) (map[string]any, error) {
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	err := sp.SyncHeads(tctx)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	res := map[string]any{"reachedPeer": err == nil, "timedOut": false, "error": nil}
	if err != nil {
		res["error"] = err.Error()
		res["timedOut"] = errors.Is(tctx.Err(), context.DeadlineExceeded)
	} else if serr := a.markPeerSynced(sp.Id(), true); serr != nil {
		// A peer answered, but the flag the publish gate reads is not on
		// disk: not OK.
		return nil, fmt.Errorf("sync_heads reached a peer, but the account state was not saved: %w", serr)
	}
	return res, nil
}

// spaceListSync asks reachable peers for the space list within timeout,
// then lists. A failed or timed-out sync is reported, not an error.
func (a *account) spaceListSync(ctx context.Context, timeout time.Duration) (map[string]any, error) {
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var syncErr any
	timedOut := false
	if err := a.sdk.Spaces().SyncSpaceList(tctx); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		syncErr = err.Error()
		timedOut = errors.Is(tctx.Err(), context.DeadlineExceeded)
	}
	list, err := a.spaceListJSON(ctx)
	if err != nil {
		return nil, err
	}
	return map[string]any{"spaces": list, "syncError": syncErr, "timedOut": timedOut}, nil
}

func positiveTimeout(ms C.int32_t) (time.Duration, error) {
	if ms <= 0 {
		return 0, invalid("timeout_ms must be > 0, got %d", int32(ms))
	}
	return time.Duration(ms) * time.Millisecond, nil
}

// ---------------------------------------------------------------- exports

//export any_shim_space_create
func any_shim_space_create(h C.uint64_t, name *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			r, err := a.createSpace(goStr(name))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_space_list
func any_shim_space_list(h C.uint64_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			l, err := a.spaceListJSON(a.ctx)
			if err != nil {
				return err
			}
			return putJSON(outJSON, map[string]any{"spaces": l})
		})
	})
}

//export any_shim_space_list_sync_start
func any_shim_space_list_sync_start(h C.uint64_t, timeoutMs C.int32_t, outOp *C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			if outOp == nil {
				return invalid("out_op is NULL")
			}
			d, err := positiveTimeout(timeoutMs)
			if err != nil {
				return err
			}
			putOp(outOp, a.startOp(func(ctx context.Context) (any, error) { return a.spaceListSync(ctx, d) }))
			return nil
		})
	})
}

//export any_shim_space_resolve_start
func any_shim_space_resolve_start(h C.uint64_t, spaceID *C.char, outOp *C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			if outOp == nil {
				return invalid("out_op is NULL")
			}
			id := goStr(spaceID)
			if _, err := a.startLoad(id); err != nil {
				return err
			}
			putOp(outOp, a.startOp(func(ctx context.Context) (any, error) { return a.resolve(ctx, id) }))
			return nil
		})
	})
}

//export any_shim_space_status
func any_shim_space_status(h C.uint64_t, spaceID *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			st, err := a.spaceStatus(goStr(spaceID))
			if err != nil {
				return err
			}
			return putJSON(outJSON, st)
		})
	})
}

//export any_shim_space_sync_heads_start
func any_shim_space_sync_heads_start(h C.uint64_t, spaceID *C.char, timeoutMs C.int32_t, outOp *C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			if outOp == nil {
				return invalid("out_op is NULL")
			}
			d, err := positiveTimeout(timeoutMs)
			if err != nil {
				return err
			}
			sp, err := a.space(goStr(spaceID))
			if err != nil {
				return err
			}
			putOp(outOp, a.startOp(func(ctx context.Context) (any, error) { return a.syncHeads(ctx, sp, d) }))
			return nil
		})
	})
}
