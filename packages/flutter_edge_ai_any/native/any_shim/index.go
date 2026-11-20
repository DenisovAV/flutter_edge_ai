package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	anystore "github.com/anyproto/any-store/v2"
	"github.com/anyproto/any-store/v2/anyenc"
	"github.com/anyproto/any-store/v2/query"
)

// The local index is one any-store database per location. It is derived
// data: rebuilt from the space by the caller, never synced.
//
//	meta        {id, v}: fmt, fileId, active (the generation n), bind
//	docs_<n>    {id, text, meta, f: {<key>: value}, embedding}: the rows,
//	            with the vector index "vec" (exact), a range index per
//	            bound field on f.<key>, and the full-text index on text
//	state_<n>   {id, v}: the caller's state (cursor, clock, ...)
//
// A rebuild writes generation n+1 (the shadow) next to n and swaps it in
// with one transaction (index_apply shadowBegin / shadowSwap).
const (
	indexFmt        = 1
	metaCollection  = "meta"
	vectorField     = "embedding"
	vectorIndexName = "vec"
	ftsIndexName    = "fts"
	maxDim          = 65536
)

// fieldKeyRe is the shape of a bound field key (and of f.<key> in a
// filter): the caller's hash-and-type key, never a raw name.
var fieldKeyRe = regexp.MustCompile(`^[0-9a-z-]+$`)

var genRe = regexp.MustCompile(`^(docs|state)_(\d+)$`)

var bg = context.Background()

type fieldDecl struct {
	Key  string `json:"key"`
	Type string `json:"type"`
}

type bindConfig struct {
	Dim        int         `json:"dim"`
	Metric     string      `json:"metric"`
	Fields     []fieldDecl `json:"fields"`
	TextSearch bool        `json:"textSearch"`
}

func (c *bindConfig) field(key string) (fieldDecl, bool) {
	for _, f := range c.Fields {
		if f.Key == key {
			return f, true
		}
	}
	return fieldDecl{}, false
}

func (c *bindConfig) json() map[string]any {
	fields := make([]map[string]any, 0, len(c.Fields))
	for _, f := range c.Fields {
		fields = append(fields, map[string]any{"key": f.Key, "type": f.Type})
	}
	return map[string]any{"dim": c.Dim, "metric": c.Metric, "fields": fields, "textSearch": c.TextSearch}
}

type localIndex struct {
	db     anystore.DB
	path   string
	fileId string
	lock   *os.File
	claims []*dirClaim

	// mu: reads and plain writes hold it shared; bind, a shadow begin or
	// swap, and close hold it exclusively, so a reader never meets a
	// collection handle the swap closed.
	mu     sync.RWMutex
	closed atomic.Bool

	meta        anystore.Collection
	active      int
	docs, state anystore.Collection
	shDocs      anystore.Collection // shadow generation, nil without one
	shState     anystore.Collection
	cfg         *bindConfig
}

type indexOpenOpts struct {
	Path       string `json:"path"`
	KeyHex     string `json:"keyHex"`
	OwnerToken string `json:"ownerToken"`
}

func genName(kind string, n int) string { return kind + "_" + strconv.Itoa(n) }

// ioOr classifies a file-system failure as ANY_SHIM_ERR_IO and anything
// else as other.
func ioOr(err error, other int, format string, args ...any) error {
	msg := fmt.Sprintf(format, args...)
	if isIOErrno(err) {
		return wrapCode(codeIO, fmt.Errorf("%s: %w", msg, err))
	}
	return wrapCode(other, fmt.Errorf("%s: %w", msg, err))
}

func openIndex(optsJSON string) (_ *localIndex, err error) {
	var o indexOpenOpts
	if err := decodeStrict(optsJSON, &o); err != nil {
		return nil, err
	}
	if o.Path == "" {
		return nil, invalid("path is required")
	}
	if o.OwnerToken == "" {
		return nil, invalid("ownerToken is required")
	}
	var key []byte
	if o.KeyHex != "" {
		key, err = hex.DecodeString(o.KeyHex)
		if err != nil || len(key) != 32 {
			return nil, invalid("keyHex must be 64 hex characters (32 bytes)")
		}
	}
	dir, err := canonicalDir(filepath.Dir(o.Path))
	if err != nil {
		return nil, ioOr(err, codeInternal, "index directory")
	}
	path := filepath.Join(dir, filepath.Base(o.Path))
	cl, err := claim(o.OwnerToken, "the index "+path, "index:"+path)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			unclaim(cl)
		}
	}()
	lock, err := lockFile(path + ".lock")
	if err != nil {
		if codeOf(err) == codeBusy {
			return nil, err
		}
		return nil, ioOr(err, codeInternal, "lock %s", path)
	}
	defer func() {
		if err != nil {
			_ = unlockFile(lock)
		}
	}()
	x, err := openIndexFile(path, key)
	if err != nil {
		return nil, err
	}
	x.lock, x.claims = lock, cl
	return x, nil
}

func dbConfig(key []byte) *anystore.Config {
	cfg := &anystore.Config{}
	if key != nil {
		// 32 bytes: any-store's raw-key path, no KDF.
		cfg.Encryption = anystore.EncryptionConfig{Passphrase: append([]byte(nil), key...)}
	}
	return cfg
}

// openIndexFile runs the keycheck protocol (keycheck.go): the sidecar is
// written before the database is created, so a crash at any point leaves
// a state the next open classifies:
//
//	no sidecar, no file        create both
//	sidecar, no file           rewrite the sidecar, create the file
//	sidecar mismatches the key KEY_MISMATCH / KEY_MISSING
//	sidecar matches            open; another fileId inside: KEY_MISMATCH;
//	                           a failed open: CORRUPT (IO for errno)
//	no sidecar, file present   CORRUPT
func openIndexFile(path string, key []byte) (*localIndex, error) {
	sidecar := path + ".keycheck"
	// A temp sidecar is a write that did not finish: never the answer.
	if err := os.Remove(sidecar + ".tmp"); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, ioOr(err, codeInternal, "remove %s.tmp", sidecar)
	}
	kc, err := readKeycheck(sidecar)
	if err != nil {
		if codeOf(err) == codeCorrupt {
			return nil, err
		}
		return nil, ioOr(err, codeInternal, "read %s", sidecar)
	}
	_, statErr := os.Stat(path)
	if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return nil, ioOr(statErr, codeInternal, "stat %s", path)
	}
	if statErr != nil { // no file
		// Journal files of a file that is gone belong to nothing.
		for _, s := range []string{"-wal", "-wal-shm", "-shm"} {
			_ = os.Remove(path + s)
		}
		nkc, err := newKeycheck(key)
		if err != nil {
			return nil, err
		}
		if err := writeKeycheck(sidecar, nkc); err != nil {
			return nil, ioOr(err, codeInternal, "write %s", sidecar)
		}
		return createIndexDB(path, key, nkc.FileId)
	}
	if kc == nil {
		return nil, withCode(codeCorrupt, "%s exists without its keycheck sidecar (%s): it cannot be told what key it was written with", path, sidecar)
	}
	if err := kc.checkKey(key); err != nil {
		return nil, err
	}
	db, err := anystore.Open(bg, path, dbConfig(key))
	if err != nil {
		// The sidecar says the key is right, so a decrypt failure is
		// damage, not a wrong key.
		return nil, ioOr(err, codeCorrupt, "open %s", path)
	}
	x, err := loadIndex(db, path, kc.FileId)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	return x, nil
}

func createIndexDB(path string, key []byte, fileId string) (*localIndex, error) {
	db, err := anystore.Open(bg, path, dbConfig(key))
	if err != nil {
		return nil, ioOr(err, codeInternal, "create %s", path)
	}
	x, err := loadIndex(db, path, fileId)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	return x, nil
}

func metaGet(ctx context.Context, meta anystore.Collection, key string) (*anyenc.Value, error) {
	d, err := meta.FindId(ctx, key)
	if errors.Is(err, anystore.ErrDocNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	// Read at once by the caller: the value points into the document.
	return d.Value().Get("v"), nil
}

func metaSet(ctx context.Context, meta anystore.Collection, key string, v *anyenc.Value) error {
	a := &anyenc.Arena{}
	o := a.NewObject()
	o.Set("id", a.NewString(key))
	o.Set("v", v)
	return meta.UpsertOne(ctx, o)
}

// loadIndex reads (or, for a database with no collections at all, writes)
// meta, drops orphan generations and opens the active one.
func loadIndex(db anystore.DB, path, fileId string) (*localIndex, error) {
	names, err := db.GetCollectionNames(bg)
	if err != nil {
		return nil, ioOr(err, codeCorrupt, "read %s", path)
	}
	hasMeta := false
	for _, n := range names {
		hasMeta = hasMeta || n == metaCollection
	}
	if !hasMeta {
		if len(names) > 0 {
			return nil, withCode(codeCorrupt, "%s has collections %v but no meta", path, names)
		}
		// New, or created before a crash that came ahead of this commit.
		if err := initIndexDB(db, fileId); err != nil {
			return nil, ioOr(err, codeInternal, "initialise %s", path)
		}
		names = []string{metaCollection, genName("docs", 0), genName("state", 0)}
	}
	meta, err := db.OpenCollection(bg, metaCollection)
	if err != nil {
		return nil, ioOr(err, codeCorrupt, "open meta of %s", path)
	}
	x := &localIndex{db: db, path: path, meta: meta}
	fail := func(code int, format string, args ...any) (*localIndex, error) {
		_ = meta.Close()
		return nil, withCode(code, format, args...)
	}
	fv, err := metaGet(bg, meta, "fmt")
	if err != nil || fv == nil || fv.Type() != anyenc.TypeNumber {
		return fail(codeCorrupt, "%s: meta has no format (%v)", path, err)
	}
	if n, _ := fv.Int(); n != indexFmt {
		return fail(codeCorrupt, "%s has format %d; this build knows %d", path, n, indexFmt)
	}
	idv, err := metaGet(bg, meta, "fileId")
	if err != nil || idv == nil || idv.Type() != anyenc.TypeString {
		return fail(codeCorrupt, "%s: meta has no fileId (%v)", path, err)
	}
	if got := string(idv.GetStringBytes()); got != fileId {
		return fail(codeKeyMismatch, "%s belongs to keycheck fileId %s, the sidecar says %s (a sidecar of another file)", path, got, fileId)
	}
	x.fileId = fileId
	av, err := metaGet(bg, meta, "active")
	if err != nil || av == nil || av.Type() != anyenc.TypeNumber {
		return fail(codeCorrupt, "%s: meta has no active generation (%v)", path, err)
	}
	active, _ := av.Int()
	x.active = active
	if bv, err := metaGet(bg, meta, "bind"); err != nil {
		return fail(codeCorrupt, "%s: bind: %v", path, err)
	} else if bv != nil {
		var c bindConfig
		if bv.Type() != anyenc.TypeString || json.Unmarshal(bv.GetStringBytes(), &c) != nil {
			return fail(codeCorrupt, "%s: bind config does not parse", path)
		}
		x.cfg = &c
	}
	// Orphans: a shadow whose swap never came, a generation whose drop
	// did not commit.
	var orphans []string
	for _, n := range names {
		if m := genRe.FindStringSubmatch(n); m != nil {
			if g, _ := strconv.Atoi(m[2]); g != active {
				orphans = append(orphans, n)
			}
		}
	}
	if len(orphans) > 0 {
		if err := dropCollections(db, orphans); err != nil {
			return fail(codeInternal, "%s: drop orphan generations %v: %v", path, orphans, err)
		}
	}
	if x.docs, err = db.OpenCollection(bg, genName("docs", active)); err != nil {
		return fail(codeCorrupt, "%s: active generation %d: %v", path, active, err)
	}
	if x.state, err = db.OpenCollection(bg, genName("state", active)); err != nil {
		_ = x.docs.Close()
		return fail(codeCorrupt, "%s: active generation %d: %v", path, active, err)
	}
	return x, nil
}

func initIndexDB(db anystore.DB, fileId string) (err error) {
	tx, err := db.WriteTx(bg)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()
	ctx := tx.Context()
	meta, err := db.CreateCollection(ctx, metaCollection)
	if err != nil {
		return err
	}
	a := &anyenc.Arena{}
	for _, kv := range []struct {
		k string
		v *anyenc.Value
	}{{"fmt", a.NewNumberInt(indexFmt)}, {"fileId", a.NewString(fileId)}, {"active", a.NewNumberInt(0)}} {
		if err := metaSet(ctx, meta, kv.k, kv.v); err != nil {
			return err
		}
	}
	for _, n := range []string{genName("docs", 0), genName("state", 0)} {
		if _, err := db.CreateCollection(ctx, n); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func dropCollections(db anystore.DB, names []string) (err error) {
	tx, err := db.WriteTx(bg)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()
	for _, n := range names {
		c, err := db.OpenCollection(tx.Context(), n)
		if err != nil {
			return err
		}
		if err := c.Drop(tx.Context()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (x *localIndex) enter() (func(), error) {
	x.mu.RLock()
	if x.closed.Load() {
		x.mu.RUnlock()
		return nil, errClosed
	}
	return x.mu.RUnlock, nil
}

func (x *localIndex) enterExclusive() (func(), error) {
	x.mu.Lock()
	if x.closed.Load() {
		x.mu.Unlock()
		return nil, errClosed
	}
	return x.mu.Unlock, nil
}

// close is idempotent after the first call (which reports CLOSED for
// later ones). It releases the lock and the claim even when the
// database close fails.
func (x *localIndex) close() error {
	if x.closed.Load() {
		return errClosed
	}
	markClosing(x.claims)
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.closed.Swap(true) {
		return errClosed
	}
	var errs []error
	for _, c := range []anystore.Collection{x.docs, x.state, x.shDocs, x.shState, x.meta} {
		if c != nil {
			errs = append(errs, c.Close())
		}
	}
	errs = append(errs, x.db.Close(), unlockFile(x.lock))
	unclaim(x.claims)
	return errors.Join(errs...)
}

// ------------------------------------------------------------------- bind

func vectorParams(c *bindConfig) (*anystore.VectorParams, error) {
	vp := &anystore.VectorParams{Field: vectorField, Dim: c.Dim, Mode: anystore.VectorModeBruteForce}
	switch c.Metric {
	case "cosine":
		vp.Metric = anystore.VectorCosine
	case "l2":
		vp.Metric = anystore.VectorL2
	case "dot":
		vp.Metric = anystore.VectorDot
	default:
		return nil, invalid("metric %q: expected cosine, l2 or dot", c.Metric)
	}
	return vp, nil
}

// ensureDocIndexes gives a docs collection the indexes of c.
func ensureDocIndexes(ctx context.Context, docs anystore.Collection, c *bindConfig) error {
	vp, err := vectorParams(c)
	if err != nil {
		return err
	}
	infos := []anystore.IndexInfo{{Name: vectorIndexName, Kind: anystore.IndexKindVector, Vector: vp}}
	for _, f := range c.Fields {
		infos = append(infos, anystore.IndexInfo{Name: "f_" + f.Key, Fields: []string{"f." + f.Key}})
	}
	if c.TextSearch {
		infos = append(infos, anystore.IndexInfo{Name: ftsIndexName, Kind: anystore.IndexKindFulltext, Fields: []string{"text"}})
	}
	return docs.EnsureIndex(ctx, infos...)
}

func (x *localIndex) bind(bindJSON string) (map[string]any, error) {
	var req bindConfig
	if err := decodeStrict(bindJSON, &req); err != nil {
		return nil, err
	}
	if req.Dim <= 0 || req.Dim > maxDim {
		return nil, invalid("dim must be in 1..%d, got %d", maxDim, req.Dim)
	}
	if _, err := vectorParams(&req); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, f := range req.Fields {
		if !fieldKeyRe.MatchString(f.Key) {
			return nil, invalid("field key %q is not [0-9a-z-]+", f.Key)
		}
		switch f.Type {
		case "string", "number", "bool":
		default:
			return nil, invalid("field %q: type %q, expected string, number or bool", f.Key, f.Type)
		}
		if seen[f.Key] {
			return nil, invalid("field %q is listed twice", f.Key)
		}
		seen[f.Key] = true
	}
	leave, err := x.enterExclusive()
	if err != nil {
		return nil, err
	}
	defer leave()
	merged := bindConfig{Dim: req.Dim, Metric: req.Metric, TextSearch: req.TextSearch}
	if old := x.cfg; old != nil {
		if old.Dim != req.Dim || old.Metric != req.Metric {
			return nil, withCode(codeConflict, "the index is bound to dim %d, metric %s; asked for dim %d, metric %s",
				old.Dim, old.Metric, req.Dim, req.Metric)
		}
		merged.Fields = append(merged.Fields, old.Fields...)
		merged.TextSearch = old.TextSearch || req.TextSearch
	}
	for _, f := range req.Fields {
		if have, ok := merged.field(f.Key); ok {
			if have.Type != f.Type {
				return nil, withCode(codeConflict, "field %q is bound as %s; asked for %s", f.Key, have.Type, f.Type)
			}
			continue
		}
		merged.Fields = append(merged.Fields, f)
	}
	if merged.Fields == nil {
		merged.Fields = []fieldDecl{}
	}
	if x.cfg != nil && len(merged.Fields) == len(x.cfg.Fields) && merged.TextSearch == x.cfg.TextSearch {
		return x.cfg.json(), nil // idempotent: nothing to write
	}
	b, _ := json.Marshal(merged)
	tx, err := x.db.WriteTx(bg)
	if err != nil {
		return nil, err
	}
	ctx := tx.Context()
	a := &anyenc.Arena{}
	err = metaSet(ctx, x.meta, "bind", a.NewString(string(b)))
	if err == nil {
		err = ensureDocIndexes(ctx, x.docs, &merged)
	}
	if err == nil && x.shDocs != nil {
		err = ensureDocIndexes(ctx, x.shDocs, &merged)
	}
	if err != nil {
		_ = tx.Rollback()
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	x.cfg = &merged
	return merged.json(), nil
}

func (x *localIndex) info() map[string]any {
	if x.cfg == nil {
		return map[string]any{}
	}
	m := x.cfg.json()
	m["fileId"] = x.fileId
	return m
}

// ------------------------------------------------------------------ apply

type vecSlot struct {
	Offset *int64 `json:"offset"`
	Dim    *int64 `json:"dim"`
}

type applyOpIn struct {
	Op     string                     `json:"op"`
	Coll   string                     `json:"coll"`
	Id     *string                    `json:"id"`
	Text   *string                    `json:"text"`
	Meta   json.RawMessage            `json:"meta"`
	F      map[string]json.RawMessage `json:"f"`
	Vector json.RawMessage            `json:"vector"`
	Key    *string                    `json:"key"`
	Value  json.RawMessage            `json:"value"`
}

type casIn struct {
	Key    string          `json:"key"`
	Expect json.RawMessage `json:"expect"`
}

type applyIn struct {
	Cas []casIn     `json:"cas"`
	Ops []applyOpIn `json:"ops"`
}

// applyOp is one validated op, ready to run.
type applyOp struct {
	kind   string // upsert, delete, clearDocs, stateSet, shadowBegin, shadowSwap
	shadow bool   // the op's collection is the shadow generation
	id     string
	text   *string
	meta   *anyenc.Value
	f      map[string]any
	vec    []float32
	hasVec bool
	value  *string
}

type casCheck struct {
	key    string
	expect *string
}

// maxSquaredNorm keeps every distance finite in float32: an l2 distance
// is at most (|a|+|b|)^2 = 4 * maxSquaredNorm, a dot product at most
// maxSquaredNorm. Beyond it a result's distance could be Inf, which fails
// the JSON of every query that returns the document.
const maxSquaredNorm = math.MaxFloat32 / 8

func checkFinite(v []float32) error {
	var sq float64
	for i, f := range v {
		if math.IsNaN(float64(f)) || math.IsInf(float64(f), 0) {
			return invalid("vector[%d] is not finite", i)
		}
		sq += float64(f) * float64(f)
	}
	if sq > maxSquaredNorm {
		return invalid("vector norm is too large for finite distances")
	}
	return nil
}

func isNull(raw json.RawMessage) bool {
	t := strings.TrimSpace(string(raw))
	return t == "" || t == "null"
}

func nullableString(raw json.RawMessage, what string) (*string, error) {
	if isNull(raw) {
		return nil, nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, invalid("%s must be a string or null", what)
	}
	return &s, nil
}

// fieldValue checks one f.<key> value against the bound type.
func fieldValue(cfg *bindConfig, key string, raw json.RawMessage) (any, error) {
	if !fieldKeyRe.MatchString(key) {
		return nil, invalid("f key %q is not [0-9a-z-]+", key)
	}
	if cfg == nil {
		return nil, invalid("f.%s before index_bind: no field is bound", key)
	}
	decl, ok := cfg.field(key)
	if !ok {
		return nil, invalid("f.%s is not a bound field", key)
	}
	v, err := jsonValue(raw)
	if err != nil {
		return nil, invalid("f.%s: %v", key, err)
	}
	switch decl.Type {
	case "string":
		if s, ok := v.(string); ok {
			return s, nil
		}
	case "number":
		switch n := v.(type) {
		case int64:
			return float64(n), nil
		case float64:
			if !math.IsInf(n, 0) && !math.IsNaN(n) {
				return n, nil
			}
		}
	case "bool":
		if b, ok := v.(bool); ok {
			return b, nil
		}
	}
	return nil, invalid("f.%s must be a %s, got %s", key, decl.Type, strings.TrimSpace(string(raw)))
}

// validateApply checks every op and every vector slot before anything is
// written. The float buffer is read only after the slots are known to
// tile it exactly: slot i starts where slot i-1 ended, the first at 0,
// the last ends at vector_floats.
func (x *localIndex) validateApply(opsJSON string, vectors unsafe.Pointer, nFloats int64) ([]casCheck, []applyOp, bool, error) {
	var in applyIn
	if err := decodeStrict(opsJSON, &in); err != nil {
		return nil, nil, false, err
	}
	if nFloats < 0 {
		return nil, nil, false, invalid("vector_floats is negative")
	}
	if nFloats > 0 && vectors == nil {
		return nil, nil, false, invalid("vectors is NULL with vector_floats %d", nFloats)
	}
	if nFloats > math.MaxInt32*16 {
		return nil, nil, false, invalid("vector_floats %d is too large", nFloats)
	}
	cas := make([]casCheck, 0, len(in.Cas))
	for i, c := range in.Cas {
		if c.Key == "" {
			return nil, nil, false, invalid("cas[%d]: key is empty", i)
		}
		e, err := nullableString(c.Expect, fmt.Sprintf("cas[%d].expect", i))
		if err != nil {
			return nil, nil, false, err
		}
		cas = append(cas, casCheck{key: c.Key, expect: e})
	}
	shadow := x.shDocs != nil
	ddl := false
	var cursor int64
	type pending struct {
		op       int
		off, dim int64
	}
	var slots []pending
	ops := make([]applyOp, 0, len(in.Ops))
	for i, o := range in.Ops {
		bad := func(format string, args ...any) error {
			return invalid("ops[%d] (%s): %s", i, o.Op, fmt.Sprintf(format, args...))
		}
		only := func(allowed ...string) error {
			present := map[string]bool{
				"coll": o.Coll != "", "id": o.Id != nil, "text": o.Text != nil, "meta": len(o.Meta) > 0,
				"f": o.F != nil, "vector": len(o.Vector) > 0, "key": o.Key != nil, "value": len(o.Value) > 0,
			}
			for _, a := range allowed {
				delete(present, a)
			}
			for k, p := range present {
				if p {
					return bad("field %q does not belong to this op", k)
				}
			}
			return nil
		}
		docColl := func() (bool, error) {
			switch o.Coll {
			case "docs":
				return false, nil
			case "shadow":
				if !shadow {
					return false, bad("no shadow generation: shadowBegin first")
				}
				return true, nil
			}
			return false, bad("coll %q: expected docs or shadow", o.Coll)
		}
		op := applyOp{kind: o.Op}
		var err error
		switch o.Op {
		case "upsert":
			if err = only("coll", "id", "text", "meta", "f", "vector"); err != nil {
				return nil, nil, false, err
			}
			if op.shadow, err = docColl(); err != nil {
				return nil, nil, false, err
			}
			if o.Id == nil || *o.Id == "" {
				return nil, nil, false, bad("id is empty")
			}
			op.id, op.text = *o.Id, o.Text
			if !isNull(o.Meta) {
				mv, perr := anyenc.ParseJson(string(o.Meta))
				if perr != nil {
					return nil, nil, false, bad("meta: %v", perr)
				}
				op.meta = mv
			}
			if len(o.F) > 0 {
				op.f = map[string]any{}
				for k, raw := range o.F {
					v, ferr := fieldValue(x.cfg, k, raw)
					if ferr != nil {
						return nil, nil, false, bad("%v", ferr)
					}
					op.f[k] = v
				}
			}
			if !isNull(o.Vector) {
				var vs vecSlot
				if err := decodeStrict(string(o.Vector), &vs); err != nil {
					return nil, nil, false, bad("vector: %v", err)
				}
				if vs.Offset == nil || vs.Dim == nil {
					return nil, nil, false, bad("vector needs offset and dim")
				}
				if x.cfg == nil {
					return nil, nil, false, withCode(codeRefused, "ops[%d]: a vector before index_bind", i)
				}
				off, dim := *vs.Offset, *vs.Dim
				switch {
				case dim != int64(x.cfg.Dim):
					return nil, nil, false, bad("vector dim %d, the index is bound to %d", dim, x.cfg.Dim)
				case off < 0:
					return nil, nil, false, bad("vector offset %d is negative", off)
				case off != cursor:
					return nil, nil, false, bad("vector offset %d: the slots must tile the buffer in order, expected %d", off, cursor)
				case off > nFloats || dim > nFloats-off: // no overflow: both sides are in range
					return nil, nil, false, bad("vector slot %d+%d is past vector_floats %d", off, dim, nFloats)
				}
				cursor = off + dim
				op.hasVec = true
				slots = append(slots, pending{op: len(ops), off: off, dim: dim})
			}
		case "delete":
			if err = only("coll", "id"); err != nil {
				return nil, nil, false, err
			}
			if op.shadow, err = docColl(); err != nil {
				return nil, nil, false, err
			}
			if o.Id == nil || *o.Id == "" {
				return nil, nil, false, bad("id is empty")
			}
			op.id = *o.Id
		case "clearDocs":
			if err = only("coll"); err != nil {
				return nil, nil, false, err
			}
			if op.shadow, err = docColl(); err != nil {
				return nil, nil, false, err
			}
		case "stateSet":
			if err = only("coll", "key", "value"); err != nil {
				return nil, nil, false, err
			}
			switch o.Coll {
			case "state":
			case "shadowState":
				if !shadow {
					return nil, nil, false, bad("no shadow generation: shadowBegin first")
				}
				op.shadow = true
			default:
				return nil, nil, false, bad("coll %q: expected state or shadowState", o.Coll)
			}
			if o.Key == nil || *o.Key == "" {
				return nil, nil, false, bad("key is empty")
			}
			op.id = *o.Key
			if op.value, err = nullableString(o.Value, "value"); err != nil {
				return nil, nil, false, bad("%v", err)
			}
		case "shadowBegin":
			if err = only(); err != nil {
				return nil, nil, false, err
			}
			shadow, ddl = true, true
		case "shadowSwap":
			if err = only(); err != nil {
				return nil, nil, false, err
			}
			if !shadow {
				return nil, nil, false, bad("no shadow generation to swap in")
			}
			shadow, ddl = false, true
		default:
			return nil, nil, false, invalid("ops[%d]: unknown op %q", i, o.Op)
		}
		ops = append(ops, op)
	}
	if cursor != nFloats {
		return nil, nil, false, invalid("the vector slots cover %d floats, vector_floats is %d", cursor, nFloats)
	}
	if nFloats > 0 {
		all := unsafe.Slice((*float32)(vectors), int(nFloats))
		for _, s := range slots {
			v := append([]float32(nil), all[s.off:s.off+s.dim]...)
			if err := checkFinite(v); err != nil {
				return nil, nil, false, invalid("ops[%d]: %v", s.op, err)
			}
			ops[s.op].vec = v
		}
	}
	return cas, ops, ddl, nil
}

func stateGetCtx(ctx context.Context, c anystore.Collection, key string) (*string, error) {
	d, err := c.FindId(ctx, key)
	if errors.Is(err, anystore.ErrDocNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	v := d.Value().Get("v")
	if v == nil || v.Type() != anyenc.TypeString {
		return nil, withCode(codeCorrupt, "state %q is not a string value", key)
	}
	s := string(v.GetStringBytes())
	return &s, nil
}

func rowValue(op applyOp) *anyenc.Value {
	a := &anyenc.Arena{}
	o := a.NewObject()
	o.Set("id", a.NewString(op.id))
	if op.text != nil {
		o.Set("text", a.NewString(*op.text))
	}
	if op.meta != nil {
		o.Set("meta", op.meta)
	}
	if len(op.f) > 0 {
		fo := a.NewObject()
		for k, v := range op.f {
			switch t := v.(type) {
			case string:
				fo.Set(k, a.NewString(t))
			case float64:
				fo.Set(k, a.NewNumberFloat64(t))
			case bool:
				if t {
					fo.Set(k, a.NewTrue())
				} else {
					fo.Set(k, a.NewFalse())
				}
			}
		}
		o.Set("f", fo)
	}
	if op.hasVec {
		o.Set(vectorField, a.NewVectorF32(op.vec))
	}
	return o
}

// needsExclusive reports whether a request begins or swaps a shadow
// generation (it drops collections, so readers must be out). A request
// that does not parse takes the shared lock and fails validation.
func needsExclusive(opsJSON string) bool {
	var in struct {
		Ops []struct {
			Op string `json:"op"`
		} `json:"ops"`
	}
	if json.Unmarshal([]byte(opsJSON), &in) != nil {
		return false
	}
	for _, o := range in.Ops {
		if o.Op == "shadowBegin" || o.Op == "shadowSwap" {
			return true
		}
	}
	return false
}

func (x *localIndex) apply(opsJSON string, vectors unsafe.Pointer, nFloats int64) (map[string]any, error) {
	var leave func()
	var err error
	if needsExclusive(opsJSON) {
		leave, err = x.enterExclusive()
	} else {
		leave, err = x.enter()
	}
	if err != nil {
		return nil, err
	}
	defer leave()
	// Validated under the lock: the bind config and the shadow it checks
	// against change only under the exclusive lock.
	cas, ops, ddl, err := x.validateApply(opsJSON, vectors, nFloats)
	if err != nil {
		return nil, err
	}
	if ddl && !needsExclusive(opsJSON) {
		return nil, withCode(codeInternal, "a shadow op under the shared lock")
	}
	tx, err := x.db.WriteTx(bg)
	if err != nil {
		return nil, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()
	ctx := tx.Context()
	for _, c := range cas {
		have, err := stateGetCtx(ctx, x.state, c.key)
		if err != nil {
			return nil, err
		}
		if (have == nil) != (c.expect == nil) || (have != nil && *have != *c.expect) {
			return nil, withCode(codeConflict, "state %q is %s, expected %s: nothing applied", c.key, showStr(have), showStr(c.expect))
		}
	}
	docs, state, shDocs, shState, active := x.docs, x.state, x.shDocs, x.shState, x.active
	swapped := false
	for i, op := range ops {
		coll := docs
		if op.shadow {
			coll = shDocs
		}
		var err error
		switch op.kind {
		case "upsert":
			err = coll.UpsertOne(ctx, rowValue(op))
		case "delete":
			if err = coll.DeleteId(ctx, op.id); errors.Is(err, anystore.ErrDocNotFound) {
				err = nil
			}
		case "clearDocs":
			_, err = coll.Find(nil).Delete(ctx)
		case "stateSet":
			sc := state
			if op.shadow {
				sc = shState
			}
			if op.value == nil {
				if err = sc.DeleteId(ctx, op.id); errors.Is(err, anystore.ErrDocNotFound) {
					err = nil
				}
			} else {
				a := &anyenc.Arena{}
				o := a.NewObject()
				o.Set("id", a.NewString(op.id))
				o.Set("v", a.NewString(*op.value))
				err = sc.UpsertOne(ctx, o)
			}
		case "shadowBegin":
			if shDocs != nil {
				if err = shDocs.Drop(ctx); err == nil {
					err = shState.Drop(ctx)
				}
			}
			if err == nil {
				shDocs, shState, err = x.createGeneration(ctx, active+1)
			}
		case "shadowSwap":
			a := &anyenc.Arena{}
			if err = metaSet(ctx, x.meta, "active", a.NewNumberInt(active+1)); err == nil {
				if err = docs.Drop(ctx); err == nil {
					err = state.Drop(ctx)
				}
			}
			docs, state, shDocs, shState = shDocs, shState, nil, nil
			active++
			swapped = true
		}
		if err != nil {
			return nil, fmt.Errorf("ops[%d] (%s): %w", i, op.kind, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	committed = true
	if ddl || swapped {
		x.docs, x.state, x.shDocs, x.shState, x.active = docs, state, shDocs, shState, active
	}
	return map[string]any{"applied": len(ops)}, nil
}

func showStr(s *string) string {
	if s == nil {
		return "absent"
	}
	return strconv.Quote(*s)
}

// createGeneration creates docs_<n> and state_<n> with the bound indexes.
func (x *localIndex) createGeneration(ctx context.Context, n int) (anystore.Collection, anystore.Collection, error) {
	d, err := x.db.CreateCollection(ctx, genName("docs", n))
	if err != nil {
		return nil, nil, err
	}
	s, err := x.db.CreateCollection(ctx, genName("state", n))
	if err != nil {
		return nil, nil, err
	}
	if x.cfg != nil {
		if err := ensureDocIndexes(ctx, d, x.cfg); err != nil {
			return nil, nil, err
		}
	}
	return d, s, nil
}

// ------------------------------------------------------------------ reads

func docRow(v *anyenc.Value, withVector bool) map[string]any {
	r := map[string]any{"id": string(v.GetStringBytes("id")), "text": nil, "meta": nil, "f": map[string]any{}}
	if t := v.Get("text"); t != nil {
		r["text"] = goValue(t)
	}
	if m := v.Get("meta"); m != nil {
		r["meta"] = goValue(m)
	}
	if f := v.Get("f"); f != nil {
		r["f"] = goValue(f)
	}
	e := v.Get(vectorField)
	if withVector {
		r["vector"] = nil
		if e != nil {
			if fs, err := e.VectorF32(); err == nil {
				r["vector"] = fs
			}
		}
	} else {
		r["hasVector"] = e != nil
	}
	return r
}

func stateRow(v *anyenc.Value) map[string]any {
	return map[string]any{"key": string(v.GetStringBytes("id")), "value": string(v.GetStringBytes("v"))}
}

// collFor names a collection of the caller's: docs, shadow, state,
// shadowState. The caller holds mu.
func (x *localIndex) collFor(name string) (anystore.Collection, bool, error) {
	switch name {
	case "docs":
		return x.docs, true, nil
	case "state":
		return x.state, false, nil
	case "shadow", "shadowState":
		if x.shDocs == nil {
			return nil, false, invalid("no shadow generation")
		}
		if name == "shadow" {
			return x.shDocs, true, nil
		}
		return x.shState, false, nil
	}
	return nil, false, invalid("coll %q: expected docs, shadow, state or shadowState", name)
}

func (x *localIndex) get(collName, id string) (map[string]any, error) {
	if id == "" {
		return nil, invalid("id is empty")
	}
	c, isDocs, err := x.collFor(collName)
	if err != nil {
		return nil, err
	}
	d, err := c.FindId(bg, id)
	if errors.Is(err, anystore.ErrDocNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if isDocs {
		return docRow(d.Value(), true), nil
	}
	return stateRow(d.Value()), nil
}

const defaultScanLimit = 500

func (x *localIndex) scan(collName, prefix, after string, limit int) (map[string]any, error) {
	c, isDocs, err := x.collFor(collName)
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = defaultScanLimit
	}
	cond := map[string]any{}
	switch {
	case after != "" && after >= prefix:
		cond["id"] = map[string]any{"$gt": after}
	case prefix != "":
		cond["id"] = map[string]any{"$gte": prefix}
	}
	var filter any
	if len(cond) > 0 {
		filter = cond
	}
	it, err := c.Find(filter).Sort("id").Iter(bg)
	if err != nil {
		return nil, err
	}
	defer it.Close()
	items := []map[string]any{}
	var next any
	lastId := ""
	for it.Next() {
		d, err := it.Doc()
		if err != nil {
			return nil, err
		}
		v := d.Value()
		id := string(v.GetStringBytes("id"))
		if !strings.HasPrefix(id, prefix) {
			break // sorted: past the prefix range
		}
		if len(items) == limit {
			next = lastId
			break
		}
		lastId = id
		if isDocs {
			items = append(items, docRow(v, false))
		} else {
			items = append(items, stateRow(v))
		}
	}
	if err := it.Err(); err != nil {
		return nil, err
	}
	return map[string]any{"items": items, "next": next}, nil
}

// checkFilter accepts a Mongo-style filter over the bound fields only:
// field paths f.<key>, combined with $and / $or / $nor; operators inside
// a field's condition are any-store's.
func checkFilter(v any) error {
	m, ok := v.(map[string]any)
	if !ok {
		return invalid("filter must be a JSON object")
	}
	for k, val := range m {
		switch {
		case k == "$and" || k == "$or" || k == "$nor":
			arr, ok := val.([]any)
			if !ok || len(arr) == 0 {
				return invalid("filter: %s takes a non-empty array", k)
			}
			for _, e := range arr {
				if err := checkFilter(e); err != nil {
					return err
				}
			}
		case strings.HasPrefix(k, "f.") && fieldKeyRe.MatchString(k[2:]):
		default:
			return invalid("filter: %q is not f.<key> (key [0-9a-z-]+) or $and/$or/$nor", k)
		}
	}
	return nil
}

func parseFilter(s string) (map[string]any, error) {
	s = strings.TrimSpace(s)
	if s == "" || s == "{}" || s == "null" {
		return nil, nil
	}
	var m any
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		return nil, invalid("filter: %v", err)
	}
	if err := checkFilter(m); err != nil {
		return nil, err
	}
	return m.(map[string]any), nil
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
		r := map[string]any{scoreKey: score(), "id": string(v.GetStringBytes("id")), "text": nil, "meta": nil}
		if t := v.Get("text"); t != nil {
			r["text"] = goValue(t)
		}
		if m := v.Get("meta"); m != nil {
			r["meta"] = goValue(m)
		}
		out = append(out, r)
	}
	return out, it.Err()
}

func (x *localIndex) knn(q []float32, k int, filter string) (map[string]any, error) {
	if x.cfg == nil {
		return nil, withCode(codeRefused, "the index is not bound yet (index_bind)")
	}
	if len(q) != x.cfg.Dim {
		return nil, invalid("query has %d dimensions, the index %d", len(q), x.cfg.Dim)
	}
	if err := checkFinite(q); err != nil {
		return nil, err
	}
	if k <= 0 || k > query.KnnMaxK {
		return nil, invalid("k must be in 1..%d", query.KnnMaxK)
	}
	fm, err := parseFilter(filter)
	if err != nil {
		return nil, err
	}
	and := query.And{query.Key{Path: []string{vectorField}, Filter: query.NewKnn(q, k)}}
	if fm != nil {
		pf, err := query.ParseCondition(fm)
		if err != nil {
			return nil, invalid("filter: %v", err)
		}
		and = append(and, pf)
	}
	it, err := x.docs.Find(and).Iter(bg)
	if err != nil {
		return nil, err
	}
	res, err := collect(it, "distance", func() float64 { return float64(it.Distance()) })
	if err != nil {
		return nil, err
	}
	return map[string]any{"results": res}, nil
}

func (x *localIndex) text(q string, k int, filter string) (map[string]any, error) {
	if x.cfg == nil || !x.cfg.TextSearch {
		return nil, withCode(codeRefused, "text search is not bound (index_bind textSearch)")
	}
	if strings.TrimSpace(q) == "" {
		return nil, invalid("query is empty")
	}
	if k <= 0 || k > query.KnnMaxK {
		return nil, invalid("k must be in 1..%d", query.KnnMaxK)
	}
	fm, err := parseFilter(filter)
	if err != nil {
		return nil, err
	}
	m := map[string]any{}
	for key, v := range fm {
		m[key] = v
	}
	m["$text"] = map[string]any{"$search": q}
	// Sorted before the limit, so equal scores come back in id order and
	// the page is the same in every insertion order (measured: without the
	// sort, ties come in insertion order).
	it, err := x.docs.Find(m).Sort("-_score", "id").Limit(uint(k)).Iter(bg)
	if err != nil {
		return nil, invalid("text query: %v", err)
	}
	res, err := collect(it, "score", it.Score)
	if err != nil {
		return nil, err
	}
	return map[string]any{"results": res}, nil
}

// flush checkpoints the database now (writes, full-text postings
// included, are committed by their transaction; this makes them durable
// in the main file). wait bounds the wait for the writer lock; 0 is one
// attempt bounded by maxWait.
func (x *localIndex) flush(wait time.Duration) error {
	if wait <= 0 {
		wait = maxWait
	}
	ctx, cancel := context.WithTimeout(bg, wait)
	defer cancel()
	err := x.db.Flush(ctx, 0, anystore.FlushModeCheckpointPassive)
	if err != nil && ctx.Err() != nil {
		return withCode(codeTimeout, "flush did not finish within %v: %v", wait, err)
	}
	return err
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

// withIndexNoLock is for calls that take the index lock themselves.
func withIndexNoLock(h C.uint64_t, f func(x *localIndex) error) error {
	x, err := lookup[*localIndex](uint64(h), "an index")
	if err != nil {
		return err
	}
	if x.closed.Load() {
		return errClosed
	}
	return f(x)
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
		x, err := take[*localIndex](uint64(h), "an index")
		if err != nil {
			return err
		}
		return x.close()
	})
}

func releaseIndex(h uint64) {
	defer func() { _ = recover() }()
	x, ok := takeIf[*localIndex](h)
	if !ok {
		return
	}
	markClosing(x.claims)
	go func() {
		defer func() { _ = recover() }()
		_ = x.close()
	}()
}

//export any_shim_index_release
func any_shim_index_release(h C.uintptr_t) {
	releaseIndex(uint64(h))
}

//export any_shim_index_bind
func any_shim_index_bind(h C.uint64_t, bindJSON *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndexNoLock(h, func(x *localIndex) error {
			if outJSON == nil {
				return invalid("out_json is NULL")
			}
			r, err := x.bind(goStr(bindJSON))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_index_info
func any_shim_index_info(h C.uint64_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error { return putJSON(outJSON, x.info()) })
	})
}

//export any_shim_index_apply
func any_shim_index_apply(h C.uint64_t, opsJSON *C.char, vectors *C.float, vectorFloats C.int64_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndexNoLock(h, func(x *localIndex) error {
			if outJSON == nil {
				return invalid("out_json is NULL")
			}
			r, err := x.apply(goStr(opsJSON), unsafe.Pointer(vectors), int64(vectorFloats))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_index_get
func any_shim_index_get(h C.uint64_t, coll, id *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			if outJSON == nil {
				return invalid("out_json is NULL")
			}
			r, err := x.get(goStr(coll), goStr(id))
			if err != nil {
				return err
			}
			if r == nil {
				*outJSON = nil
				return nil
			}
			return putJSON(outJSON, r)
		})
	})
}

//export any_shim_index_scan
func any_shim_index_scan(h C.uint64_t, coll, prefix, after *C.char, limit C.int32_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			r, err := x.scan(goStr(coll), goStr(prefix), goStr(after), int(limit))
			if err != nil {
				return err
			}
			return putJSON(outJSON, r)
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

func (x *localIndex) countVectors() (int, error) {
	return x.docs.Find(map[string]any{vectorField: map[string]any{"$exists": true}}).Count(bg)
}

//export any_shim_index_count_vectors
func any_shim_index_count_vectors(h C.uint64_t, outCount *C.int64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error {
			if outCount == nil {
				return invalid("out_count is NULL")
			}
			n, err := x.countVectors()
			if err != nil {
				return err
			}
			*outCount = C.int64_t(n)
			return nil
		})
	})
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

//export any_shim_index_flush
func any_shim_index_flush(h C.uint64_t, waitMs C.int32_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withIndex(h, func(x *localIndex) error { return x.flush(clampWait(waitMs)) })
	})
}
