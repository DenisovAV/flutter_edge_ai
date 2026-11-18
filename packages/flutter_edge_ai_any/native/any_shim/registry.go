package main

import "sync"

// registry maps the opaque uint64 handles the C API hands out to Go
// values. Unlike runtime/cgo.Handle, a stale or forged handle is a lookup
// miss (ANY_SHIM_ERR_CLOSED), never a panic or a use of freed memory.
type registry struct {
	mu   sync.Mutex
	next uint64
	m    map[uint64]any
}

var handles = &registry{m: map[uint64]any{}}

func (r *registry) add(v any) uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.next++
	r.m[r.next] = v
	return r.next
}

func (r *registry) remove(h uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.m, h)
}

func lookup[T any](h uint64, what string) (T, error) {
	handles.mu.Lock()
	v, ok := handles.m[h]
	handles.mu.Unlock()
	var zero T
	if !ok {
		return zero, errClosed
	}
	t, ok := v.(T)
	if !ok {
		return zero, invalid("handle %d is not %s", h, what)
	}
	return t, nil
}
