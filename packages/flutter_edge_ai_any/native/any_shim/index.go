package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"sync"
	"sync/atomic"
	"unsafe"

	anystore "github.com/anyproto/any-store/v2"
	"github.com/anyproto/any-store/v2/anyenc"
	"github.com/anyproto/any-store/v2/query"
)

// The local index is one any-store database per device. It is derived
// data: rebuilt from the space by the consumer, never synced.
//
//	collection "docs":  {id, name, text, meta, embedding}, with the vector
//	                    index "vec", the full-text index "fts" on
//	                    name+text, and a range index per meta filter field
//	collection "state": {id, v}, the consumer's cursor and generation,
//	                    plus configKey, the vector parameters the
//	                    database was created with
const (
	docsCollection  = "docs"
	stateCollection = "state"
	vectorField     = "embedding"
	vectorIndexName = "vec"
	configKey       = "_any_shim_index_config"
)

type hnswOpts struct {
	M              int `json:"m"`
	EfConstruction int `json:"efConstruction"`
	EfSearch       int `json:"efSearch"`
}

type indexOpts struct {
	Path         string    `json:"path"`
	Dim          int       `json:"dim"`
	Metric       string    `json:"metric"`
	Mode         string    `json:"mode"`
	HNSW         *hnswOpts `json:"hnsw"`
	FilterFields []string  `json:"filterFields"`
	Passphrase   string    `json:"passphrase"`
}

// indexConfig is what must not change across opens of one database.
type indexConfig struct {
	Dim    int    `json:"dim"`
	Metric string `json:"metric"`
	Mode   string `json:"mode"`
}

type localIndex struct {
	db    anystore.DB
	docs  anystore.Collection
	state anystore.Collection
	cfg   indexConfig

	ops    sync.RWMutex
	closed atomic.Bool
}

var bg = context.Background()

func vectorParams(o indexOpts) (*anystore.VectorParams, error) {
	vp := &anystore.VectorParams{Field: vectorField, Dim: o.Dim}
	switch o.Metric {
	case "cosine":
		vp.Metric = anystore.VectorCosine
	case "l2":
		vp.Metric = anystore.VectorL2
	case "dot":
		vp.Metric = anystore.VectorDot
	default:
		return nil, invalid("metric %q: expected cosine, l2 or dot", o.Metric)
	}
	switch o.Mode {
	case "exact":
		vp.Mode = anystore.VectorModeBruteForce
		if o.HNSW != nil {
			return nil, invalid("hnsw options need mode \"hnsw\"")
		}
	case "hnsw":
		vp.Mode = anystore.VectorModeBTree
		if h := o.HNSW; h != nil {
			if h.M < 0 || h.EfConstruction < 0 || h.EfSearch < 0 {
				return nil, invalid("hnsw options must not be negative")
			}
			vp.M, vp.EfConstruction, vp.EfSearch = h.M, h.EfConstruction, h.EfSearch
		}
	default:
		// IVF-SQ trains its cells on the data present when the index is
		// built, and an index is built empty here.
		return nil, withCode(codeRefused, "index mode %q is not supported: use \"exact\" or \"hnsw\"", o.Mode)
	}
	return vp, nil
}

func openIndex(optsJSON string) (_ *localIndex, err error) {
	var o indexOpts
	if err := decodeStrict(optsJSON, &o); err != nil {
		return nil, err
	}
	if o.Path == "" {
		return nil, invalid("path is required")
	}
	if o.Dim <= 0 {
		return nil, invalid("dim must be positive, got %d", o.Dim)
	}
	if o.Metric == "" {
		o.Metric = "cosine"
	}
	if o.Mode == "" {
		o.Mode = "exact"
	}
	vp, err := vectorParams(o)
	if err != nil {
		return nil, err
	}
	var fields []string
	for _, f := range o.FilterFields {
		f = strings.TrimSpace(f)
		if f == "" || strings.ContainsAny(f, ".$") {
			return nil, invalid("filter field %q: a plain meta key, without '.' or '$'", f)
		}
		fields = append(fields, f)
	}
	var cfg *anystore.Config
	if o.Passphrase != "" {
		cfg = &anystore.Config{Encryption: anystore.EncryptionConfig{Passphrase: []byte(o.Passphrase)}}
	}
	db, err := anystore.Open(bg, o.Path, cfg)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			_ = db.Close()
		}
	}()
	state, err := db.Collection(bg, stateCollection)
	if err != nil {
		return nil, err
	}
	want := indexConfig{Dim: o.Dim, Metric: o.Metric, Mode: o.Mode}
	if prev, ok, err := stateGet(state, configKey); err != nil {
		return nil, err
	} else if ok {
		var have indexConfig
		if err := json.Unmarshal([]byte(prev), &have); err != nil {
			return nil, fmt.Errorf("index config: %w", err)
		}
		if have != want {
			return nil, invalid("%s was created with dim %d, metric %s, mode %s; asked for dim %d, metric %s, mode %s",
				o.Path, have.Dim, have.Metric, have.Mode, want.Dim, want.Metric, want.Mode)
		}
	} else {
		b, _ := json.Marshal(want)
		if err := stateSet(state, configKey, string(b)); err != nil {
			return nil, err
		}
	}
	docs, err := db.Collection(bg, docsCollection)
	if err != nil {
		return nil, err
	}
	infos := []anystore.IndexInfo{
		{Name: vectorIndexName, Kind: anystore.IndexKindVector, Vector: vp},
		{Name: "fts", Kind: anystore.IndexKindFulltext, Fields: []string{"name", "text"}},
	}
	for _, f := range fields {
		infos = append(infos, anystore.IndexInfo{Fields: []string{"meta." + f}})
	}
	if err := docs.EnsureIndex(bg, infos...); err != nil {
		return nil, err
	}
	return &localIndex{db: db, docs: docs, state: state, cfg: want}, nil
}

func (x *localIndex) enter() (func(), error) {
	x.ops.RLock()
	if x.closed.Load() {
		x.ops.RUnlock()
		return nil, errClosed
	}
	return x.ops.RUnlock, nil
}

func (x *localIndex) close() error {
	if x.closed.Swap(true) {
		return errClosed
	}
	x.ops.Lock()
	defer x.ops.Unlock()
	return errors.Join(x.docs.Close(), x.state.Close(), x.db.Close())
}

func checkVector(v []float32, dim int) error {
	if len(v) != dim {
		return invalid("vector has %d dimensions, the index %d", len(v), dim)
	}
	for i, f := range v {
		if math.IsNaN(float64(f)) || math.IsInf(float64(f), 0) {
			return invalid("vector[%d] is not finite", i)
		}
	}
	return nil
}

func (x *localIndex) upsert(docJSON string, vec []float32) error {
	if err := checkVector(vec, x.cfg.Dim); err != nil {
		return err
	}
	d, err := anyenc.ParseJson(docJSON)
	if err != nil {
		return invalid("doc: %v", err)
	}
	if d.Type() != anyenc.TypeObject {
		return invalid("doc must be a JSON object")
	}
	if id := d.Get("id"); id == nil || id.Type() != anyenc.TypeString || len(id.GetStringBytes()) == 0 {
		return invalid("doc needs a non-empty string id")
	}
	if d.Get(vectorField) != nil {
		return invalid("doc must not carry %q: pass the vector separately", vectorField)
	}
	a := &anyenc.Arena{}
	d.Set(vectorField, a.NewVectorF32(vec))
	return x.docs.UpsertOne(bg, d)
}

func (x *localIndex) delete(id string) (bool, error) {
	if id == "" {
		return false, invalid("id is empty")
	}
	err := x.docs.DeleteId(bg, id)
	if errors.Is(err, anystore.ErrDocNotFound) {
		return false, nil
	}
	return err == nil, err
}

func parseFilter(s string) (query.Filter, error) {
	s = strings.TrimSpace(s)
	if s == "" || s == "{}" {
		return nil, nil
	}
	f, err := query.ParseCondition(s)
	if err != nil {
		return nil, invalid("filter: %v", err)
	}
	return f, nil
}

func collect(it anystore.Iterator, scoreKey string, score func() float64) ([]map[string]any, error) {
	defer it.Close()
	out := []map[string]any{}
	for it.Next() {
		d, err := it.Doc()
		if err != nil {
			return nil, err
		}
		v := d.Value()
		r := map[string]any{scoreKey: score(), "name": nil, "text": nil, "meta": nil}
		for _, k := range []string{"id", "name", "text", "meta"} {
			if f := v.Get(k); f != nil {
				r[k] = goValue(f)
			}
		}
		out = append(out, r)
	}
	return out, it.Err()
}

// knn runs the query; in hnsw mode a filtered query that comes back short
// while the collection holds more documents is re-run with a doubled ef
// (the ANN beam the filter is applied within), up to the collection size.
func (x *localIndex) knn(q []float32, k int, filter string) (map[string]any, error) {
	if err := checkVector(q, x.cfg.Dim); err != nil {
		return nil, err
	}
	if k <= 0 || k > query.KnnMaxK {
		return nil, invalid("k must be in 1..%d", query.KnnMaxK)
	}
	pf, err := parseFilter(filter)
	if err != nil {
		return nil, err
	}
	run := func(ef int) ([]map[string]any, error) {
		var opts []query.KnnOpt
		if ef > 0 {
			opts = append(opts, query.KnnEf(ef))
		}
		and := query.And{query.Key{Path: []string{vectorField}, Filter: query.NewKnn(q, k, opts...)}}
		if pf != nil {
			and = append(and, pf)
		}
		it, err := x.docs.Find(and).Iter(bg)
		if err != nil {
			return nil, err
		}
		return collect(it, "distance", func() float64 { return float64(it.Distance()) })
	}
	ef, attempts := 0, 1
	res, err := run(ef)
	if err != nil {
		return nil, err
	}
	if x.cfg.Mode == "hnsw" && pf != nil && len(res) < k {
		total, err := x.docs.Count(bg)
		if err != nil {
			return nil, err
		}
		ceiling := min(total, query.KnnMaxEf)
		ef = max(4*k, 64)
		for len(res) < k && len(res) < total {
			ef = min(ef, ceiling)
			ef = max(ef, k)
			attempts++
			if res, err = run(ef); err != nil {
				return nil, err
			}
			if ef >= ceiling {
				break
			}
			ef *= 2
		}
	}
	return map[string]any{"results": res, "ef": ef, "attempts": attempts}, nil
}

func (x *localIndex) text(q string, k int, filter string) (map[string]any, error) {
	if strings.TrimSpace(q) == "" {
		return nil, invalid("query is empty")
	}
	if k <= 0 {
		return nil, invalid("k must be positive")
	}
	m := map[string]any{"$text": map[string]any{"$search": q}}
	if f := strings.TrimSpace(filter); f != "" && f != "{}" {
		var extra map[string]any
		if err := json.Unmarshal([]byte(f), &extra); err != nil {
			return nil, invalid("filter: %v", err)
		}
		for key, v := range extra {
			if key == "$text" {
				return nil, invalid("filter must not carry $text")
			}
			m[key] = v
		}
	}
	it, err := x.docs.Find(m).Limit(uint(k)).Iter(bg)
	if err != nil {
		return nil, err
	}
	res, err := collect(it, "score", it.Score)
	if err != nil {
		return nil, err
	}
	return map[string]any{"results": res}, nil
}

func stateGet(c anystore.Collection, key string) (string, bool, error) {
	d, err := c.FindId(bg, key)
	if errors.Is(err, anystore.ErrDocNotFound) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return string(d.Value().GetStringBytes("v")), true, nil
}

func stateSet(c anystore.Collection, key, val string) error {
	a := &anyenc.Arena{}
	o := a.NewObject()
	o.Set("id", a.NewString(key))
	o.Set("v", a.NewString(val))
	return c.UpsertOne(bg, o)
}

// ---------------------------------------------------------------- exports

func withIndex(h C.uint64_t, f func(x *localIndex) error) error {
	x, err := lookup[*localIndex](uint64(h), "an index")
	if err != nil {
		return err
	}
	leave, err := x.enter()
	if err != nil {
		return err
	}
	defer leave()
	return f(x)
}

// goFloats copies n floats; a NULL pointer with n > 0 is an error.
func goFloats(p *C.float, n C.int32_t) ([]float32, error) {
	if n < 0 {
		return nil, invalid("dim is negative")
	}
	if p == nil {
		if n == 0 {
			return nil, nil
		}
		return nil, invalid("vector is NULL")
	}
	return append([]float32(nil), unsafe.Slice((*float32)(unsafe.Pointer(p)), int(n))...), nil
}

//export any_shim_index_open
func any_shim_index_open(optsJSON *C.char, outIndex *C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		if outIndex == nil {
			return invalid("out_index is NULL")
		}
		x, err := openIndex(goStr(optsJSON))
		if err != nil {
			return err
		}
		*outIndex = C.uint64_t(handles.add(x))
		return nil
	})
}

//export any_shim_index_close
func any_shim_index_close(h C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		x, err := lookup[*localIndex](uint64(h), "an index")
		if err != nil {
			return err
		}
		handles.remove(uint64(h))
		return x.close()
	})
}

//export any_shim_index_upsert
func any_shim_index_upsert(h C.uint64_t, docJSON *C.char, vector *C.float, dim C.int32_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			v, err := goFloats(vector, dim)
			if err != nil {
				return err
			}
			return x.upsert(goStr(docJSON), v)
		})
	})
}

//export any_shim_index_delete
func any_shim_index_delete(h C.uint64_t, id *C.char, outFound *C.int32_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			if outFound == nil {
				return invalid("out_found is NULL")
			}
			found, err := x.delete(goStr(id))
			if err != nil {
				return err
			}
			*outFound = 0
			if found {
				*outFound = 1
			}
			return nil
		})
	})
}

//export any_shim_index_count
func any_shim_index_count(h C.uint64_t, outCount *C.int64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			if outCount == nil {
				return invalid("out_count is NULL")
			}
			n, err := x.docs.Count(bg)
			if err != nil {
				return err
			}
			*outCount = C.int64_t(n)
			return nil
		})
	})
}

//export any_shim_index_knn
func any_shim_index_knn(h C.uint64_t, q *C.float, dim, k C.int32_t, filterJSON *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			v, err := goFloats(q, dim)
			if err != nil {
				return err
			}
			r, err := x.knn(v, int(k), goStr(filterJSON))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_index_text
func any_shim_index_text(h C.uint64_t, q *C.char, k C.int32_t, filterJSON *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			r, err := x.text(goStr(q), int(k), goStr(filterJSON))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_index_state_get
func any_shim_index_state_get(h C.uint64_t, key *C.char, outValue, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			if outValue == nil {
				return invalid("out_value is NULL")
			}
			k := goStr(key)
			if k == "" || k == configKey {
				return invalid("key %q is empty or reserved", k)
			}
			v, ok, err := stateGet(x.state, k)
			if err != nil {
				return err
			}
			*outValue = nil
			if ok {
				*outValue = C.CString(v)
			}
			return nil
		})
	})
}

//export any_shim_index_state_set
func any_shim_index_state_set(h C.uint64_t, key, value *C.char, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			k := goStr(key)
			if k == "" || k == configKey {
				return invalid("key %q is empty or reserved", k)
			}
			return stateSet(x.state, k, goStr(value))
		})
	})
}
