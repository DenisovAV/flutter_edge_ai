package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	anystore "github.com/anyproto/any-store/v2"
	"github.com/anyproto/any-store/v2/anyenc"
	anysyncsdk "github.com/anyproto/any-sync-sdk"
	"github.com/anyproto/any-sync-sdk/auth"
	"github.com/anyproto/any-sync-sdk/config"
	"github.com/anyproto/any-sync-sdk/space"
)

// Tests for the review round 1 fixes (FIXES.md H1-H7, B1-B2, G1-G13).

// claimHeld reports a claim under dir. Claim keys hold the canonical
// path (symlinks resolved; on Windows also 8.3 short names such as
// RUNNER~1 expanded), so dir is canonicalised the same way first.
func claimHeld(dir string) bool {
	sub := dir
	if c, err := filepath.EvalSymlinks(dir); err == nil {
		sub = c
	}
	claims.Lock()
	defer claims.Unlock()
	for k := range claims.m {
		if strings.Contains(k, sub) {
			return true
		}
	}
	return false
}

// releasePoisoned drops the poisoned claims under dir at the end of the
// test and closes the lock file they keep, so the test's TempDir can be
// removed (Windows does not delete an open file). Registered after
// TempDir, so it runs before TempDir's removal.
func releasePoisoned(t *testing.T, dir string) {
	t.Cleanup(func() {
		sub := dir
		if c, err := filepath.EvalSymlinks(dir); err == nil {
			sub = c
		}
		claims.Lock()
		defer claims.Unlock()
		for k, c := range claims.m {
			if strings.Contains(k, sub) && c.poisoned.Load() {
				if f := c.heldLock.Load(); f != nil {
					unlockFile(f)
				}
				delete(claims.m, k)
			}
		}
	})
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

// G-R1: a panic anywhere in the close body cannot free the lock while
// the SDK is open: the SDK closes first, then the lock and claims go.
func TestClosePanicClosesSDKBeforeUnlock(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)}
	a, err := openAccount(acctOpts(t, cfg))
	if err != nil {
		t.Fatal(err)
	}
	lockPath := filepath.Join(cfg.base, "data", dataDirLockName)
	a.stopStatus = func() { panic("simulated stopStatus panic") }
	var lockedAtSDKClose, claimedAtSDKClose bool
	orig := closeSDKHook
	closeSDKHook = func(s *anysyncsdk.SDK) error {
		f, lerr := lockFile(lockPath)
		lockedAtSDKClose = codeOf(lerr) == codeBusy
		if lerr == nil {
			unlockFile(f)
		}
		claimedAtSDKClose = claimHeld(cfg.base)
		return closeSDK(s)
	}
	defer func() { closeSDKHook = orig }()
	err = a.closeNow()
	if codeOf(err) != codePanic || !strings.Contains(err.Error(), "simulated stopStatus panic") {
		t.Fatalf("close error %v, want the panic", err)
	}
	if !lockedAtSDKClose || !claimedAtSDKClose {
		t.Fatalf("at the SDK close: lock held %v, claim held %v; both must be", lockedAtSDKClose, claimedAtSDKClose)
	}
	if claimHeld(cfg.base) {
		t.Fatal("claims left after the close")
	}
	f, err := lockFile(lockPath)
	if err != nil {
		t.Fatalf("lock still held: %v", err)
	}
	unlockFile(f)
}

// G-R1: an SDK close that panics (or fails) poisons the claims: the
// directory is refused for the life of the process, never reopened next
// to a half-closed SDK.
func TestFailedSDKClosePoisonsClaim(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t), token: "p1"}
	releasePoisoned(t, cfg.base)
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
	if err := a.closeNow(); codeOf(err) != codePanic {
		t.Fatalf("close: %v", err)
	}
	for _, tok := range []string{"p1", "p2"} {
		c := cfg
		c.token = tok
		_, err := accountOpenStart(acctOpts(t, c))
		if codeOf(err) != codeRefused || !strings.Contains(err.Error(), "failed to close") || !strings.Contains(err.Error(), "simulated close panic") {
			t.Fatalf("token %s: %v, want REFUSED failed to close with the cause", tok, err)
		}
	}
	if _, err := lockFile(filepath.Join(cfg.base, "data", dataDirLockName)); codeOf(err) != codeBusy {
		t.Fatalf("the lock was released after a failed close: %v", err)
	}
}

// G-R1, index side: a failed database close poisons the index claim.
func TestFailedIndexClosePoisonsClaim(t *testing.T) {
	path := filepath.Join(t.TempDir(), "index.anystore")
	releasePoisoned(t, filepath.Dir(path))
	x, err := openIndex(idxOpts(path, "", "t"))
	if err != nil {
		t.Fatal(err)
	}
	orig := closeDBHook
	closeDBHook = func(db anystore.DB) error { _ = db.Close(); panic("simulated db close panic") }
	defer func() { closeDBHook = orig }()
	if err := x.close(); codeOf(err) != codePanic {
		t.Fatalf("close: %v", err)
	}
	_, err = openIndex(idxOpts(path, "", "t2"))
	if codeOf(err) != codeRefused || !strings.Contains(err.Error(), "failed to close") || !strings.Contains(err.Error(), "simulated db close panic") {
		t.Fatalf("reopen: %v, want REFUSED with the cause", err)
	}
}

// G3-1: a database close that returns an error (any-store closed all it
// could) reports it and releases the path.
func TestIndexCloseErrorReleases(t *testing.T) {
	path := filepath.Join(t.TempDir(), "index.anystore")
	x, err := openIndex(idxOpts(path, "", "t"))
	if err != nil {
		t.Fatal(err)
	}
	orig := closeDBHook
	closeDBHook = func(db anystore.DB) error { _ = db.Close(); return errors.New("simulated close error") }
	if err := x.close(); err == nil || !strings.Contains(err.Error(), "simulated close error") {
		closeDBHook = orig
		t.Fatalf("close: %v, want the error reported", err)
	}
	closeDBHook = orig
	y, err := openIndex(idxOpts(path, "", "t2"))
	if err != nil {
		t.Fatalf("reopen after a close error: %v", err)
	}
	y.close()
}

// G3-1: an SDK close that returns an error reports it and releases the
// directory.
func TestSDKCloseErrorReleases(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t), token: "e1"}
	a, err := openAccount(acctOpts(t, cfg))
	if err != nil {
		t.Fatal(err)
	}
	orig := closeSDKHook
	closeSDKHook = func(s *anysyncsdk.SDK) error { _ = closeSDK(s); return errors.New("simulated SDK close error") }
	err = a.closeNow()
	closeSDKHook = orig
	if err == nil || !strings.Contains(err.Error(), "simulated SDK close error") {
		t.Fatalf("close: %v", err)
	}
	if claimHeld(cfg.base) {
		t.Fatal("claims kept after a close that returned an error")
	}
	cfg.token = "e2"
	openAt(t, cfg)
}

// G-R2, G3-2: a panic inside the SDK's open poisons the directory (the SDK
// may have opened files and goroutines); a panic before it releases.
func TestOpenPanicPoisons(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)}
	releasePoisoned(t, cfg.base)
	orig := openSDKHook
	openSDKHook = func(context.Context, config.Config, auth.Provider) (*anysyncsdk.SDK, error) {
		panic("simulated open panic")
	}
	h, err := accountOpenStart(acctOpts(t, cfg))
	if err != nil {
		openSDKHook = orig
		t.Fatal(err)
	}
	_, err = waitOpDone(t, h, 10*time.Second)
	openSDKHook = orig
	if codeOf(err) != codePanic {
		t.Fatalf("open op: %v", err)
	}
	if _, err := accountOpenStart(acctOpts(t, cfg)); codeOf(err) != codeRefused || !strings.Contains(err.Error(), "open panicked") {
		t.Fatalf("reopen after a panicking SDK open: %v, want REFUSED", err)
	}
}

// G-R3: op_cancel of the close op cuts the load wait short; the wait is
// clamped.
func TestCloseWaitCutByCancel(t *testing.T) {
	if d, b := boundLoadWait(time.Hour, 0, false); d != maxWaitLoads || b {
		t.Fatal("boundLoadWait does not clamp")
	}
	// iOS reported 12 s left after the task began: 7 s, and bounded.
	if d, b := boundLoadWait(25*time.Second, 12*time.Second, true); d != 7*time.Second || !b {
		t.Fatalf("iOS bound: %v %v", d, b)
	}
	if d, b := boundLoadWait(25*time.Second, 3*time.Second, true); d != 0 || !b {
		t.Fatalf("iOS bound below 5 s: %v %v", d, b)
	}
	// No post-begin read (foreground, or main busy): the clamp only.
	if d, _ := boundLoadWait(-time.Second, 0, false); d != 0 {
		t.Fatal("boundLoadWait does not clamp")
	}
	a, err := openAccount(acctOpts(t, acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)}))
	if err != nil {
		t.Fatal(err)
	}
	a.loadWG.Add(1) // a load that never ends
	h := handles.add(a)
	ch, err := accountCloseStart(h, 25000)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	start := time.Now()
	o, _ := take[*op](ch, "an op")
	o.abandon()
	select {
	case <-a.closeDone:
	case <-time.After(10 * time.Second):
		t.Fatal("the close did not go on after op_cancel")
	}
	// The cut wait, then at most 2 s for loads that ignore the cancel.
	if took := time.Since(start); took > 4*time.Second {
		t.Fatalf("close after cancel took %v", took)
	}
	a.loadWG.Done()
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

// G-R9: a real *os.PathError carrying ENOSPC (as a write on a full disk
// returns it) is ERR_IO through storeErr; so are any-store's corrupt and
// "full" errors classified (the latter by its text: its sentinel is in an
// internal package; this is not coverage of a real full database).
func TestStoreErrClassification(t *testing.T) {
	pe := &os.PathError{Op: "write", Path: "/x/index.anystore-wal", Err: syscall.ENOSPC}
	if codeOf(storeErr(fmt.Errorf("commit: %w", pe))) != codeIO {
		t.Fatal("ENOSPC PathError is not IO")
	}
	for _, e := range []syscall.Errno{syscall.EACCES, syscall.EROFS, syscall.EDQUOT} {
		if codeOf(storeErr(&os.PathError{Op: "open", Path: "/x", Err: e})) != codeIO {
			t.Fatalf("%v is not IO", e)
		}
	}
	if codeOf(storeErr(fmt.Errorf("read: %w", anystore.ErrCorrupt))) != codeCorrupt {
		t.Fatal("ErrCorrupt is not CORRUPT")
	}
	if codeOf(storeErr(errors.New(anystoreFullText))) != codeIO {
		t.Fatal("full text is not IO")
	}
	if codeOf(storeErr(errors.New("something else"))) != codeInternal {
		t.Fatal("an unknown error is not INTERNAL")
	}
	if codeOf(openStoreErr(anystore.ErrIncompatibleVersion, "open")) != codeInternal {
		t.Fatal("incompatible version is not INTERNAL")
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
	// Bounded by rows per call, not wall time (the race detector and a
	// loaded machine stretch the time, not the rule): a 20 ms call never
	// drops the whole 3000-row generation.
	calls := 0
	for {
		done, st, err := x.gcWithStats(20 * time.Millisecond)
		if err != nil {
			t.Fatal(err)
		}
		calls++
		if st.rows >= 3000 {
			t.Fatalf("one gc(20 ms) call deleted %d rows: not bounded", st.rows)
		}
		if done {
			break
		}
		if calls > 5000 {
			t.Fatal("gc never finished")
		}
	}
	if calls < 2 {
		t.Fatalf("gc(20 ms) did 3000 rows in %d call", calls)
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
