package main

import "sync"

// registry maps the opaque uint64 handles the C API hands out to Go
// values: accounts, indexes and ops share one number space. Unlike
// runtime/cgo.Handle, a stale or forged handle is a lookup miss
// (ANY_SHIM_ERR_CLOSED), never a panic or a use of freed memory.
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

// takeIf removes h and returns its value when the value is a T: one
// caller wins, every later or concurrent one gets false. A handle of
// another kind is left in place.
func takeIf[T any](h uint64) (T, bool) {
	handles.mu.Lock()
	defer handles.mu.Unlock()
	var zero T
	v, ok := handles.m[h]
	if !ok {
		return zero, false
	}
	t, ok := v.(T)
	if !ok {
		return zero, false
	}
	delete(handles.m, h)
	return t, true
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

// take is takeIf with the errors of lookup: CLOSED for an unknown handle,
// INVALID_ARGUMENT for one of another kind.
func take[T any](h uint64, what string) (T, error) {
	if t, ok := takeIf[T](h); ok {
		return t, nil
	}
	_, err := lookup[T](h, what)
	if err == nil {
		// Taken by a concurrent caller between the two looks.
		err = errClosed
	}
	var zero T
	return zero, err
}
