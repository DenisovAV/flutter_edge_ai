package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
	"unsafe"
)

var testKey = strings.Repeat("ab", 32)

func idxOpts(path, keyHex, token string) string {
	b, _ := json.Marshal(map[string]any{"path": path, "keyHex": keyHex, "ownerToken": token})
	return string(b)
}

func mustOpenIndex(t *testing.T, path, keyHex string) *localIndex {
	t.Helper()
	x, err := openIndex(idxOpts(path, keyHex, "tok"))
	if err != nil {
		t.Fatalf("openIndex: %v", err)
	}
	t.Cleanup(func() { _ = x.close() })
	return x
}

func newIndex(t *testing.T) *localIndex {
	return mustOpenIndex(t, filepath.Join(t.TempDir(), "index.anystore"), "")
}

func mustBind(t *testing.T, x *localIndex, js string) map[string]any {
	t.Helper()
	r, err := x.bind(js)
	if err != nil {
		t.Fatalf("bind %s: %v", js, err)
	}
	return r
}

// applyJSON runs index_apply with the floats as the vector buffer.
func applyJSON(x *localIndex, ops any, floats []float32) (map[string]any, error) {
	b, _ := json.Marshal(ops)
	var p unsafe.Pointer
	if len(floats) > 0 {
		p = unsafe.Pointer(&floats[0])
	}
	return x.apply(string(b), p, int64(len(floats)))
}

func mustApply(t *testing.T, x *localIndex, ops any, floats []float32) {
	t.Helper()
	if _, err := applyJSON(x, ops, floats); err != nil {
		t.Fatalf("apply: %v", err)
	}
}

// unit returns a normalised vector pointing mostly along axis i.
func unit(dim, i int, jitter float32) []float32 {
	v := make([]float32, dim)
	v[i%dim] = 1
	v[(i+1)%dim] = jitter
	var n float64
	for _, f := range v {
		n += float64(f * f)
	}
	for k := range v {
		v[k] /= float32(math.Sqrt(n))
	}
	return v
}

func ids(r map[string]any) []string {
	var out []string
	for _, m := range r["results"].([]map[string]any) {
		out = append(out, m["id"].(string))
	}
	return out
}

type upsert struct {
	id, text string
	f        map[string]any
	vec      []float32
	coll     string
}

// upserts builds one apply request (ops + buffer) for rows.
func upserts(rows ...upsert) (map[string]any, []float32) {
	var ops []map[string]any
	var buf []float32
	for _, r := range rows {
		coll := r.coll
		if coll == "" {
			coll = "docs"
		}
		op := map[string]any{"op": "upsert", "coll": coll, "id": r.id, "text": r.text, "meta": map[string]any{"src": r.id}}
		if r.f != nil {
			op["f"] = r.f
		}
		if r.vec != nil {
			op["vector"] = map[string]any{"offset": len(buf), "dim": len(r.vec)}
			buf = append(buf, r.vec...)
		} else {
			op["vector"] = nil
		}
		ops = append(ops, op)
	}
	return map[string]any{"ops": ops}, buf
}

func TestIndexBindIdempotentGrowConflict(t *testing.T) {
	x := newIndex(t)
	if info := x.info(); len(info) != 0 {
		t.Fatalf("info before bind = %v, want {}", info)
	}
	r := mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[{"key":"a-string","type":"string"}],"textSearch":false}`)
	if r["dim"] != 4 || len(r["fields"].([]map[string]any)) != 1 {
		t.Fatalf("bind = %v", r)
	}
	// Same again: idempotent. A subset: still everything bound (only grows).
	mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[{"key":"a-string","type":"string"}],"textSearch":false}`)
	r = mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[],"textSearch":false}`)
	if len(r["fields"].([]map[string]any)) != 1 {
		t.Fatalf("fields shrank: %v", r)
	}
	r = mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[{"key":"b-number","type":"number"}],"textSearch":true}`)
	if len(r["fields"].([]map[string]any)) != 2 || r["textSearch"] != true {
		t.Fatalf("grow: %v", r)
	}
	r = mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[],"textSearch":false}`)
	if r["textSearch"] != true {
		t.Fatalf("textSearch went back to false: %v", r)
	}
	for _, c := range []string{
		`{"dim":8,"metric":"cosine","fields":[],"textSearch":false}`,
		`{"dim":4,"metric":"l2","fields":[],"textSearch":false}`,
		`{"dim":4,"metric":"cosine","fields":[{"key":"a-string","type":"bool"}],"textSearch":false}`,
	} {
		if _, err := x.bind(c); codeOf(err) != codeConflict {
			t.Errorf("%s: %v, want CONFLICT", c, err)
		}
	}
	for _, c := range []string{
		`{"dim":0,"metric":"cosine"}`,
		`{"dim":4,"metric":"hamming"}`,
		`{"dim":4,"metric":"cosine","fields":[{"key":"A.b","type":"string"}]}`,
		`{"dim":4,"metric":"cosine","fields":[{"key":"k","type":"date"}]}`,
		`{"dim":4,"metric":"cosine","fields":[{"key":"k","type":"string"},{"key":"k","type":"string"}]}`,
		`{"dim":4,"metric":"cosine","mode":"hnsw"}`,
	} {
		if _, err := x.bind(c); codeOf(err) != codeInvalidArgument {
			t.Errorf("%s: %v, want INVALID_ARGUMENT", c, err)
		}
	}
	info := x.info()
	if info["fileId"] == nil || info["dim"] != 4 {
		t.Fatalf("info = %v", info)
	}
	// The bind survives a reopen.
	path := x.path
	if err := x.close(); err != nil {
		t.Fatal(err)
	}
	y := mustOpenIndex(t, path, "")
	if got := y.info(); got["textSearch"] != true || len(got["fields"].([]map[string]any)) != 2 || got["fileId"] != info["fileId"] {
		t.Fatalf("after reopen: %v", got)
	}
}

func TestIndexApplyKnnTextGetScanCount(t *testing.T) {
	x := newIndex(t)
	// Text-only rows before bind are allowed; a vector is refused.
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": "pre", "text": "early row"}}}, nil)
	ops, buf := upserts(upsert{id: "v", text: "x", vec: unit(4, 0, 0)})
	if _, err := applyJSON(x, ops, buf); codeOf(err) != codeRefused {
		t.Fatalf("vector before bind: %v, want REFUSED", err)
	}
	mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[{"key":"cat","type":"string"},{"key":"n","type":"number"},{"key":"ok","type":"bool"}],"textSearch":true}`)
	ops, buf = upserts(
		upsert{id: "a", text: "methane on titan", f: map[string]any{"cat": "space", "n": 1, "ok": true}, vec: unit(4, 0, 0.1)},
		upsert{id: "b", text: "bread and butter", f: map[string]any{"cat": "food", "n": 2}, vec: unit(4, 1, 0.1)},
		upsert{id: "c", text: "rings of saturn", f: map[string]any{"cat": "space", "n": 3}, vec: unit(4, 2, 0.1)},
		upsert{id: "d", text: "pasta with basil", f: map[string]any{"cat": "food"}}, // text-only
	)
	mustApply(t, x, ops, buf)
	r, err := x.knn(unit(4, 1, 0.1), 10, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 3 || got[0] != "b" {
		t.Fatalf("knn = %v, want b first and only the 3 rows with a vector", got)
	}
	r, err = x.knn(unit(4, 1, 0.1), 10, `{"f.cat":"space"}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 2 {
		t.Fatalf("filtered knn = %v", got)
	}
	r, err = x.knn(unit(4, 1, 0.1), 10, `{"$or":[{"f.n":{"$gte":3}},{"f.ok":true}]}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 2 {
		t.Fatalf("$or knn = %v", got)
	}
	for _, bad := range []string{`{"meta.cat":"x"}`, `{"f.A":"x"}`, `{"$where":"1"}`, `[1]`, `{"f.cat":`} {
		if _, err := x.knn(unit(4, 1, 0), 1, bad); codeOf(err) != codeInvalidArgument {
			t.Errorf("filter %s: %v", bad, err)
		}
	}
	if _, err := x.knn([]float32{1, 0, 0}, 1, ""); codeOf(err) != codeInvalidArgument {
		t.Errorf("wrong query dim: %v", err)
	}
	if _, err := x.knn(unit(4, 0, 0), 0, ""); codeOf(err) != codeInvalidArgument {
		t.Errorf("k=0: %v", err)
	}
	r, err = x.text("basil", 5, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 1 || got[0] != "d" {
		t.Fatalf("text = %v, want the text-only row", got)
	}
	r, err = x.text("early", 5, `{"f.cat":"food"}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 0 {
		t.Fatalf("filtered text = %v", got)
	}
	var n int64
	if c, _ := x.docs.Count(bg); c != 5 {
		t.Fatalf("count = %d, want 5", c)
	}
	if c, err := x.countVectors(); err != nil || c != 3 {
		t.Fatalf("count vectors = %d %v, want 3", c, err)
	}
	_ = n
	g, err := x.get("docs", "a")
	if err != nil || g == nil {
		t.Fatalf("get a: %v %v", g, err)
	}
	if vec := g["vector"].([]float32); len(vec) != 4 || g["text"] != "methane on titan" || g["f"].(map[string]any)["cat"] != "space" {
		t.Fatalf("get a = %v", g)
	}
	if g, err := x.get("docs", "nope"); err != nil || g != nil {
		t.Fatalf("get absent = %v %v, want nil", g, err)
	}
	if _, err := x.get("shadow", "a"); codeOf(err) != codeInvalidArgument {
		t.Fatalf("get shadow without one: %v", err)
	}
	// State.
	mustApply(t, x, map[string]any{"ops": []any{
		map[string]any{"op": "stateSet", "coll": "state", "key": "cursor", "value": "42"},
		map[string]any{"op": "stateSet", "coll": "state", "key": "cx/1", "value": "a"},
		map[string]any{"op": "stateSet", "coll": "state", "key": "cx/2", "value": "b"},
		map[string]any{"op": "stateSet", "coll": "state", "key": "cy/1", "value": "c"},
	}}, nil)
	if g, _ := x.get("state", "cursor"); g["value"] != "42" || g["key"] != "cursor" {
		t.Fatalf("state get = %v", g)
	}
	s, err := x.scan("state", "cx/", "", 1)
	if err != nil {
		t.Fatal(err)
	}
	items := s["items"].([]map[string]any)
	if len(items) != 1 || items[0]["key"] != "cx/1" || s["next"] != "cx/1" {
		t.Fatalf("scan page 1 = %v", s)
	}
	s, _ = x.scan("state", "cx/", "cx/1", 1)
	items = s["items"].([]map[string]any)
	if len(items) != 1 || items[0]["key"] != "cx/2" || s["next"] != nil {
		t.Fatalf("scan page 2 = %v", s)
	}
	s, _ = x.scan("docs", "", "", 0)
	items = s["items"].([]map[string]any)
	if len(items) != 5 || items[0]["id"] != "a" || items[0]["hasVector"] != true || items[3]["hasVector"] != false {
		t.Fatalf("scan docs = %v", items)
	}
	if _, ok := items[0]["vector"]; ok {
		t.Fatal("scan returned a vector")
	}
	// Delete, clear.
	mustApply(t, x, map[string]any{"ops": []any{
		map[string]any{"op": "delete", "coll": "docs", "id": "a"},
		map[string]any{"op": "delete", "coll": "docs", "id": "never"},
		map[string]any{"op": "stateSet", "coll": "state", "key": "cy/1", "value": nil},
	}}, nil)
	if c, _ := x.docs.Count(bg); c != 4 {
		t.Fatalf("after delete: %d", c)
	}
	if g, _ := x.get("state", "cy/1"); g != nil {
		t.Fatalf("state deleted still there: %v", g)
	}
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "clearDocs", "coll": "docs"}}}, nil)
	if c, _ := x.docs.Count(bg); c != 0 {
		t.Fatalf("after clearDocs: %d", c)
	}
	if err := x.flush(10 * time.Millisecond); err != nil {
		t.Fatalf("flush: %v", err)
	}
}

func TestIndexTextRefusedWithoutTextSearch(t *testing.T) {
	x := newIndex(t)
	if _, err := x.text("a", 1, ""); codeOf(err) != codeRefused {
		t.Fatalf("text before bind: %v", err)
	}
	mustBind(t, x, `{"dim":2,"metric":"l2","fields":[],"textSearch":false}`)
	if _, err := x.text("a", 1, ""); codeOf(err) != codeRefused {
		t.Fatalf("text without textSearch: %v", err)
	}
	if _, err := x.knn([]float32{1, 0}, 1, ""); err != nil {
		t.Fatalf("knn on an empty bound index: %v", err)
	}
}

// Equal BM25 scores come back by id, whatever the insertion order
// (measured: without the sort they come in insertion order).
func TestIndexTextTieOrder(t *testing.T) {
	for _, order := range [][]string{{"d", "b", "f", "a", "e", "c"}, {"c", "a", "e", "f", "b", "d"}} {
		x := newIndex(t)
		mustBind(t, x, `{"dim":2,"metric":"cosine","fields":[],"textSearch":true}`)
		var rows []upsert
		for _, id := range order {
			rows = append(rows, upsert{id: id, text: "same words here"})
		}
		ops, buf := upserts(rows...)
		mustApply(t, x, ops, buf)
		r, err := x.text("words", 2, "")
		if err != nil {
			t.Fatal(err)
		}
		if got := ids(r); len(got) != 2 || got[0] != "a" || got[1] != "b" {
			t.Fatalf("order %v: text = %v, want [a b]", order, got)
		}
	}
}

// Every malformed request is INVALID_ARGUMENT, and nothing of it lands.
func TestIndexApplyFuzzNothingApplied(t *testing.T) {
	x := newIndex(t)
	mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[{"key":"k","type":"string"}],"textSearch":true}`)
	good := unit(4, 0, 0.2)
	nan := []float32{1, float32(math.NaN()), 0, 0}
	inf := []float32{1, float32(math.Inf(1)), 0, 0}
	huge := []float32{3e19, 0, 0, 0}
	up := func(id string, off, dim any) map[string]any {
		return map[string]any{"op": "upsert", "coll": "docs", "id": id, "text": "t", "vector": map[string]any{"offset": off, "dim": dim}}
	}
	type tc struct {
		name   string
		ops    any
		floats []float32
		n      int64 // vector_floats; -1 = len(floats)
		nilBuf bool
	}
	two := append(append([]float32{}, good...), good...)
	cases := []tc{
		{"negative offset", map[string]any{"ops": []any{up("a", -4, 4)}}, good, -1, false},
		{"offset past the buffer", map[string]any{"ops": []any{up("a", 4, 4)}}, good, -1, false},
		{"truncated buffer", map[string]any{"ops": []any{up("a", 0, 4)}}, good[:3], -1, false},
		{"slot longer than the buffer", map[string]any{"ops": []any{up("a", 0, 4)}}, good, 2, false},
		{"overflowing offset", map[string]any{"ops": []any{up("a", int64(math.MaxInt64-2), 4)}}, good, -1, false},
		{"overflowing count", map[string]any{"ops": []any{up("a", 0, 4)}}, good, math.MaxInt64, false},
		{"negative count", map[string]any{"ops": []any{up("a", 0, 4)}}, good, -4, false},
		{"NULL buffer", map[string]any{"ops": []any{up("a", 0, 4)}}, nil, 4, true},
		{"wrong dim", map[string]any{"ops": []any{up("a", 0, 3)}}, good[:3], -1, false},
		{"gap between slots", map[string]any{"ops": []any{up("a", 0, 4), up("b", 4, 4)}}, append(two, 0, 0, 0, 0), -1, false},
		{"slots out of order", map[string]any{"ops": []any{up("a", 4, 4), up("b", 0, 4)}}, two, -1, false},
		{"overlapping slots", map[string]any{"ops": []any{up("a", 0, 4), up("b", 0, 4)}}, two, -1, false},
		{"unused tail", map[string]any{"ops": []any{up("a", 0, 4)}}, two, -1, false},
		{"NaN", map[string]any{"ops": []any{up("a", 0, 4)}}, nan, -1, false},
		{"Inf", map[string]any{"ops": []any{up("a", 0, 4)}}, inf, -1, false},
		{"huge norm", map[string]any{"ops": []any{up("a", 0, 4)}}, huge, -1, false},
		{"NaN in the second slot", map[string]any{"ops": []any{up("a", 0, 4), up("b", 4, 4)}}, append(append([]float32{}, good...), nan...), -1, false},
		{"vector without dim", map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": "a", "vector": map[string]any{"offset": 0}}}}, good, -1, false},
		{"unknown op", map[string]any{"ops": []any{map[string]any{"op": "drop"}}}, nil, -1, false},
		{"unknown field", map[string]any{"ops": []any{map[string]any{"op": "delete", "coll": "docs", "id": "a", "x": 1}}}, nil, -1, false},
		{"field of another op", map[string]any{"ops": []any{map[string]any{"op": "delete", "coll": "docs", "id": "a", "text": "t"}}}, nil, -1, false},
		{"empty id", map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": ""}}}, nil, -1, false},
		{"bad coll", map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "state", "id": "a"}}}, nil, -1, false},
		{"shadow without begin", map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "shadow", "id": "a"}}}, nil, -1, false},
		{"swap without shadow", map[string]any{"ops": []any{map[string]any{"op": "shadowSwap"}}}, nil, -1, false},
		{"f not bound", map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": "a", "f": map[string]any{"other": "x"}}}}, nil, -1, false},
		{"f wrong type", map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": "a", "f": map[string]any{"k": 1}}}}, nil, -1, false},
		{"f bad key", map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": "a", "f": map[string]any{"K.x": "x"}}}}, nil, -1, false},
		{"stateSet non-string", map[string]any{"ops": []any{map[string]any{"op": "stateSet", "coll": "state", "key": "k", "value": 1}}}, nil, -1, false},
		{"cas without key", map[string]any{"cas": []any{map[string]any{"expect": nil}}, "ops": []any{}}, nil, -1, false},
		{"valid then bad", map[string]any{"ops": []any{up("ok", 0, 4), map[string]any{"op": "bogus"}}}, good, -1, false},
		{"not JSON", "{", nil, -1, false},
	}
	for _, c := range cases {
		var b []byte
		if s, ok := c.ops.(string); ok {
			b = []byte(s)
		} else {
			b, _ = json.Marshal(c.ops)
		}
		n := int64(len(c.floats))
		if c.n != -1 {
			n = c.n
		}
		var p unsafe.Pointer
		if len(c.floats) > 0 && !c.nilBuf {
			p = unsafe.Pointer(&c.floats[0])
		}
		_, err := x.apply(string(b), p, n)
		if codeOf(err) != codeInvalidArgument {
			t.Errorf("%s: code %d (%v), want INVALID_ARGUMENT", c.name, codeOf(err), err)
		}
		runtime.KeepAlive(c.floats)
	}
	if c, _ := x.docs.Count(bg); c != 0 {
		t.Fatalf("%d rows landed from invalid requests", c)
	}
	s, _ := x.scan("state", "", "", 0)
	if len(s["items"].([]map[string]any)) != 0 {
		t.Fatalf("state landed: %v", s)
	}
}

func TestIndexCasConflictAppliesNothing(t *testing.T) {
	x := newIndex(t)
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "stateSet", "coll": "state", "key": "gen", "value": "g1"}}}, nil)
	req := func(expect any) map[string]any {
		return map[string]any{
			"cas": []any{map[string]any{"key": "gen", "expect": expect}, map[string]any{"key": "none", "expect": nil}},
			"ops": []any{
				map[string]any{"op": "upsert", "coll": "docs", "id": "r", "text": "x"},
				map[string]any{"op": "stateSet", "coll": "state", "key": "gen", "value": "g2"},
			},
		}
	}
	for _, miss := range []any{"g0", nil} {
		if _, err := applyJSON(x, req(miss), nil); codeOf(err) != codeConflict {
			t.Fatalf("expect %v: %v, want CONFLICT", miss, err)
		}
		if c, _ := x.docs.Count(bg); c != 0 {
			t.Fatal("a row landed with a missed CAS")
		}
	}
	if _, err := applyJSON(x, req("g1"), nil); err != nil {
		t.Fatal(err)
	}
	if g, _ := x.get("state", "gen"); g["value"] != "g2" {
		t.Fatalf("gen = %v", g)
	}
}

func TestIndexShadowSwapAndReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "index.anystore")
	x := mustOpenIndex(t, path, testKey)
	mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[{"key":"k","type":"string"}],"textSearch":true}`)
	ops, buf := upserts(upsert{id: "old", text: "old row", vec: unit(4, 0, 0)})
	mustApply(t, x, ops, buf)
	// Begin and fill the shadow in one apply, the second page in another.
	ops, buf = upserts(upsert{id: "n1", text: "new one", coll: "shadow", vec: unit(4, 1, 0), f: map[string]any{"k": "v"}})
	ops["ops"] = append([]map[string]any{{"op": "shadowBegin"}}, ops["ops"].([]map[string]any)...)
	mustApply(t, x, ops, buf)
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "stateSet", "coll": "shadowState", "key": "cursor", "value": "7"}}}, nil)
	if g, _ := x.get("shadow", "n1"); g == nil {
		t.Fatal("shadow row missing")
	}
	if c, _ := x.docs.Count(bg); c != 1 {
		t.Fatalf("active changed before the swap: %d", c)
	}
	// A shadow begun again starts empty.
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "shadowBegin"}}}, nil)
	if g, _ := x.get("shadow", "n1"); g != nil {
		t.Fatal("shadowBegin kept the previous shadow")
	}
	ops, buf = upserts(upsert{id: "n2", text: "new two", coll: "shadow", vec: unit(4, 2, 0)})
	ops["ops"] = append(ops["ops"].([]map[string]any),
		map[string]any{"op": "stateSet", "coll": "shadowState", "key": "cursor", "value": "9"},
		map[string]any{"op": "shadowSwap"},
		map[string]any{"op": "upsert", "coll": "docs", "id": "after-swap", "text": "x", "vector": nil})
	mustApply(t, x, ops, buf)
	// gen 0 active, gen 1 the first shadow (orphaned by the second
	// begin), gen 2 swapped in; 0 and 1 are orphans now.
	if x.active != 2 || x.shDocs != nil || x.orphanCount() != 2 {
		t.Fatalf("active %d shadow %v orphans %v", x.active, x.shDocs != nil, x.orphans)
	}
	if g, _ := x.get("docs", "n2"); g == nil {
		t.Fatal("swapped-in row missing")
	}
	if g, _ := x.get("docs", "old"); g != nil {
		t.Fatal("old generation row still visible")
	}
	if g, _ := x.get("state", "cursor"); g["value"] != "9" {
		t.Fatalf("state after swap: %v", g)
	}
	if r, err := x.text("two", 5, ""); err != nil || len(ids(r)) != 1 {
		t.Fatalf("text index on the new generation: %v %v", r, err)
	}
	// An unswapped shadow and the old generations are recorded at the
	// next open, and index_gc drops them.
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "shadowBegin"}}}, nil)
	if err := x.close(); err != nil {
		t.Fatal(err)
	}
	y := mustOpenIndex(t, path, testKey)
	if y.orphanCount() != 3 || y.active != 2 {
		t.Fatalf("after reopen: active %d orphans %v", y.active, y.orphans)
	}
	for i := 0; ; i++ {
		done, err := y.gc(maxWait)
		if err != nil {
			t.Fatal(err)
		}
		if done {
			break
		}
		if i > 100 {
			t.Fatal("gc never finished")
		}
	}
	names, _ := y.db.GetCollectionNames(bg)
	for _, n := range names {
		if n != "meta" && n != "docs_2" && n != "state_2" {
			t.Fatalf("collections after gc: %v", names)
		}
	}
	// A new shadow never reuses a number: it is past every generation.
	mustApply(t, y, map[string]any{"ops": []any{map[string]any{"op": "shadowBegin"}}}, nil)
	if y.shadowGen != 4 {
		t.Fatalf("new shadow generation %d, want 4", y.shadowGen)
	}
	if c, _ := y.docs.Count(bg); c != 2 {
		t.Fatalf("rows after reopen: %d", c)
	}
}

// A swap re-points the live handle while readers run: no reader ever
// sees a closed collection.
func TestIndexSwapWithConcurrentReaders(t *testing.T) {
	x := newIndex(t)
	mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[],"textSearch":true}`)
	ops, buf := upserts(upsert{id: "a", text: "alpha", vec: unit(4, 0, 0)})
	mustApply(t, x, ops, buf)
	stop := make(chan struct{})
	errs := make(chan error, 64)
	var wg sync.WaitGroup
	for r := 0; r < 4; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				leave, err := x.enter()
				if codeOf(err) == codePending {
					continue // a swap holds the index: the export answers PENDING
				}
				if err != nil {
					errs <- err
					return
				}
				_, e1 := x.knn(unit(4, 0, 0), 5, "")
				_, e2 := x.text("alpha", 5, "")
				_, e3 := x.docs.Count(bg)
				_, e4 := x.get("docs", "a")
				_, e5 := x.scan("docs", "", "", 10)
				leave()
				for _, e := range []error{e1, e2, e3, e4, e5} {
					if e != nil {
						errs <- e
						return
					}
				}
			}
		}()
	}
	for i := 0; i < 30; i++ {
		ops, buf := upserts(upsert{id: "a", text: "alpha", coll: "shadow", vec: unit(4, i, 0)})
		all := []map[string]any{{"op": "shadowBegin"}}
		all = append(all, ops["ops"].([]map[string]any)...)
		all = append(all, map[string]any{"op": "shadowSwap"})
		mustApply(t, x, map[string]any{"ops": all}, buf)
	}
	close(stop)
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Fatalf("reader during swaps: %v", e)
	}
	if x.active != 30 || x.orphanCount() != 30 {
		t.Fatalf("active = %d, orphans %d", x.active, x.orphanCount())
	}
}

func TestIndexOwnerTokenAndRelease(t *testing.T) {
	path := filepath.Join(t.TempDir(), "index.anystore")
	x, err := openIndex(idxOpts(path, "", "gen1"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := openIndex(idxOpts(path, "", "gen2")); codeOf(err) != codeBusy {
		t.Fatalf("other token: %v, want BUSY", err)
	}
	if _, err := openIndex(idxOpts(path, "", "gen1")); codeOf(err) != codeRefused {
		t.Fatalf("same token: %v, want REFUSED", err)
	}
	h := handles.add(x)
	releaseIndex(h)
	releaseIndex(h) // stale: no-op
	releaseIndex(0)
	releaseIndex(1 << 62)
	var y *localIndex
	deadline := time.Now().Add(5 * time.Second)
	for {
		y, err = openIndex(idxOpts(path, "", "gen2"))
		if err == nil {
			break
		}
		if codeOf(err) != codeBusy || time.Now().After(deadline) {
			t.Fatalf("open after release: %v", err)
		}
		time.Sleep(5 * time.Millisecond)
	}
	defer y.close()
	if _, err := lookup[*localIndex](h, "an index"); codeOf(err) != codeClosed {
		t.Fatalf("released handle: %v", err)
	}
	// An account handle passed as an index is not released.
	a := handles.add("not an index")
	releaseIndex(a)
	if _, err := lookup[string](a, "x"); err != nil {
		t.Fatalf("release took a handle of another kind: %v", err)
	}
	handles.remove(a)
}

func TestLockFileRefusesSecondHolder(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.lock")
	f, err := lockFile(p)
	if err != nil {
		t.Fatal(err)
	}
	// flock belongs to the open file description: a second open in the
	// same process stands for another process.
	if _, err := lockFile(p); codeOf(err) != codeBusy {
		t.Fatalf("second lock: %v, want BUSY", err)
	}
	if err := unlockFile(f); err != nil {
		t.Fatal(err)
	}
	g, err := lockFile(p)
	if err != nil {
		t.Fatalf("lock after unlock: %v", err)
	}
	unlockFile(g)
}

// The keycheck protocol, through every state a crash can leave.
func TestIndexKeycheckCrashMatrix(t *testing.T) {
	type setup func(t *testing.T, path string)
	create := func(key string) setup {
		return func(t *testing.T, path string) {
			x, err := openIndex(idxOpts(path, key, "t0"))
			if err != nil {
				t.Fatal(err)
			}
			mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "stateSet", "coll": "state", "key": "k", "value": "v"}}}, nil)
			if err := x.close(); err != nil {
				t.Fatal(err)
			}
		}
	}
	other := strings.Repeat("cd", 32)
	cases := []struct {
		name  string
		setup []setup
		key   string
		code  int
		keeps bool // the old state value is still there
	}{
		{"nothing", nil, testKey, codeOK, false},
		{"directory only", []setup{func(t *testing.T, p string) { os.MkdirAll(filepath.Dir(p), 0o700) }}, testKey, codeOK, false},
		{"sidecar tmp only", []setup{func(t *testing.T, p string) {
			os.WriteFile(p+".keycheck.tmp", []byte(`{"fmt":1,"fileId":"half`), 0o600)
		}}, testKey, codeOK, false},
		{"sidecar without file", []setup{create(other), func(t *testing.T, p string) {
			for _, s := range []string{"", "-wal", "-wal-shm", "-shm"} {
				os.Remove(p + s)
			}
		}}, testKey, codeOK, false},
		{"file without sidecar", []setup{create(testKey), func(t *testing.T, p string) { os.Remove(p + ".keycheck") }}, testKey, codeCorrupt, false},
		{"file and a tmp sidecar only", []setup{create(testKey), func(t *testing.T, p string) {
			os.Rename(p+".keycheck", p+".keycheck.tmp")
		}}, testKey, codeCorrupt, false},
		{"reopen with the same key", []setup{create(testKey)}, testKey, codeOK, true},
		{"reopen plain", []setup{create("")}, "", codeOK, true},
		{"wrong key", []setup{create(testKey)}, other, codeKeyMismatch, false},
		{"missing key", []setup{create(testKey)}, "", codeKeyMissing, false},
		{"plain file and a key", []setup{create("")}, testKey, codeKeyMismatch, false},
		{"sidecar of another file", []setup{create(testKey), func(t *testing.T, p string) {
			// A valid sidecar for the same key but another fileId.
			kc, _ := newKeycheck(mustHex(testKey))
			if err := writeKeycheck(p+".keycheck", kc); err != nil {
				t.Fatal(err)
			}
		}}, testKey, codeKeyMismatch, false},
		{"unparseable sidecar", []setup{create(testKey), func(t *testing.T, p string) {
			os.WriteFile(p+".keycheck", []byte("{"), 0o600)
		}}, testKey, codeCorrupt, false},
		{"damaged encrypted file", []setup{create(testKey), func(t *testing.T, p string) { damage(t, p) }}, testKey, codeCorrupt, false},
		{"damaged plain file", []setup{create(""), func(t *testing.T, p string) { damage(t, p) }}, "", codeCorrupt, false},
		{"sidecar plain, file encrypted", []setup{create(testKey), func(t *testing.T, p string) {
			kc, _ := newKeycheck(nil)
			writeKeycheck(p+".keycheck", kc)
		}}, "", codeInternal, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "loc", "index.anystore")
			os.MkdirAll(filepath.Dir(path), 0o700)
			for _, s := range c.setup {
				s(t, path)
			}
			x, err := openIndex(idxOpts(path, c.key, "t1"))
			if codeOf(err) != c.code {
				t.Fatalf("code %d (%v), want %d", codeOf(err), err, c.code)
			}
			if err != nil {
				return
			}
			defer x.close()
			g, _ := x.get("state", "k")
			if (g != nil) != c.keeps {
				t.Fatalf("state k = %v, keeps %v", g, c.keeps)
			}
			kc, err := readKeycheck(path + ".keycheck")
			if err != nil || kc == nil || kc.FileId != x.fileId {
				t.Fatalf("sidecar %v %v, fileId %s", kc, err, x.fileId)
			}
			if _, err := os.Stat(path + ".keycheck.tmp"); !os.IsNotExist(err) {
				t.Fatal("tmp sidecar left behind")
			}
		})
	}
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// damage overwrites the database's pages after the first, so the open
// (or the read of meta) meets pages that fail their integrity check.
func damage(t *testing.T, path string) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < len(b); i++ {
		b[i] ^= 0x5a
	}
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// A directory the process may not write is ANY_SHIM_ERR_IO, never
// CORRUPT. Classified by errno (EACCES), not by message text.
func TestIndexOpenPermissionIsIO(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs POSIX permissions and a non-root user")
	}
	dir := filepath.Join(t.TempDir(), "ro")
	os.MkdirAll(dir, 0o700)
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o700)
	_, err := openIndex(idxOpts(filepath.Join(dir, "index.anystore"), "", "t"))
	if codeOf(err) != codeIO {
		t.Fatalf("read-only directory: code %d (%v), want IO", codeOf(err), err)
	}
}

func TestIndexOpenOptions(t *testing.T) {
	dir := t.TempDir()
	for _, bad := range []string{
		`{"keyHex":"","ownerToken":"t"}`,
		fmt.Sprintf(`{"path":%q}`, filepath.Join(dir, "a")),
		fmt.Sprintf(`{"path":%q,"ownerToken":"t","keyHex":"abcd"}`, filepath.Join(dir, "a")),
		fmt.Sprintf(`{"path":%q,"ownerToken":"t","keyHex":%q}`, filepath.Join(dir, "a"), strings.Repeat("zz", 32)),
		fmt.Sprintf(`{"path":%q,"ownerToken":"t","passphrase":"x"}`, filepath.Join(dir, "a")),
		fmt.Sprintf(`{"path":%q,"ownerToken":"t","dim":4}`, filepath.Join(dir, "a")),
	} {
		if _, err := openIndex(bad); codeOf(err) != codeInvalidArgument {
			t.Errorf("%s: %v, want INVALID_ARGUMENT", bad, err)
		}
	}
}

// Results built inside an iteration must not alias the iterator's buffer.
func TestIndexResultsDoNotAliasIteratorBuffer(t *testing.T) {
	x := newIndex(t)
	mustBind(t, x, `{"dim":4,"metric":"cosine","fields":[],"textSearch":false}`)
	var rows []upsert
	for i := 0; i < 20; i++ {
		rows = append(rows, upsert{id: fmt.Sprintf("d%02d", i), text: "t", vec: unit(4, i, 0.3)})
	}
	ops, buf := upserts(rows...)
	for i, op := range ops["ops"].([]map[string]any) {
		op["meta"] = map[string]any{"category": "c", "index": i, fmt.Sprintf("key_%02d", i): true}
	}
	mustApply(t, x, ops, buf)
	r, err := x.knn(unit(4, 0, 0.3), 20, "")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(r)
	var back struct {
		Results []struct {
			Id   string         `json:"id"`
			Meta map[string]any `json:"meta"`
		} `json:"results"`
	}
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if len(back.Results) != 20 {
		t.Fatalf("%d results", len(back.Results))
	}
	for _, res := range back.Results {
		var i int
		fmt.Sscanf(res.Id, "d%02d", &i)
		if len(res.Meta) != 3 || res.Meta[fmt.Sprintf("key_%02d", i)] != true {
			t.Fatalf("%s meta = %v", res.Id, res.Meta)
		}
	}
}

// A database file the process may not write (any-store's own open fails)
// is ANY_SHIM_ERR_IO, never CORRUPT.
func TestIndexReadOnlyFileIsIO(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs POSIX permissions and a non-root user")
	}
	path := filepath.Join(t.TempDir(), "index.anystore")
	x, err := openIndex(idxOpts(path, "", "t"))
	if err != nil {
		t.Fatal(err)
	}
	x.close()
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(path, 0o600)
	_, err = openIndex(idxOpts(path, "", "t"))
	if codeOf(err) != codeIO {
		t.Fatalf("read-only file: code %d (%v), want IO", codeOf(err), err)
	}
}

// Binds that grow the config while applies, swaps and reads run (the
// race detector holds the locking to account).
func TestIndexBindApplySwapConcurrently(t *testing.T) {
	x := newIndex(t)
	mustBind(t, x, `{"dim":2,"metric":"cosine","fields":[],"textSearch":false}`)
	var wg sync.WaitGroup
	errs := make(chan error, 100)
	wg.Add(3)
	go func() {
		defer wg.Done()
		for i := 0; i < 20; i++ {
			if _, err := x.bind(fmt.Sprintf(`{"dim":2,"metric":"cosine","fields":[{"key":"k%d","type":"string"}],"textSearch":%v}`, i, i%2 == 0)); err != nil {
				errs <- err
			}
		}
	}()
	// Index calls answer PENDING while a bind or a swap holds the index:
	// they are retried, as the Dart side does.
	retry := func(f func() error) error {
		for {
			err := f()
			if codeOf(err) != codePending {
				return err
			}
			time.Sleep(time.Millisecond)
		}
	}
	go func() {
		defer wg.Done()
		for i := 0; i < 40; i++ {
			ops, buf := upserts(upsert{id: fmt.Sprint(i), text: "t", vec: []float32{1, float32(i)}})
			if err := retry(func() error { _, err := applyJSON(x, ops, buf); return err }); err != nil {
				errs <- err
			}
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 10; i++ {
			if err := retry(func() error {
				_, err := applyJSON(x, map[string]any{"ops": []any{map[string]any{"op": "shadowBegin"}, map[string]any{"op": "shadowSwap"}}}, nil)
				return err
			}); err != nil {
				errs <- err
			}
			err := retry(func() error {
				leave, err := x.enter()
				if err != nil {
					return err
				}
				defer leave()
				_ = x.info()
				_, err = x.knn([]float32{1, 0}, 3, "")
				return err
			})
			if err != nil {
				errs <- err
			}
		}
	}()
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	if got := x.info(); len(got["fields"].([]map[string]any)) != 20 {
		t.Fatalf("fields after concurrent binds: %v", got["fields"])
	}
}
