package main

import (
	"github.com/anyproto/any-store/v2/anyenc"
)

// goValue is anyenc.Value.GoType with every object key copied.
//
// GoType copies string values but keeps object keys as they were parsed,
// pointing into the buffer the value was read from. An any-store iterator
// reuses that buffer for the next document, so a map built by GoType inside
// an iteration and marshalled after it carried another document's bytes as
// its keys (measured: meta keys "ding", "m" and binary garbage in a kNN
// result). Every value that leaves the shim goes through here.
func goValue(v *anyenc.Value) any {
	if v == nil {
		return nil
	}
	switch v.Type() {
	case anyenc.TypeArray:
		arr, _ := v.Array()
		out := make([]any, len(arr))
		for i, av := range arr {
			out[i] = goValue(av)
		}
		return out
	case anyenc.TypeObject:
		obj, _ := v.Object()
		out := make(map[string]any, obj.Len())
		obj.Visit(func(k []byte, kv *anyenc.Value) {
			out[string(k)] = goValue(kv) // string() copies the bytes
		})
		return out
	default:
		return v.GoType()
	}
}
