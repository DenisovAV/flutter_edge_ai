package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// These tests use the network: a blackhole address (no answer) and LAN
// p2p between two accounts in this process, on a random mDNS service
// name, with the dead nodeconf. Never the production network. Skipped
// with -short.

// Against nodes that never answer, SyncHeads blocks ~50 s and
// SyncSpaceList ~30-60 s (measured). The ops end by their own deadline,
// and no op_wait slice takes more than ~250 ms.
func TestOpsNeverBlockAgainstBlackhole(t *testing.T) {
	if testing.Short() {
		t.Skip("network")
	}
	conf := strings.ReplaceAll(deadNodeConf(t), "127.0.0.1:9", "10.255.255.1:443")
	a, err := openAccount(acctOpts(t, acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: conf}))
	if err != nil {
		t.Fatal(err)
	}
	sid := mustCreateSpace(t, a, "bh")
	sp, err := a.space(sid)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	h := a.startOp(func(ctx context.Context) (any, error) { return a.syncHeads(ctx, sp, 2*time.Second) })
	first := time.Now()
	if _, err := waitOp(h, maxWait); codeOf(err) != codePending {
		t.Fatalf("first slice: %v, want PENDING", err)
	}
	if took := time.Since(first); took > 260*time.Millisecond {
		t.Fatalf("op_wait slice took %v", took)
	}
	r, err := waitOpDone(t, h, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	res := r.(map[string]any)
	t.Logf("sync_heads against a blackhole: %v after %v", res, time.Since(start))
	if res["reachedPeer"] != false || res["error"] == nil {
		t.Fatalf("result %v", res)
	}
	if res["timedOut"] != true && !strings.Contains(fmt.Sprint(res["error"]), "connect") {
		t.Fatalf("neither timed out nor failed to connect: %v", res)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Fatalf("a 2 s sync_heads took %v", took)
	}

	start = time.Now()
	h = a.startOp(func(ctx context.Context) (any, error) { return a.spaceListSync(ctx, 2*time.Second) })
	r, err = waitOpDone(t, h, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("space_list_sync against a blackhole: %v after %v", r, time.Since(start))
	if l := r.(map[string]any); len(l["spaces"].([]map[string]any)) == 0 {
		t.Fatalf("list sync lost the local list: %v", l)
	}
	if took := time.Since(start); took > 3*time.Second {
		t.Fatalf("a 2 s space_list_sync took %v", took)
	}

	// A sync blocked on the network when the account closes: the close
	// cancels it, the op reports CLOSED, the close op finishes, and no
	// slice of either wait blocks.
	h = a.startOp(func(ctx context.Context) (any, error) { return a.syncHeads(ctx, sp, 60*time.Second) })
	time.Sleep(100 * time.Millisecond)
	ah := handles.add(a)
	a2, _ := take[*account](ah, "an account")
	a2.beginClose(true)
	closeOp := startOp(context.Background(), func(context.Context) (any, error) { return nil, a2.finishClose(context.Background(), 0) })
	if _, err := waitOpDone(t, h, 5*time.Second); codeOf(err) != codeClosed {
		t.Fatalf("blocked sync after close: %v, want CLOSED", err)
	}
	start = time.Now()
	if _, err := waitOpDone(t, closeOp, 30*time.Second); err != nil {
		t.Fatalf("close: %v", err)
	}
	t.Logf("close with a blackhole: %v", time.Since(start))
}

// Two devices of one account over LAN p2p: the joining device resolves
// the space (a detached load), reads the bundle definitions and the
// documents the creator wrote, reaches a peer with sync_heads, and has
// everPeerSynced set without asking for it.
func TestTwoDevicesOverLAN(t *testing.T) {
	if testing.Short() {
		t.Skip("network")
	}
	m := newMnemonic(t)
	svc := fmt.Sprintf("_fea%x._tcp", rand.Int31())
	base := t.TempDir()
	A := openAt(t, acctCfg{base: filepath.Join(base, "A"), mnemonic: m, nodeConf: deadNodeConf(t), service: svc, p2p: true, token: "A"})
	sid := mustCreateSpace(t, A, "lan")
	ids := mustRagBundles(t, A, sid, true)
	doc, err := patch(A, sid, map[string]any{"create": map[string]any{"type": ids.doc}},
		[]any{map[string]any{"xkey": "doc", "value": `{"fmt":1,"key":"k"}`}, map[string]any{"xkey": "vecs", "leaf": "h1", "value": map[string]any{"dim": 2}}})
	if err != nil {
		t.Fatal(err)
	}
	docId := doc["id"].(string)
	spA, _ := A.space(sid)
	if err := setBody(A.ctx, spA, docId, "hello\nworld"); err != nil {
		t.Fatal(err)
	}
	if st, _ := A.spaceStatus(sid); st["everPeerSynced"] != false {
		t.Fatalf("A alone: %v", st)
	}

	B := openAt(t, acctCfg{base: filepath.Join(base, "B"), mnemonic: m, nodeConf: deadNodeConf(t), service: svc, p2p: true, token: "B"})
	t0 := time.Now()
	// The space list first: B learns S from the tech space.
	for {
		known, _ := B.knows(sid)
		if known {
			break
		}
		h := B.startOp(func(ctx context.Context) (any, error) { return B.spaceListSync(ctx, 5*time.Second) })
		waitOpDone(t, h, 10*time.Second)
		if time.Since(t0) > 3*time.Minute {
			t.Fatal("B never learned the space")
		}
	}
	t.Logf("B knows the space after %v", time.Since(t0))
	h := B.startOp(func(ctx context.Context) (any, error) { return B.resolve(ctx, sid) })
	if _, err := waitOpDone(t, h, 4*time.Minute); err != nil {
		t.Fatalf("resolve on B: %v", err)
	}
	t.Logf("B resolved the space after %v", time.Since(t0))
	// While nothing else needs the space, other calls never block.
	var bIds ragIds
	for {
		start := time.Now()
		r, err := B.ragBundles(sid, false)
		if took := time.Since(start); took > time.Second {
			t.Fatalf("rag_bundles(read) took %v", took)
		}
		if err == nil {
			loc, d := r["location"].(bundleIds), r["document"].(bundleIds)
			bIds = ragIds{loc: loc.RootId, doc: d.RootId, core: loc.Properties["core"], fields: loc.Properties["fields"],
				profiles: loc.Properties["profiles"], textSe: loc.Properties["textSearch"],
				docProp: d.Properties["doc"], vecs: d.Properties["vecs"], tombstones: loc.Tombstones}
			break
		}
		if codeOf(err) != codeNotFound || time.Since(t0) > 5*time.Minute {
			t.Fatalf("rag_bundles on B: %v", err)
		}
		time.Sleep(200 * time.Millisecond)
	}
	if bIds != ids {
		t.Fatalf("B reads other ids: %+v vs %+v", bIds, ids)
	}
	h = B.startOp(func(ctx context.Context) (any, error) {
		sp, err := B.space(sid)
		if err != nil {
			return nil, err
		}
		return B.syncHeads(ctx, sp, 20*time.Second)
	})
	r, err := waitOpDone(t, h, 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("B sync_heads: %v", r)
	if r.(map[string]any)["reachedPeer"] != true {
		t.Fatalf("B sync_heads did not reach A: %v", r)
	}
	req, _ := json.Marshal(map[string]any{"ids": []string{docId}, "xkeys": []string{"doc", "vecs"}})
	deadline := time.Now().Add(2 * time.Minute)
	for {
		rr, err := B.objectRead(sid, string(req))
		if err != nil {
			t.Fatal(err)
		}
		it := rr["items"].([]map[string]any)[0]
		if it["state"] == "ok" {
			if it["props"].(map[string]any)["doc"] != `{"fmt":1,"key":"k"}` {
				t.Fatalf("B reads %v", it)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("B never saw the document: %v", it)
		}
		time.Sleep(200 * time.Millisecond)
	}
	for _, x := range []*account{A, B} {
		deadline := time.Now().Add(time.Minute)
		for {
			st, err := x.spaceStatus(sid)
			if err != nil {
				t.Fatal(err)
			}
			if st["everPeerSynced"] == true && x.state.get(sid).EverPeerSynced {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("everPeerSynced not set: %v", st)
			}
			time.Sleep(200 * time.Millisecond)
		}
	}
	st, _ := B.spaceStatus(sid)
	if st["createdHere"] != false || st["lastSyncedAt"] == nil {
		t.Fatalf("B status %v", st)
	}
	deadline = time.Now().Add(time.Minute)
	for {
		s, _ := A.objectSyncState(sid, docId)
		if s["state"] == "synced" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("A's document never synced: %v", s)
		}
		time.Sleep(200 * time.Millisecond)
	}
}
