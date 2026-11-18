package main

import (
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
	"path/filepath"
	"testing"
)

func mustOpenIndex(t *testing.T, opts map[string]any) *localIndex {
	t.Helper()
	b, _ := json.Marshal(opts)
	x, err := openIndex(string(b))
	if err != nil {
		t.Fatalf("openIndex: %v", err)
	}
	t.Cleanup(func() { _ = x.close() })
	return x
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

func TestIndexExactKnnFilterAndText(t *testing.T) {
	x := mustOpenIndex(t, map[string]any{
		"path": filepath.Join(t.TempDir(), "i.db"), "dim": 8, "filterFields": []string{"cat"},
	})
	docs := []struct {
		id, text, cat string
		axis          int
	}{
		{"a", "methane on titan", "space", 0},
		{"b", "bread and butter", "food", 1},
		{"c", "rings of saturn", "space", 2},
		{"d", "pasta with basil", "food", 3},
	}
	for _, d := range docs {
		doc, _ := json.Marshal(map[string]any{"id": d.id, "name": d.id, "text": d.text, "meta": map[string]any{"cat": d.cat}})
		if err := x.upsert(string(doc), unit(8, d.axis, 0.1)); err != nil {
			t.Fatal(err)
		}
	}
	r, err := x.knn(unit(8, 1, 0.1), 1, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 1 || got[0] != "b" {
		t.Fatalf("knn = %v, want [b]", got)
	}
	r, err = x.knn(unit(8, 1, 0.1), 4, `{"meta.cat":"space"}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 2 || got[0] != "a" && got[0] != "c" {
		t.Fatalf("filtered knn = %v, want the two space docs", got)
	}
	r, err = x.text("methane", 5, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 1 || got[0] != "a" {
		t.Fatalf("text = %v, want [a]", got)
	}
	r, err = x.text("pasta", 5, `{"meta.cat":"space"}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != 0 {
		t.Fatalf("filtered text = %v, want none", got)
	}
	found, err := x.delete("a")
	if err != nil || !found {
		t.Fatalf("delete a = %v, %v", found, err)
	}
	found, err = x.delete("a")
	if err != nil || found {
		t.Fatalf("second delete a = %v, %v; want not found, no error", found, err)
	}
	if n, _ := x.docs.Count(bg); n != 3 {
		t.Fatalf("count = %d, want 3", n)
	}
}

func TestIndexRejectsBadInput(t *testing.T) {
	x := mustOpenIndex(t, map[string]any{"path": filepath.Join(t.TempDir(), "i.db"), "dim": 4})
	cases := []struct {
		name string
		err  error
	}{
		{"wrong dim", x.upsert(`{"id":"a"}`, []float32{1, 2, 3})},
		{"NaN", x.upsert(`{"id":"a"}`, []float32{1, float32(math.NaN()), 0, 0})},
		{"no id", x.upsert(`{"name":"a"}`, []float32{1, 0, 0, 0})},
		{"not an object", x.upsert(`[1]`, []float32{1, 0, 0, 0})},
		{"embedded vector", x.upsert(`{"id":"a","embedding":[1,0,0,0]}`, []float32{1, 0, 0, 0})},
	}
	for _, c := range cases {
		if codeOf(c.err) != codeInvalidArgument {
			t.Errorf("%s: code %d (%v), want invalid argument", c.name, codeOf(c.err), c.err)
		}
	}
	if _, err := x.knn([]float32{1, 0, 0, 0}, 0, ""); codeOf(err) != codeInvalidArgument {
		t.Errorf("k=0: %v", err)
	}
	if _, err := x.knn([]float32{1, 0, 0, 0}, 1, "{not json"); codeOf(err) != codeInvalidArgument {
		t.Errorf("bad filter: %v", err)
	}
}

func TestIndexOptionsAndReopen(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "i.db")
	for _, bad := range []string{
		`{"dim":4}`,
		`{"path":"p","dim":0}`,
		`{"path":"p","dim":4,"metric":"hamming"}`,
		`{"path":"p","dim":4,"filterFields":["a.b"]}`,
		`{"path":"p","dim":4,"hnsw":{"m":8}}`,
		`{"path":"p","dim":4,"unknown":1}`,
	} {
		if _, err := openIndex(bad); codeOf(err) != codeInvalidArgument {
			t.Errorf("%s: %v, want invalid argument", bad, err)
		}
	}
	if _, err := openIndex(`{"path":"p","dim":4,"mode":"ivfsq"}`); codeOf(err) != codeRefused {
		t.Errorf("ivfsq: %v, want refused", err)
	}

	x, err := openIndex(fmt.Sprintf(`{"path":%q,"dim":4,"passphrase":"correct horse"}`, path))
	if err != nil {
		t.Fatal(err)
	}
	if err := stateSet(x.state, "cursor", "42"); err != nil {
		t.Fatal(err)
	}
	if err := x.close(); err != nil {
		t.Fatal(err)
	}
	if err := x.close(); codeOf(err) != codeClosed {
		t.Fatalf("second close: %v", err)
	}
	if _, err := openIndex(fmt.Sprintf(`{"path":%q,"dim":4}`, path)); err == nil {
		t.Fatal("an encrypted index opened without its passphrase")
	}
	if _, err := openIndex(fmt.Sprintf(`{"path":%q,"dim":8,"passphrase":"correct horse"}`, path)); codeOf(err) != codeInvalidArgument {
		t.Fatalf("reopen with another dim: %v, want invalid argument", err)
	}
	x, err = openIndex(fmt.Sprintf(`{"path":%q,"dim":4,"passphrase":"correct horse"}`, path))
	if err != nil {
		t.Fatal(err)
	}
	defer x.close()
	if v, ok, err := stateGet(x.state, "cursor"); err != nil || !ok || v != "42" {
		t.Fatalf("state after reopen = %q %v %v", v, ok, err)
	}
}

// In hnsw mode a filter on a field without a range index is applied to
// the ANN candidates (any-store's DRIVER plan, ef = 10 x k by default), so
// a selective one comes back short. The shim re-runs it with a larger ef.
// (A filter on an indexed field is probed exactly by any-store itself.)
func TestIndexHnswFilteredKnnReturnsK(t *testing.T) {
	const dim, n, k = 16, 3000, 5
	x := mustOpenIndex(t, map[string]any{
		"path": filepath.Join(t.TempDir(), "i.db"), "dim": dim, "mode": "hnsw",
	})
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < n; i++ {
		bucket := "common"
		if i%150 == 0 {
			bucket = "rare" // 20 documents
		}
		v := make([]float32, dim)
		for j := range v {
			v[j] = rng.Float32()*2 - 1
		}
		doc, _ := json.Marshal(map[string]any{"id": fmt.Sprintf("d%04d", i), "meta": map[string]any{"bucket": bucket}})
		if err := x.upsert(string(doc), v); err != nil {
			t.Fatal(err)
		}
	}
	q := make([]float32, dim)
	for j := range q {
		q[j] = rng.Float32()*2 - 1
	}
	r, err := x.knn(q, k, `{"meta.bucket":"rare"}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(r); len(got) != k {
		t.Fatalf("filtered hnsw knn returned %d (%v), want %d; ef %v after %v attempts", len(got), got, k, r["ef"], r["attempts"])
	}
	if r["attempts"].(int) < 2 {
		t.Fatalf("the first run already returned k: the test no longer exercises the retry")
	}
	for _, id := range ids(r) {
		var i int
		fmt.Sscanf(id, "d%04d", &i)
		if i%150 != 0 {
			t.Fatalf("%s is not in the filter", id)
		}
	}
}

// Results built inside an iteration must not alias the iterator's buffer:
// any-store reuses it for the next document, and GoType keeps object keys
// pointing into it.
func TestIndexResultsDoNotAliasIteratorBuffer(t *testing.T) {
	x := mustOpenIndex(t, map[string]any{"path": filepath.Join(t.TempDir(), "i.db"), "dim": 4})
	for i := 0; i < 20; i++ {
		doc, _ := json.Marshal(map[string]any{
			"id":   fmt.Sprintf("d%02d", i),
			"name": fmt.Sprintf("doc %d", i),
			"meta": map[string]any{"category": "c", "index": i, fmt.Sprintf("key_%02d", i): true},
		})
		if err := x.upsert(string(doc), unit(4, i, 0.3)); err != nil {
			t.Fatal(err)
		}
	}
	r, err := x.knn(unit(4, 0, 0.3), 20, "")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(r) // marshalled after the iteration, as the export does
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
		want := map[string]bool{"category": true, "index": true, fmt.Sprintf("key_%02d", i): true}
		if len(res.Meta) != 3 {
			t.Fatalf("%s meta = %v", res.Id, res.Meta)
		}
		for k := range res.Meta {
			if !want[k] {
				t.Fatalf("%s meta has key %q: %v", res.Id, k, res.Meta)
			}
		}
	}
}
