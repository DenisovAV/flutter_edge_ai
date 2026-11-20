package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	anystore "github.com/anyproto/any-store/v2"
	"github.com/anyproto/any-store/v2/anyenc"
	anysyncsdk "github.com/anyproto/any-sync-sdk"
	"github.com/anyproto/any-sync-sdk/space"
)

// Tests for the review round 1 fixes (FIXES.md H1-H7, B1-B2, G1-G13).

func claimHeld(sub string) bool {
	claims.Lock()
	defer claims.Unlock()
	for k := range claims.m {
		if strings.Contains(k, sub) {
			return true
		}
	}
	return false
}

// H1: BUSY and REFUSED come back from the start call itself; the SDK
// opens in the op; the op result names the account handle.
func TestAccountOpenStart(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t), token: "g1"}
	oh, err := accountOpenStart(acctOpts(t, cfg))
	if err != nil {
		t.Fatal(err)
	}
	r, err := waitOpDone(t, oh, 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	h := r.(map[string]any)["account"].(uint64)
	if b, _ := json.Marshal(r); !strings.Contains(string(b), fmt.Sprintf(`"account":%d`, h)) {
		t.Fatalf("result json %s", b)
	}
	a, err := lookup[*account](h, "an account")
	if err != nil {
		t.Fatal(err)
	}
	cfg2 := cfg
	cfg2.token = "g2"
	start := time.Now()
	if _, err := accountOpenStart(acctOpts(t, cfg2)); codeOf(err) != codeBusy {
		t.Fatalf("other token: %v, want BUSY from the start call", err)
	}
	if _, err := accountOpenStart(acctOpts(t, cfg)); codeOf(err) != codeRefused {
		t.Fatalf("same token: %v, want REFUSED", err)
	}
	if took := time.Since(start); took > 100*time.Millisecond {
		t.Fatalf("refusals took %v", took)
	}
	// The data dir lock is .shimlock, not any-store's sentinel name.
	if _, err := os.Stat(filepath.Join(a.lock.Name())); err != nil || filepath.Base(a.lock.Name()) != ".shimlock" {
		t.Fatalf("lock file %s: %v", a.lock.Name(), err)
	}
	cop, err := accountCloseStart(h, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := waitOpDone(t, cop, 30*time.Second); err != nil {
		t.Fatal(err)
	}
	if claimHeld(cfg.base) {
		t.Fatal("claims left after close")
	}
}

// H1: an opened account nobody takes (the op was cancelled) is closed
// again: its claims and lock go.
func TestAccountOpenStartCancelledReleases(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t), token: "c1"}
	for _, cancelEarly := range []bool{true, false} {
		oh, err := accountOpenStart(acctOpts(t, cfg))
		if err != nil {
			t.Fatal(err)
		}
		o, _ := lookup[*op](oh, "an op")
		if !cancelEarly {
			<-o.done // finished: the account exists and is undelivered
		}
		if o, err := take[*op](oh, "an op"); err != nil {
			t.Fatal(err)
		} else {
			o.abandon()
		}
		deadline := time.Now().Add(20 * time.Second)
		for claimHeld(cfg.base) {
			if time.Now().After(deadline) {
				t.Fatalf("cancelEarly=%v: claims never released", cancelEarly)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	// And the directory opens again.
	a := openAt(t, cfg)
	_ = a
}

// H2: a close that waits for loads finishes promptly when none runs,
// and refuses calls at once.
func TestCloseStartWaitsForLoads(t *testing.T) {
	a, err := openAccount(acctOpts(t, acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)}))
	if err != nil {
		t.Fatal(err)
	}
	sid := mustCreateSpace(t, a, "w")
	// A load that is still running when the close starts: its slot is
	// held by hand, as a slow first load would.
	slow := &spaceLoad{done: make(chan struct{})}
	a.loadsMu.Lock()
	a.loads["slow"] = slow
	a.loadsMu.Unlock()
	a.loadWG.Add(1)
	h := handles.add(a)
	start := time.Now()
	op, err := accountCloseStart(h, 25000)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.enter(); codeOf(err) != codeClosed {
		t.Fatalf("call during a waiting close: %v", err)
	}
	if a.ctx.Err() != nil {
		t.Fatal("a close that waits for loads cancelled at once")
	}
	time.Sleep(300 * time.Millisecond)
	if _, err := waitOp(op, 0); codeOf(err) != codePending {
		t.Fatalf("close did not wait for the load: %v", err)
	}
	close(slow.done)
	a.loadWG.Done()
	if _, err := waitOpDone(t, op, 30*time.Second); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took > 20*time.Second {
		t.Fatalf("close took %v", took)
	}
	_ = sid
}

// G1: a close that panics in the SDK still releases the claims and the
// lock, and reports the panic.
func TestClosePanicLeavesNoClaim(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)}
	a, err := openAccount(acctOpts(t, cfg))
	if err != nil {
		t.Fatal(err)
	}
	orig := closeSDKHook
	closeSDKHook = func(s *anysyncsdk.SDK) error {
		_ = closeSDK(s)
		panic("simulated close panic")
	}
	defer func() { closeSDKHook = orig }()
	err = a.closeNow()
	if codeOf(err) != codePanic || !strings.Contains(err.Error(), "simulated close panic") {
		t.Fatalf("close error %v, want the panic", err)
	}
	if claimHeld(cfg.base) {
		t.Fatal("claims left after a panicking close")
	}
	f, err := lockFile(filepath.Join(cfg.base, "data", dataDirLockName))
	if err != nil {
		t.Fatalf("lock still held: %v", err)
	}
	unlockFile(f)
}

// G7: the close drops the account's ops.
func TestCloseDropsOps(t *testing.T) {
	a, err := openAccount(acctOpts(t, acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)}))
	if err != nil {
		t.Fatal(err)
	}
	h := a.startOp(func(ctx context.Context) (any, error) { <-ctx.Done(); return nil, ctx.Err() })
	if err := a.closeNow(); err != nil {
		t.Fatal(err)
	}
	if _, err := lookup[*op](h, "an op"); codeOf(err) != codeClosed {
		t.Fatalf("op of a closed account: %v", err)
	}
}

// G7: a finished op nobody waited for is dropped after staleOpAge.
func TestStaleOpsDropped(t *testing.T) {
	h := startOp(context.Background(), func(context.Context) (any, error) { return nil, nil })
	o, _ := lookup[*op](h, "an op")
	<-o.done
	o.finished.Store(time.Now().Add(-staleOpAge - time.Minute).UnixNano())
	startOp(context.Background(), func(context.Context) (any, error) { return nil, nil })
	if _, err := lookup[*op](h, "an op"); codeOf(err) != codeClosed {
		t.Fatalf("stale op: %v", err)
	}
}

// H5: the derived id equals what Objects().Derive gives, without a write.
func TestDeriveIdMatchesDerive(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "d")
	ids := mustRagBundles(t, a, sid, true)
	for _, seed := range []string{"flutter_edge_ai.rag/manifest/main", "x", "flutter_edge_ai.rag/manifest/ünïcode"} {
		want, err := deriveObjectId(sid, seed)
		if err != nil {
			t.Fatal(err)
		}
		sp, _ := a.space(sid)
		// No object before the derive: the id was computed, not read.
		if st, _, _ := objectState(a.ctx, sp, want); st != "missing" {
			t.Fatalf("derive_id wrote %s: %s", want, st)
		}
		got, err := sp.Objects().Derive(a.ctx, space.DeriveObjectOpts{Seed: []byte(seed), Type: ids.loc})
		if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("seed %q: derive_id %s, Derive %s", seed, want, got)
		}
	}
	if _, err := deriveObjectId(sid, ""); codeOf(err) != codeInvalidArgument {
		t.Fatalf("empty seed: %v", err)
	}
}

// B1: core and textSearch are object-kind with leaves; B2: revs takes
// numbers only, reserved ids are open.
func TestBundleShapes(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "b")
	ids := mustRagBundles(t, a, sid, true)
	m, err := patch(a, sid, map[string]any{"derive": map[string]any{"seed": "m", "type": ids.loc}},
		[]any{map[string]any{"xkey": "core", "leaf": "text", "value": map[string]any{"fmt": 1}},
			map[string]any{"xkey": "core", "leaf": "image", "value": map[string]any{"fmt": 1}},
			map[string]any{"xkey": "textSearch", "leaf": "on", "value": true}})
	if err != nil {
		t.Fatal(err)
	}
	man := m["id"].(string)
	req, _ := json.Marshal(map[string]any{"ids": []string{man}, "xkeys": []string{"core", "textSearch"}})
	r, err := a.objectRead(sid, string(req))
	if err != nil {
		t.Fatal(err)
	}
	p := r["items"].([]map[string]any)[0]["props"].(map[string]any)
	core := p["core"].(map[string]any)
	if len(core) != 2 || p["textSearch"].(map[string]any)["on"] != true {
		t.Fatalf("props %v", p)
	}
	if _, err := patch(a, sid, map[string]any{"id": man}, []any{map[string]any{"xkey": "core", "value": "x"}}); codeOf(err) != codeRefused {
		t.Fatalf("a string core: %v", err)
	}
	if err := a.recordsModify(sid, man, ids.tombstones, `[{"id":"clear","addToSet":{"revs":5}},{"id":"future_name","addToSet":{"revs":6}}]`); err != nil {
		t.Fatalf("reserved ids: %v", err)
	}
	if err := a.recordsModify(sid, man, ids.tombstones, `[{"id":"clear","addToSet":{"revs":"5"}}]`); err == nil {
		t.Fatal("a string rev was accepted")
	}
	if err := a.recordsModify(sid, man, ids.tombstones, `[{"id":"`+strings.Repeat("a", 64)+`","set":{"key":7}}]`); err == nil {
		t.Fatal("a number key was accepted")
	}
}

// G8: an xkey our bundle declared and that was removed is REFUSED.
func TestRemovedXKeyRefused(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "rm")
	ids := mustRagBundles(t, a, sid, true)
	sp, _ := a.space(sid)
	if err := sp.Types().RemoveProperty(a.ctx, ids.doc, ids.vecs); err != nil {
		t.Fatal(err)
	}
	_, err := patch(a, sid, map[string]any{"create": map[string]any{"type": ids.doc}}, []any{map[string]any{"xkey": "vecs", "leaf": "h", "value": 1}})
	if codeOf(err) != codeRefused {
		t.Fatalf("removed xkey: %v, want REFUSED", err)
	}
	if _, err := patch(a, sid, map[string]any{"create": map[string]any{"type": ids.doc}}, []any{map[string]any{"xkey": "other", "value": 1}}); codeOf(err) != codeInvalidArgument {
		t.Fatalf("never declared: %v", err)
	}
}

// G4, G10, H6: a failed state save is reported, never silent; a space
// created anyway is OK with its id.
func TestStateSaveErrors(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs POSIX permissions")
	}
	a := openOffline(t)
	dataDir := filepath.Dir(a.state.path)
	if err := os.Chmod(dataDir, 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dataDir, 0o700)
	r, err := a.createSpace("x")
	if err != nil {
		t.Fatalf("create with a failing save: %v", err)
	}
	sid, _ := r["id"].(string)
	if sid == "" || r["stateSaveError"] == nil {
		t.Fatalf("create result %v", r)
	}
	if err := a.markPeerSynced(sid, true); codeOf(err) != codeIO {
		t.Fatalf("sync save: %v, want IO", err)
	}
	st, err := a.spaceStatus(sid)
	if err != nil || st["stateSaveError"] == nil {
		t.Fatalf("status %v %v", st, err)
	}
	os.Chmod(dataDir, 0o700)
	if err := a.markPeerSynced("another", true); err != nil {
		t.Fatal(err)
	}
	if st, _ := a.spaceStatus(sid); st["stateSaveError"] != nil {
		t.Fatalf("a successful save did not clear the error: %v", st)
	}
}

// G3: any-store's "full" error is ERR_IO; its text is pinned to the
// any-store source (the sentinel is in an internal package).
func TestAnystoreFullTextIsCurrent(t *testing.T) {
	out, err := exec.Command("go", "list", "-m", "-f", "{{.Dir}}", "github.com/anyproto/any-store/v2").Output()
	if err != nil {
		t.Skipf("go list: %v", err)
	}
	src, err := os.ReadFile(filepath.Join(strings.TrimSpace(string(out)), "internal", "btree", "errors.go"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), `ErrFull = errors.New("`+anystoreFullText+`")`) {
		t.Fatalf("any-store's ErrFull text is no longer %q", anystoreFullText)
	}
	if codeOf(storeErr(fmt.Errorf("commit: %w", errors.New(anystoreFullText)))) != codeIO {
		t.Fatal("full is not IO")
	}
	if codeOf(storeErr(fmt.Errorf("write: %w", syscall.ENOSPC))) != codeIO {
		t.Fatal("ENOSPC is not IO")
	}
	if codeOf(storeErr(fmt.Errorf("read: %w", anystore.ErrCorrupt))) != codeCorrupt {
		t.Fatal("ErrCorrupt is not CORRUPT")
	}
}

// H4: a swap only flips; gc drops the orphans in bounded calls.
func TestIndexGcBounded(t *testing.T) {
	x := newIndex(t)
	mustBind(t, x, `{"dim":2,"metric":"cosine","fields":[],"textSearch":true}`)
	var rows []upsert
	for i := 0; i < 3000; i++ {
		rows = append(rows, upsert{id: fmt.Sprintf("r%05d", i), text: "some words", vec: []float32{1, float32(i)}})
	}
	ops, buf := upserts(rows...)
	mustApply(t, x, ops, buf)
	start := time.Now()
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "shadowBegin"}, map[string]any{"op": "shadowSwap"}}}, nil)
	t.Logf("swap over 3000 rows: %v", time.Since(start))
	if x.orphanCount() != 1 {
		t.Fatalf("orphans %v", x.orphans)
	}
	calls := 0
	for {
		start := time.Now()
		done, err := x.gc(0)
		if err != nil {
			t.Fatal(err)
		}
		calls++
		if took := time.Since(start); took > 250*time.Millisecond {
			t.Fatalf("gc(0) took %v", took)
		}
		if done {
			break
		}
		if calls > 1000 {
			t.Fatal("gc never finished")
		}
	}
	if calls < 3 {
		t.Fatalf("gc(0) did 3000 rows in %d calls: not bounded", calls)
	}
	names, _ := x.db.GetCollectionNames(bg)
	if len(names) != 3 {
		t.Fatalf("collections after gc: %v", names)
	}
	if done, _ := x.gc(maxWait); !done {
		t.Fatal("gc with nothing to do is not done")
	}
}

// H3: bind_start refuses a conflicting bind in the start call; the op
// builds the indexes over existing rows.
func TestIndexBindAndCloseStart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "index.anystore")
	x, err := openIndex(idxOpts(path, "", "t"))
	if err != nil {
		t.Fatal(err)
	}
	h := handles.add(x)
	op, err := indexBindStart(h, `{"dim":2,"metric":"cosine","fields":[],"textSearch":false}`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := waitOpDone(t, op, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": "a", "text": "early words", "vector": nil}}}, nil)
	if _, err := indexBindStart(h, `{"dim":3,"metric":"cosine","fields":[],"textSearch":false}`); codeOf(err) != codeConflict {
		t.Fatalf("conflict: %v", err)
	}
	op, err = indexBindStart(h, `{"dim":2,"metric":"cosine","fields":[{"key":"k","type":"string"}],"textSearch":true}`)
	if err != nil {
		t.Fatal(err)
	}
	r, err := waitOpDone(t, op, 10*time.Second)
	if err != nil || r.(map[string]any)["textSearch"] != true {
		t.Fatalf("bind op %v %v", r, err)
	}
	if res, err := x.text("early", 5, ""); err != nil || len(ids(res)) != 1 {
		t.Fatalf("text over a row written before the bind: %v %v", res, err)
	}
	cop, err := indexCloseStart(h)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := waitOpDone(t, cop, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	if _, err := indexBindStart(h, `{"dim":2,"metric":"cosine"}`); codeOf(err) != codeClosed {
		t.Fatalf("bind after close: %v", err)
	}
	if _, err := os.Stat(path + ".shimlock"); err != nil {
		t.Fatalf("index lock name: %v", err)
	}
}

// G11: more crash states; G12: undecodable stored values are CORRUPT.
func TestIndexMoreCrashStatesAndCorruptRows(t *testing.T) {
	dir := t.TempDir()
	// Unparseable sidecar, no database: rewritten.
	p1 := filepath.Join(dir, "a", "index.anystore")
	os.MkdirAll(filepath.Dir(p1), 0o700)
	os.WriteFile(p1+".keycheck", []byte("{"), 0o600)
	x, err := openIndex(idxOpts(p1, testKey, "t"))
	if err != nil {
		t.Fatalf("damaged sidecar without a file: %v", err)
	}
	x.close()
	// A zero-length database file with its sidecar: opens (initialised).
	p2 := filepath.Join(dir, "b", "index.anystore")
	os.MkdirAll(filepath.Dir(p2), 0o700)
	kc, _ := newKeycheck(nil)
	writeKeycheck(p2+".keycheck", kc)
	os.WriteFile(p2, nil, 0o600)
	x, err = openIndex(idxOpts(p2, "", "t"))
	if err != nil {
		t.Fatalf("zero-length file: %v", err)
	}
	x.close()
	// Collections without meta: CORRUPT.
	p3 := filepath.Join(dir, "c", "index.anystore")
	os.MkdirAll(filepath.Dir(p3), 0o700)
	kc, _ = newKeycheck(nil)
	writeKeycheck(p3+".keycheck", kc)
	db, err := anystore.Open(bg, p3, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Collection(bg, "something"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	if _, err := openIndex(idxOpts(p3, "", "t")); codeOf(err) != codeCorrupt {
		t.Fatalf("collections without meta: %v", err)
	}

	y := newIndex(t)
	mustBind(t, y, `{"dim":2,"metric":"cosine","fields":[],"textSearch":false}`)
	a := &anyenc.Arena{}
	bad := a.NewObject()
	bad.Set("id", a.NewString("k"))
	bad.Set("v", a.NewNumberInt(1))
	if err := y.state.UpsertOne(bg, bad); err != nil {
		t.Fatal(err)
	}
	if _, err := y.get("state", "k"); codeOf(err) != codeCorrupt {
		t.Fatalf("non-string state: %v", err)
	}
	if _, err := y.scan("state", "", "", 0); codeOf(err) != codeCorrupt {
		t.Fatalf("scan of a non-string state: %v", err)
	}
	row := a.NewObject()
	row.Set("id", a.NewString("r"))
	row.Set("embedding", a.NewString("not a vector"))
	if err := y.docs.UpsertOne(bg, row); err != nil {
		t.Logf("any-store refuses a non-vector embedding itself: %v", err)
		return
	}
	if _, err := y.get("docs", "r"); codeOf(err) != codeCorrupt {
		t.Fatalf("undecodable vector: %v", err)
	}
}
