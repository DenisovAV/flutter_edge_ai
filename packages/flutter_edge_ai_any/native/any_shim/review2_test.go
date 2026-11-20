package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Tests for review round 2 (FIXES-r2.md G-R1..G-R10); G-R1..G-R3 and
// the storeErr part of G-R9 are in review_test.go.

// G-R4: while a bind (or swap) holds the index exclusively, index calls
// answer PENDING at once instead of blocking.
func TestIndexCallsPendingWhileExclusive(t *testing.T) {
	x := newIndex(t)
	mustBind(t, x, `{"dim":2,"metric":"cosine","fields":[],"textSearch":false}`)
	x.mu.Lock() // what a bind op holds while it builds indexes
	start := time.Now()
	if _, err := x.enter(); codeOf(err) != codePending {
		t.Fatalf("shared entry: %v", err)
	}
	if _, err := applyJSON(x, map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": "a"}}}, nil); codeOf(err) != codePending {
		t.Fatalf("apply: %v", err)
	}
	if took := time.Since(start); took > 50*time.Millisecond {
		t.Fatalf("shared calls took %v", took)
	}
	start = time.Now()
	if _, err := applyJSON(x, map[string]any{"ops": []any{map[string]any{"op": "shadowBegin"}}}, nil); codeOf(err) != codePending {
		t.Fatalf("swap apply: %v", err)
	}
	if took := time.Since(start); took > maxWait+100*time.Millisecond {
		t.Fatalf("a swap apply waited %v", took)
	}
	h := handles.add(x)
	if _, err := indexBindStart(h, `{"dim":2,"metric":"cosine","fields":[],"textSearch":true}`); codeOf(err) != codePending {
		t.Fatalf("bind_start: %v", err)
	}
	handles.remove(h)
	x.mu.Unlock()
	if _, err := applyJSON(x, map[string]any{"ops": []any{map[string]any{"op": "upsert", "coll": "docs", "id": "a"}}}, nil); err != nil {
		t.Fatalf("after the lock: %v", err)
	}
}

// G-R5: a declared bundle property missing from a non-empty definition
// list was removed: REFUSED, not NOT_FOUND.
func TestRagBundlesRemovedPropertyRefused(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "rm")
	ids := mustRagBundles(t, a, sid, true)
	sp, _ := a.space(sid)
	if err := sp.Types().RemoveProperty(a.ctx, ids.loc, ids.fields); err != nil {
		t.Fatal(err)
	}
	for _, ensure := range []bool{false, true} {
		if _, err := a.ragBundles(sid, ensure); codeOf(err) != codeRefused || !strings.Contains(err.Error(), "removed") {
			t.Fatalf("ensure=%v: %v, want REFUSED", ensure, err)
		}
	}
}

// G-R6: one gc step stays within its slice; measured on 1000 rows of
// ~400-word texts at dim 768 with text search on.
func TestIndexGcStepMeasured(t *testing.T) {
	if testing.Short() {
		t.Skip("measurement")
	}
	x := newIndex(t)
	mustBind(t, x, `{"dim":768,"metric":"cosine","fields":[{"key":"k","type":"string"}],"textSearch":true}`)
	rng := rand.New(rand.NewSource(1))
	words := strings.Fields("the quick brown fox jumps over a lazy dog while methane lakes shimmer on titan under nitrogen skies and rings of saturn turn slowly beyond")
	for page := 0; page < 10; page++ {
		var rows []upsert
		for i := 0; i < 100; i++ {
			var b strings.Builder
			for w := 0; w < 400; w++ {
				b.WriteString(words[rng.Intn(len(words))])
				b.WriteString(fmt.Sprintf("%d ", rng.Intn(500)))
			}
			v := make([]float32, 768)
			for j := range v {
				v[j] = rng.Float32()*2 - 1
			}
			rows = append(rows, upsert{id: fmt.Sprintf("r%05d", page*100+i), text: b.String(), vec: v, f: map[string]any{"k": "v"}})
		}
		ops, buf := upserts(rows...)
		mustApply(t, x, ops, buf)
	}
	mustApply(t, x, map[string]any{"ops": []any{map[string]any{"op": "shadowBegin"}, map[string]any{"op": "shadowSwap"}}}, nil)
	start := time.Now()
	done, st, err := x.gcWithStats(0) // one step: at least one row, slice 1 ms
	min0 := time.Since(start)
	if err != nil || done {
		t.Fatalf("gc(0): %v %v", done, err)
	}
	start = time.Now()
	_, st250, err := x.gcWithStats(maxWait)
	took := time.Since(start)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("gc on 1000 rows (400 words, dim 768, text search): gc(0) %v for %d rows in %d step; gc(250ms) %v for %d rows in %d steps",
		min0, st.rows, st.steps, took, st250.rows, st250.steps)
	if took > maxWait+250*time.Millisecond {
		t.Fatalf("gc(250 ms) took %v", took)
	}
	calls := 2
	for {
		done, err := x.gc(maxWait)
		if err != nil {
			t.Fatal(err)
		}
		calls++
		if done {
			break
		}
	}
	t.Logf("gc of the whole orphan generation: %d calls of 250 ms", calls)
}

// G-R8: a failed background save leaves the state dirty; the next sync
// update (even with nothing new) and flush save again.
func TestStateSaveRetried(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs POSIX permissions")
	}
	dir := t.TempDir()
	st, err := loadAccountState(dir)
	if err != nil {
		t.Fatal(err)
	}
	os.Chmod(dir, 0o500)
	if err := st.update("s1", false, func(s *spaceState) { s.EverPeerSynced = true }); err != nil {
		t.Fatal(err)
	}
	st.wg.Wait()
	if st.saveError() == nil {
		t.Fatal("background save did not fail")
	}
	if err := st.update("s1", true, func(s *spaceState) { s.EverPeerSynced = true }); codeOf(err) != codeIO {
		t.Fatalf("sync update with nothing new while the disk fails: %v, want IO", err)
	}
	os.Chmod(dir, 0o700)
	if err := st.update("s1", true, func(s *spaceState) { s.EverPeerSynced = true }); err != nil {
		t.Fatalf("retry: %v", err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, stateFileName))
	if !strings.Contains(string(b), "s1") {
		t.Fatalf("not saved: %s", b)
	}
	// flush retries too.
	os.Chmod(dir, 0o500)
	_ = st.update("s2", false, func(s *spaceState) { s.CreatedHere = true })
	st.wg.Wait()
	os.Chmod(dir, 0o700)
	if err := st.flush(); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(filepath.Join(dir, stateFileName))
	if !strings.Contains(string(b), "s2") {
		t.Fatalf("flush did not save: %s", b)
	}
}

// G-R9: an account a finished open op holds for another owner token (a
// hot restart's dead generation) is released by the next open of the
// same directories; one of the same token is left alone.
func TestUndeliveredOpenReleased(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t), token: "old"}
	oh, err := accountOpenStart(acctOpts(t, cfg))
	if err != nil {
		t.Fatal(err)
	}
	o, _ := lookup[*op](oh, "an op")
	<-o.done
	same := cfg
	if _, err := accountOpenStart(acctOpts(t, same)); codeOf(err) != codeRefused {
		t.Fatalf("same token: %v", err)
	}
	if _, err := lookup[*op](oh, "an op"); err != nil {
		t.Fatal("the same token released the undelivered open")
	}
	next := cfg
	next.token = "new"
	deadline := time.Now().Add(20 * time.Second)
	var h uint64
	for {
		h, err = accountOpenStart(acctOpts(t, next))
		if err == nil {
			break
		}
		if codeOf(err) != codeBusy || time.Now().After(deadline) {
			t.Fatalf("next generation: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := lookup[*op](oh, "an op"); codeOf(err) != codeClosed {
		t.Fatalf("the undelivered open op is still there: %v", err)
	}
	r, err := waitOpDone(t, h, 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	ah := r.(map[string]any)["account"].(uint64)
	c, _ := accountCloseStart(ah, 0)
	waitOpDone(t, c, 30*time.Second)
	_ = json.Marshal
	_ = context.Background
}
