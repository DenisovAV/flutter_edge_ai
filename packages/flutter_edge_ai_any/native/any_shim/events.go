package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"sync"
	"time"

	"github.com/anyproto/any-sync-sdk/space"
)

const (
	defaultQueueCapacity = 4096
	defaultPollMax       = 256
)

// eventQueue is an account's bounded event queue. push never blocks: it
// runs on the SDK's apply path. When the queue is full one overflow
// marker is queued and later events are dropped until the marker is read;
// it then reports how many were dropped.
type eventQueue struct {
	mu       sync.Mutex
	items    []map[string]any
	capacity int
	dropped  int
	marker   bool // an overflow marker is in items
	wake     chan struct{}
	done     chan struct{}
	closed   bool
}

func newEventQueue(capacity int) *eventQueue {
	return &eventQueue{capacity: capacity, wake: make(chan struct{}, 1), done: make(chan struct{})}
}

func (q *eventQueue) push(ev map[string]any) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	if len(q.items) >= q.capacity {
		q.dropped++
		if !q.marker {
			q.marker = true
			q.items = append(q.items, map[string]any{"kind": "overflow"})
		}
	} else {
		q.items = append(q.items, ev)
	}
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

func (q *eventQueue) close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	if !q.closed {
		q.closed = true
		close(q.done)
	}
}

// poll waits up to timeout for an event, then takes up to max of them.
func (q *eventQueue) poll(max int, timeout time.Duration) ([]map[string]any, error) {
	if max <= 0 {
		max = defaultPollMax
	}
	var deadline <-chan time.Time
	if timeout > 0 {
		t := time.NewTimer(timeout)
		defer t.Stop()
		deadline = t.C
	}
	for {
		q.mu.Lock()
		if q.closed {
			q.mu.Unlock()
			return nil, errClosed
		}
		if len(q.items) > 0 {
			n := min(max, len(q.items))
			out := make([]map[string]any, n)
			copy(out, q.items[:n])
			q.items = append(q.items[:0:0], q.items[n:]...)
			for _, ev := range out {
				if ev["kind"] == "overflow" {
					ev["dropped"] = q.dropped
					q.dropped = 0
					q.marker = false
				}
			}
			q.mu.Unlock()
			return out, nil
		}
		q.mu.Unlock()
		if deadline == nil {
			return []map[string]any{}, nil
		}
		select {
		case <-q.wake:
		case <-q.done:
		case <-deadline:
			return []map[string]any{}, nil
		}
	}
}

// newWatchId reserves an id before subscribing, so a callback the SDK
// runs during Subscribe already carries it.
func (a *account) newWatchId() int64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.watchSeq++
	return a.watchSeq
}

func (a *account) addWatch(id int64, stop func()) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.watches[id] = stop
}

func (a *account) watchChanges(spaceId string) (int64, error) {
	sp, err := a.space(spaceId)
	if err != nil {
		return 0, err
	}
	id := a.newWatchId()
	cancel := sp.Changes().Subscribe(func(c space.ObjectChange) {
		a.events.push(map[string]any{"kind": "change", "watch": id, "spaceId": spaceId,
			"objectId": c.ObjectId, "applySeq": c.ApplySeq, "deleted": c.Deleted})
	})
	a.addWatch(id, cancel)
	return id, nil
}

func (a *account) watchSyncStatus() int64 {
	id := a.newWatchId()
	cancel := a.sdk.Spaces().SubscribeStatus(func(st space.SpaceSyncStatus) {
		ev := spaceStatusJSON(st) // carries lastSyncedAt
		ev["kind"], ev["watch"] = "syncStatus", id
		a.events.push(ev)
	})
	a.addWatch(id, cancel)
	return id
}

func (a *account) unwatch(id int64) error {
	a.mu.Lock()
	stop, ok := a.watches[id]
	delete(a.watches, id)
	a.mu.Unlock()
	if !ok {
		return withCode(codeNotFound, "no watch %d", id)
	}
	stop()
	return nil
}

func (a *account) changesSince(spaceId string, since uint64, limit int) (map[string]any, error) {
	sp, err := a.space(spaceId)
	if err != nil {
		return nil, err
	}
	// Generation and the bound first: a reset between them and the read
	// below shows up as a generation change on the next call, never as a
	// cursor silently applied to a new generation.
	gen, err := sp.Changes().Generation(a.ctx)
	if err != nil {
		return nil, err
	}
	maxSeq, err := sp.Changes().MaxApplySeq(a.ctx)
	if err != nil {
		return nil, err
	}
	ch, err := sp.Changes().ChangedSince(a.ctx, since, limit)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(ch))
	for _, c := range ch {
		out = append(out, map[string]any{"objectId": c.ObjectId, "applySeq": c.ApplySeq, "deleted": c.Deleted})
	}
	return map[string]any{"generation": gen, "maxApplySeq": maxSeq, "changes": out}, nil
}

// ---------------------------------------------------------------- exports

//export any_shim_changes_since
func any_shim_changes_since(h C.uint64_t, spaceID *C.char, since C.uint64_t, limit C.int32_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			r, err := a.changesSince(goStr(spaceID), uint64(since), int(limit))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_watch_changes
func any_shim_watch_changes(h C.uint64_t, spaceID *C.char, outWatch *C.int64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			if outWatch == nil {
				return invalid("out_watch is NULL")
			}
			id, err := a.watchChanges(goStr(spaceID))
			if err != nil {
				return err
			}
			*outWatch = C.int64_t(id)
			return nil
		})
	})
}

//export any_shim_watch_sync_status
func any_shim_watch_sync_status(h C.uint64_t, outWatch *C.int64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			if outWatch == nil {
				return invalid("out_watch is NULL")
			}
			*outWatch = C.int64_t(a.watchSyncStatus())
			return nil
		})
	})
}

//export any_shim_unwatch
func any_shim_unwatch(h C.uint64_t, watch C.int64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error { return a.unwatch(int64(watch)) })
	})
}

// any_shim_events_poll does not hold the account's call lock while it
// waits (at most 250 ms): close must not wait for a poller, it wakes it.
//
//export any_shim_events_poll
func any_shim_events_poll(h C.uint64_t, maxEvents, timeoutMs C.int32_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		a, err := lookup[*account](uint64(h), "an account")
		if err != nil {
			return err
		}
		if outJSON == nil {
			return invalid("out_json is NULL")
		}
		evs, err := a.events.poll(int(maxEvents), clampWait(timeoutMs))
		if err != nil {
			return err
		}
		return putJSON(outJSON, evs)
	})
}
