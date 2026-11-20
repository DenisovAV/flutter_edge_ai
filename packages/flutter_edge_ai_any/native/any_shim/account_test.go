package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anyproto/any-sync-sdk/auth"
	"github.com/anyproto/any-sync-sdk/space"

	editor "anyshim/third_party/any_editor"
)

func deadNodeConf(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("testdata/nodeconf-dead.yml")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

type acctCfg struct {
	base, mnemonic, token, nodeConf, service string
	p2p                                      bool
}

func acctOpts(t *testing.T, c acctCfg) string {
	t.Helper()
	dev, err := auth.GenerateDeviceKey(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	p2p := map[string]any{"enabled": c.p2p}
	if c.service != "" {
		p2p["serviceName"] = c.service
	}
	if c.token == "" {
		c.token = "tok"
	}
	opts, _ := json.Marshal(map[string]any{
		"dataDir": filepath.Join(c.base, "data"), "indexDir": filepath.Join(c.base, "index"),
		"ownerToken": c.token, "mnemonic": c.mnemonic, "deviceKeyHex": hex.EncodeToString(dev),
		"nodeConfYaml": c.nodeConf, "p2p": p2p,
	})
	return string(opts)
}

func newMnemonic(t *testing.T) string {
	m, err := auth.GenerateMnemonic()
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// openOffline opens a fresh test account with p2p off: no network at all.
func openOffline(t *testing.T) *account {
	t.Helper()
	return openAt(t, acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)})
}

func openAt(t *testing.T, c acctCfg) *account {
	t.Helper()
	a, err := openAccount(acctOpts(t, c))
	if err != nil {
		t.Fatalf("openAccount: %v", err)
	}
	t.Cleanup(func() { _ = a.closeNow() })
	return a
}

func mustCreateSpace(t *testing.T, a *account, name string) string {
	t.Helper()
	r, err := a.createSpace(name)
	if err != nil {
		t.Fatal(err)
	}
	return r["id"].(string)
}

// waitOpDone polls an op as Dart does, in ≤250 ms slices, and checks no
// slice took much longer.
func waitOpDone(t *testing.T, h uint64, max time.Duration) (any, error) {
	t.Helper()
	deadline := time.Now().Add(max)
	for {
		start := time.Now()
		r, err := waitOp(h, maxWait)
		if took := time.Since(start); took > maxWait+100*time.Millisecond {
			t.Errorf("op_wait took %v", took)
		}
		if codeOf(err) != codePending {
			return r, err
		}
		if time.Now().After(deadline) {
			t.Fatalf("op still pending after %v", max)
		}
	}
}

func TestOpenRefusesBadOptions(t *testing.T) {
	nc := deadNodeConf(t)
	prod := strings.Replace(nc, "N4N1wDHFpFpovXBqdbq2TDXE9tXdXbtV1eTJFpKJW4YeaJqR", "N83gJpVd9MuNRZAuJLZ7LiMntTThhPc6DtzWWVjb1M3PouVU", 1)
	dir := t.TempDir()
	base := map[string]any{"dataDir": filepath.Join(dir, "d"), "indexDir": filepath.Join(dir, "i"),
		"ownerToken": "t", "mnemonic": "x", "deviceKeyHex": "00", "nodeConfYaml": nc}
	with := func(k string, v any) string {
		m := map[string]any{}
		for kk, vv := range base {
			m[kk] = vv
		}
		if v == nil {
			delete(m, k)
		} else {
			m[k] = v
		}
		b, _ := json.Marshal(m)
		return string(b)
	}
	cases := []struct {
		name, opts string
		code       int
	}{
		{"no nodeconf", with("nodeConfYaml", nil), codeInvalidArgument},
		{"nodeconf without networkId", with("nodeConfYaml", "nodes: []\n"), codeInvalidArgument},
		{"production network", with("nodeConfYaml", prod), codeRefused},
		{"no dataDir", with("dataDir", nil), codeInvalidArgument},
		{"no indexDir", with("indexDir", nil), codeInvalidArgument},
		{"no ownerToken", with("ownerToken", nil), codeInvalidArgument},
		{"same data and index dir", with("indexDir", filepath.Join(dir, "d")), codeInvalidArgument},
		{"bad device key", with("deviceKeyHex", "zz"), codeInvalidArgument},
		{"unknown option", with("wallet", "file"), codeInvalidArgument},
		{"bad log level", with("logLevel", "verbose"), codeInvalidArgument},
		{"not JSON", "{", codeInvalidArgument},
	}
	for _, c := range cases {
		_, err := openAccount(c.opts)
		if codeOf(err) != c.code {
			t.Errorf("%s: code %d (%v), want %d", c.name, codeOf(err), err, c.code)
		}
	}
	// A refused open leaves no claim behind.
	if len(claims.m) != 0 {
		for k := range claims.m {
			if strings.Contains(k, dir) {
				t.Fatalf("claim left after refused opens: %s", k)
			}
		}
	}
}

func TestOptionsRejectTrailingData(t *testing.T) {
	var o openOpts
	for _, s := range []string{`{"dataDir":"x"} garbage`, `{"dataDir":"x"}{"dataDir":"y"}`} {
		if err := decodeStrict(s, &o); codeOf(err) != codeInvalidArgument {
			t.Errorf("%s: %v", s, err)
		}
	}
	if err := decodeStrict(`{"dataDir":"x"}  `, &o); err != nil {
		t.Errorf("trailing whitespace: %v", err)
	}
}

func TestLookupWrongKind(t *testing.T) {
	h := handles.add("not an account")
	defer handles.remove(h)
	if _, err := lookup[*account](h, "an account"); codeOf(err) != codeInvalidArgument {
		t.Fatalf("wrong kind: %v", err)
	}
	if _, err := lookup[*account](1<<62, "an account"); codeOf(err) != codeClosed {
		t.Fatalf("never issued: %v", err)
	}
	if _, err := take[*account](h, "an account"); codeOf(err) != codeInvalidArgument {
		t.Fatalf("take of another kind: %v", err)
	}
}

// Owner tokens: a directory held by another token, or closing, is BUSY;
// by the same token REFUSED; a release is idempotent and stale handles
// are no-ops; after the release the next generation gets in.
func TestOwnerTokenBusyAndRelease(t *testing.T) {
	m := newMnemonic(t)
	base := t.TempDir()
	cfg := acctCfg{base: base, mnemonic: m, nodeConf: deadNodeConf(t), token: "gen1"}
	a, err := openAccount(acctOpts(t, cfg))
	if err != nil {
		t.Fatal(err)
	}
	h := handles.add(a)
	cfg2 := cfg
	cfg2.token = "gen2"
	if _, err := openAccount(acctOpts(t, cfg2)); codeOf(err) != codeBusy {
		t.Fatalf("another token: %v, want BUSY", err)
	}
	if _, err := openAccount(acctOpts(t, cfg)); codeOf(err) != codeRefused {
		t.Fatalf("same token: %v, want REFUSED", err)
	}
	// Another data dir sharing the index dir: refused by name.
	shared := map[string]any{}
	json.Unmarshal([]byte(acctOpts(t, cfg2)), &shared)
	shared["dataDir"] = filepath.Join(t.TempDir(), "other")
	b, _ := json.Marshal(shared)
	if _, err := openAccount(string(b)); codeOf(err) != codeBusy || !strings.Contains(err.Error(), "indexDir") {
		t.Fatalf("shared indexDir: %v, want BUSY naming indexDir", err)
	}

	start := time.Now()
	releaseAccount(h)
	if took := time.Since(start); took > 50*time.Millisecond {
		t.Fatalf("release blocked for %v", took)
	}
	releaseAccount(h) // already released: no-op
	releaseAccount(0) // never issued
	releaseAccount(1 << 62)
	other := handles.add("not an account")
	releaseAccount(other) // another kind: left alone
	if _, err := lookup[string](other, "x"); err != nil {
		t.Fatalf("release took a handle of another kind: %v", err)
	}
	handles.remove(other)
	if _, err := lookup[*account](h, "an account"); codeOf(err) != codeClosed {
		t.Fatalf("released handle: %v", err)
	}
	if _, err := a.enter(); codeOf(err) != codeClosed {
		t.Fatalf("call on a released account: %v", err)
	}
	var b2 *account
	sawBusy := false
	deadline := time.Now().Add(20 * time.Second)
	for {
		b2, err = openAccount(acctOpts(t, cfg2))
		if err == nil {
			break
		}
		if codeOf(err) != codeBusy || time.Now().After(deadline) {
			t.Fatalf("open after release: %v", err)
		}
		sawBusy = true
		time.Sleep(20 * time.Millisecond)
	}
	t.Logf("next generation opened %v after the release (busy seen: %v)", time.Since(start), sawBusy)
	if err := b2.closeNow(); err != nil {
		t.Fatal(err)
	}
	if err := b2.closeNow(); codeOf(err) != codeClosed {
		t.Fatalf("second close: %v", err)
	}
}

func TestCloseStartOpAndCancel(t *testing.T) {
	a, err := openAccount(acctOpts(t, acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)}))
	if err != nil {
		t.Fatal(err)
	}
	sid := mustCreateSpace(t, a, "c")
	polled := make(chan error)
	go func() {
		_, err := a.events.poll(0, maxWait)
		polled <- err
	}()
	a.cancelCalls()
	if _, err := a.enter(); codeOf(err) != codeClosed {
		t.Fatalf("call after cancel: %v", err)
	}
	if _, err := a.space(sid); codeOf(err) != codeClosed && codeOf(err) != codeOK {
		t.Fatalf("space after cancel: %v", err)
	}
	h := handles.add(a)
	// What any_shim_account_close_start does.
	a2, err := take[*account](h, "an account")
	if err != nil {
		t.Fatal(err)
	}
	a2.beginClose()
	op := startOp(context.Background(), func(context.Context) (any, error) { return map[string]any{}, a2.finishClose() })
	r, err := waitOpDone(t, op, 30*time.Second)
	if err != nil {
		t.Fatalf("close op: %v", err)
	}
	if b, _ := json.Marshal(r); string(b) != "{}" {
		t.Fatalf("close result %s", b)
	}
	if err := <-polled; codeOf(err) != codeClosed && err != nil {
		t.Fatalf("poller: %v", err)
	}
	if _, err := waitOp(op, 0); codeOf(err) != codeClosed {
		t.Fatalf("op handle after delivery: %v", err)
	}
}

func TestOpsWaitPendingDeliverCancel(t *testing.T) {
	if d := clampWait(10000); d != maxWait {
		t.Fatalf("clamp 10000 = %v", d)
	}
	if d := clampWait(-5); d != 0 {
		t.Fatalf("clamp -5 = %v", d)
	}
	release := make(chan struct{})
	h := startOp(context.Background(), func(ctx context.Context) (any, error) {
		<-release
		return map[string]any{"v": 1}, nil
	})
	start := time.Now()
	if _, err := waitOp(h, 50*time.Millisecond); codeOf(err) != codePending {
		t.Fatalf("running op: %v", err)
	}
	if took := time.Since(start); took < 40*time.Millisecond || took > 200*time.Millisecond {
		t.Fatalf("wait of 50 ms took %v", took)
	}
	close(release)
	r, err := waitOpDone(t, h, 5*time.Second)
	if err != nil || r.(map[string]any)["v"] != 1 {
		t.Fatalf("result %v %v", r, err)
	}
	if _, err := waitOp(h, 0); codeOf(err) != codeClosed {
		t.Fatalf("second wait: %v", err)
	}
	// Cancel: never blocks, the handle goes, the op's context ends.
	ended := make(chan struct{})
	h = startOp(context.Background(), func(ctx context.Context) (any, error) {
		<-ctx.Done()
		close(ended)
		return nil, ctx.Err()
	})
	o, err := take[*op](h, "an op")
	if err != nil {
		t.Fatal(err)
	}
	o.cancel()
	select {
	case <-ended:
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not reach the op")
	}
	if _, err := waitOp(h, 0); codeOf(err) != codeClosed {
		t.Fatalf("wait after cancel: %v", err)
	}
	// A panic in an op is its PANIC result.
	h = startOp(context.Background(), func(context.Context) (any, error) { panic("boom") })
	if _, err := waitOpDone(t, h, 5*time.Second); codeOf(err) != codePanic {
		t.Fatalf("panicking op: %v", err)
	}
}

// A failed load frees the single-flight slot; a loaded space is cached.
func TestSpaceLoadSingleFlight(t *testing.T) {
	a := openOffline(t)
	bogus := "bafyreinosuchspacexxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.abc"
	l1, err := a.startLoad(bogus)
	if err != nil {
		t.Fatal(err)
	}
	<-l1.done
	if codeOf(loadErr(bogus, l1.err)) != codeNotFound {
		t.Fatalf("unknown space load: %v", l1.err)
	}
	if a.loading(bogus) {
		t.Fatal("a failed load still reads as loading")
	}
	a.loadsMu.Lock()
	_, kept := a.loads[bogus]
	a.loadsMu.Unlock()
	if kept {
		t.Fatal("a failed load kept its slot")
	}
	l2, _ := a.startLoad(bogus)
	if l2 == l1 {
		t.Fatal("a failed load was reused")
	}
	<-l2.done
	if _, err := a.space(bogus); codeOf(err) != codeNotFound {
		t.Fatalf("space(unknown): %v", err)
	}
	h := a.startOp(func(ctx context.Context) (any, error) { return a.resolve(ctx, bogus) })
	if _, err := waitOpDone(t, h, 5*time.Second); codeOf(err) != codeNotFound {
		t.Fatalf("resolve unknown: %v", err)
	}
	sid := mustCreateSpace(t, a, "s")
	s1, err := a.space(sid)
	if err != nil {
		t.Fatal(err)
	}
	h = a.startOp(func(ctx context.Context) (any, error) { return a.resolve(ctx, sid) })
	r, err := waitOpDone(t, h, 5*time.Second)
	if err != nil || r.(map[string]any)["spaceId"] != sid {
		t.Fatalf("resolve: %v %v", r, err)
	}
	s2, _ := a.space(sid)
	if s1 != s2 {
		t.Fatal("a second call loaded the space again")
	}
	if _, err := a.space(""); codeOf(err) != codeInvalidArgument {
		t.Fatalf("empty id: %v", err)
	}
}

// A space the account stored on an earlier run loads in the background
// within the fast wait.
func TestSpaceLoadsAfterReopen(t *testing.T) {
	cfg := acctCfg{base: t.TempDir(), mnemonic: newMnemonic(t), nodeConf: deadNodeConf(t)}
	a, err := openAccount(acctOpts(t, cfg))
	if err != nil {
		t.Fatal(err)
	}
	sid := mustCreateSpace(t, a, "persist")
	if err := a.closeNow(); err != nil {
		t.Fatal(err)
	}
	b := openAt(t, cfg)
	var sp space.Space
	deadline := time.Now().Add(10 * time.Second)
	for sp == nil {
		s, err := b.space(sid)
		switch {
		case err == nil:
			sp = s
		case codeOf(err) == codePending && time.Now().Before(deadline):
		default:
			t.Fatalf("space after reopen: %v", err)
		}
	}
	st, err := b.spaceStatus(sid)
	if err != nil {
		t.Fatal(err)
	}
	if st["createdHere"] != true || st["everPeerSynced"] != false || st["lastSyncedAt"] != nil || st["loading"] != false {
		t.Fatalf("status after reopen = %v", st)
	}
}

func TestSpaceStatusAndList(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "s")
	st, err := a.spaceStatus(sid)
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"spaceId", "state", "loading", "p2p", "localPeers", "networkPeers", "globalPeers", "synced", "total", "lastSyncedAt", "everPeerSynced", "createdHere"} {
		if _, ok := st[k]; !ok {
			t.Errorf("status lacks %q: %v", k, st)
		}
	}
	if st["createdHere"] != true || st["everPeerSynced"] != false {
		t.Fatalf("status = %v", st)
	}
	if _, err := a.spaceStatus("bafyreinosuchspace.abc"); codeOf(err) != codeNotFound {
		t.Fatalf("unknown space: code %d (%v)", codeOf(err), err)
	}
	l, err := a.spaceListJSON(a.ctx)
	if err != nil || len(l) == 0 {
		t.Fatalf("list: %v %v", l, err)
	}
	// The flag persists in the account state file.
	b, err := os.ReadFile(a.state.path)
	if err != nil || !strings.Contains(string(b), sid) {
		t.Fatalf("state file: %s %v", b, err)
	}
}

func TestEverPeerSyncedPersists(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "s")
	a.markPeerSynced(sid, true)
	path := a.state.path
	st, err := loadAccountState(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if s := st.get(sid); !s.EverPeerSynced || !s.CreatedHere {
		t.Fatalf("state = %+v", s)
	}
	// A damaged state file is CORRUPT, never silently reset.
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadAccountState(filepath.Dir(path)); codeOf(err) != codeCorrupt {
		t.Fatalf("damaged state: %v", err)
	}
}

// ---------------------------------------------------------- rag bundles

// The declarations are frozen forever once published: this golden is
// the published shape. Changing it means a new bundle id.
func TestRagBundleDeclarationsFrozen(t *testing.T) {
	enc := func(r space.EnsureBundleRequest) string {
		if r.NewRoot != nil {
			t.Fatal("a derived bundle has no NewRoot")
		}
		// Every field but the NewRoot func, which JSON cannot carry.
		v := struct {
			Id                 string
			Name               string
			DerivedRoot        bool
			RootType           string
			RootCollections    []string
			RootProperties     map[string]map[string]any
			Parts              []space.PartDraft
			Properties         []space.PropertyDraft
			XKey               string
			Layout             map[string]any
			Hidden, Collection bool
		}{r.Id, r.Name, r.DerivedRoot, r.RootType, r.RootCollections, r.RootProperties, r.Parts, r.Properties, r.XKey, r.Layout, r.Hidden, r.Collection}
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	const loc = `{"Id":"flutter_edge_ai.rag.location/v1","Name":"RAG location","DerivedRoot":true,"RootType":"","RootCollections":null,"RootProperties":null,"Parts":[{"Key":"tomb","Name":"Tombstones","Icon":"","Pos":"","Hidden":true,"UI":null,"Uses":null,"Datasets":[{"Key":"tombstones","Module":"records","Shared":false,"DisplayName":"","Description":"","Dynamic":false,"IdRule":1,"IdPattern":"[0-9a-f]{64}|clear","IdMaxLen":64,"DeleteBy":2,"SkipHistory":false,"Search":null,"Indexes":null,"Fields":[{"Key":"key","Name":"","Description":"","Kind":1,"Shape":null,"Scope":0,"Required":false,"MutableBy":2,"Stamp":0,"XFormat":null},{"Key":"revs","Name":"","Description":"","Kind":5,"Shape":null,"Scope":0,"Required":false,"MutableBy":2,"Stamp":0,"XFormat":null}]}]}],"Properties":[{"Name":"core","Description":"","XKey":"core","Meta":null,"Kind":1,"Items":null,"Properties":null,"Required":null,"Scope":0,"XFormat":null},{"Name":"fields","Description":"","XKey":"fields","Meta":null,"Kind":6,"Items":null,"Properties":null,"Required":null,"Scope":0,"XFormat":null},{"Name":"profiles","Description":"","XKey":"profiles","Meta":null,"Kind":6,"Items":null,"Properties":null,"Required":null,"Scope":0,"XFormat":null},{"Name":"textSearch","Description":"","XKey":"textSearch","Meta":null,"Kind":3,"Items":null,"Properties":null,"Required":null,"Scope":0,"XFormat":null}],"XKey":"flutter_edge_ai.rag.location","Layout":null,"Hidden":true,"Collection":false}`
	const doc = `{"Id":"flutter_edge_ai.rag.document/v1","Name":"RAG document","DerivedRoot":true,"RootType":"","RootCollections":null,"RootProperties":null,"Parts":[{"Key":"body","Name":"Body","Icon":"","Pos":"","Hidden":false,"UI":{"type":"document"},"Uses":null,"Datasets":[{"Key":"","Module":"editor","Shared":false,"DisplayName":"","Description":"","Dynamic":false,"IdRule":0,"IdPattern":"","IdMaxLen":0,"DeleteBy":0,"SkipHistory":false,"Search":null,"Indexes":null,"Fields":null}]}],"Properties":[{"Name":"doc","Description":"","XKey":"doc","Meta":null,"Kind":1,"Items":null,"Properties":null,"Required":null,"Scope":0,"XFormat":null},{"Name":"vecs","Description":"","XKey":"vecs","Meta":null,"Kind":6,"Items":null,"Properties":null,"Required":null,"Scope":0,"XFormat":null}],"XKey":"flutter_edge_ai.rag.document","Layout":null,"Hidden":true,"Collection":false}`
	// The numbers of the golden, by name: they are the SDK's enums.
	ds := ragLocationBundle().Parts[0].Datasets[0]
	if ds.IdRule != space.IdUser || ds.DeleteBy != space.DeleteByNone ||
		ds.Fields[0].MutableBy != space.MutableByAnyone || ds.Fields[1].MutableBy != space.MutableByAnyone ||
		ds.Fields[0].Kind != space.PropertyKindString || ds.Fields[1].Kind != space.PropertyKindArray {
		t.Fatalf("tombstone declaration: %+v", ds)
	}
	if got := enc(ragLocationBundle()); got != loc {
		t.Errorf("location bundle changed:\n got %s\nwant %s", got, loc)
	}
	if got := enc(ragDocumentBundle()); got != doc {
		t.Errorf("document bundle changed:\n got %s\nwant %s", got, doc)
	}
}

type ragIds struct {
	loc, doc         string
	core, fields     string
	docProp, vecs    string
	tombstones       string
	profiles, textSe string
}

func mustRagBundles(t *testing.T, a *account, sid string, ensure bool) ragIds {
	t.Helper()
	r, err := a.ragBundles(sid, ensure)
	if err != nil {
		t.Fatalf("ragBundles(ensure=%v): %v", ensure, err)
	}
	loc, doc := r["location"].(bundleIds), r["document"].(bundleIds)
	return ragIds{loc: loc.RootId, doc: doc.RootId, core: loc.Properties["core"], fields: loc.Properties["fields"],
		profiles: loc.Properties["profiles"], textSe: loc.Properties["textSearch"],
		docProp: doc.Properties["doc"], vecs: doc.Properties["vecs"], tombstones: loc.Tombstones}
}

func TestRagBundlesEnsureAndRead(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "rag")
	if _, err := a.ragBundles(sid, false); codeOf(err) != codeNotFound {
		t.Fatalf("read before ensure: %v, want NOT_FOUND", err)
	}
	ids := mustRagBundles(t, a, sid, true)
	if ids.loc == "" || ids.doc == "" || ids.core == "" || ids.fields == "" || ids.profiles == "" || ids.textSe == "" || ids.docProp == "" || ids.vecs == "" {
		t.Fatalf("ids = %+v", ids)
	}
	if ids.tombstones != ids.loc+"_tombstones" {
		t.Fatalf("tombstones collection %q", ids.tombstones)
	}
	if again := mustRagBundles(t, a, sid, true); again != ids {
		t.Fatalf("second ensure: %+v vs %+v", again, ids)
	}
	if read := mustRagBundles(t, a, sid, false); read != ids {
		t.Fatalf("read: %+v vs %+v", read, ids)
	}
	sp, _ := a.space(sid)
	derived, _ := sp.Bundles().DerivedRootId(a.ctx, ragLocationBundleId)
	if derived != ids.loc {
		t.Fatal("location root is not the derived root")
	}
}

// ----------------------------------------------------------- objects

func patch(a *account, sid string, target any, ops any) (map[string]any, error) {
	tb, _ := json.Marshal(target)
	ob, _ := json.Marshal(ops)
	return a.objectPatch(sid, string(tb), string(ob))
}

func countType(t *testing.T, a *account, sid, typeId string) int {
	t.Helper()
	sp, _ := a.space(sid)
	n, err := sp.QueryObjects().Filter(map[string]any{"any.type": typeId}).Count(a.ctx)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestObjectPatchCreateDeriveAndErrors(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "obj")
	ids := mustRagBundles(t, a, sid, true)

	// Create: doc and one vector leaf in one change.
	r, err := patch(a, sid, map[string]any{"create": map[string]any{"type": ids.doc}},
		[]any{map[string]any{"xkey": "doc", "value": `{"fmt":1}`}, map[string]any{"xkey": "vecs", "leaf": "abc-123", "value": map[string]any{"fmt": 1, "dim": 4}}})
	if err != nil {
		t.Fatal(err)
	}
	id := r["id"].(string)
	if r["created"] != true {
		t.Fatalf("create = %v", r)
	}
	sp, _ := a.space(sid)
	row, _ := sp.Objects().Get(a.ctx, id)
	if string(row.GetStringBytes(ids.doc, ids.docProp)) != `{"fmt":1}` || row.GetInt(ids.doc, ids.vecs, "abc-123", "dim") != 4 {
		t.Fatalf("row = %s", row)
	}

	// A second leaf on the existing object, by id.
	if _, err := patch(a, sid, map[string]any{"id": id}, []any{map[string]any{"xkey": "vecs", "leaf": "def", "value": map[string]any{"dim": 8}}}); err != nil {
		t.Fatal(err)
	}
	row, _ = sp.Objects().Get(a.ctx, id)
	if row.GetInt(ids.doc, ids.vecs, "abc-123", "dim") != 4 || row.GetInt(ids.doc, ids.vecs, "def", "dim") != 8 {
		t.Fatalf("leaves after patch: %s", row)
	}

	before := countType(t, a, sid, ids.doc)
	cases := []struct {
		name   string
		target any
		ops    any
		code   int
	}{
		{"wrong kind on create", map[string]any{"create": map[string]any{"type": ids.doc}}, []any{map[string]any{"xkey": "doc", "value": 42}}, codeRefused},
		{"wrong kind by id", map[string]any{"id": id}, []any{map[string]any{"xkey": "doc", "value": 42}}, codeRefused},
		{"undeclared xkey", map[string]any{"id": id}, []any{map[string]any{"xkey": "nope", "value": "x"}}, codeInvalidArgument},
		{"leaf of a string property", map[string]any{"id": id}, []any{map[string]any{"xkey": "doc", "leaf": "a", "value": "x"}}, codeInvalidArgument},
		{"leaf with a dot", map[string]any{"id": id}, []any{map[string]any{"xkey": "vecs", "leaf": "a.b", "value": "x"}}, codeInvalidArgument},
		{"leaf with a star", map[string]any{"id": id}, []any{map[string]any{"xkey": "vecs", "leaf": "*", "value": "x"}}, codeInvalidArgument},
		{"two targets", map[string]any{"id": id, "create": map[string]any{"type": ids.doc}}, []any{}, codeInvalidArgument},
		{"no target", map[string]any{}, []any{}, codeInvalidArgument},
		{"unknown id", map[string]any{"id": "bafyreinosuchobject"}, []any{map[string]any{"xkey": "doc", "value": "x"}}, codeNotFound},
		{"type without definitions", map[string]any{"create": map[string]any{"type": "bafyreinosuchtype"}}, []any{map[string]any{"xkey": "doc", "value": "x"}}, codeNotFound},
		{"missing value", map[string]any{"id": id}, []any{map[string]any{"xkey": "doc"}}, codeInvalidArgument},
	}
	for _, c := range cases {
		if _, err := patch(a, sid, c.target, c.ops); codeOf(err) != c.code {
			t.Errorf("%s: code %d (%v), want %d", c.name, codeOf(err), err, c.code)
		}
	}
	if after := countType(t, a, sid, ids.doc); after != before {
		t.Fatalf("failed creates left objects: %d -> %d", before, after)
	}

	// Derive: the manifest, then an update of it.
	seed := map[string]any{"derive": map[string]any{"seed": "flutter_edge_ai.rag/manifest/main", "type": ids.loc}}
	m1, err := patch(a, sid, seed, []any{map[string]any{"xkey": "core", "value": `{"fmt":1,"documents":"text"}`}, map[string]any{"xkey": "textSearch", "value": true}})
	if err != nil {
		t.Fatal(err)
	}
	m2, err := patch(a, sid, seed, []any{map[string]any{"xkey": "fields", "leaf": "aa-string", "value": map[string]any{"fmt": 1}}})
	if err != nil {
		t.Fatal(err)
	}
	if m1["id"] != m2["id"] || m1["created"] != true || m2["created"] != false {
		t.Fatalf("derive: %v then %v", m1, m2)
	}
	// Delete: derived refused, created ok twice, then DELETED on writes.
	if err := a.objectDelete(sid, m1["id"].(string)); codeOf(err) != codeRefused {
		t.Fatalf("delete derived: %v", err)
	}
	if err := a.objectDelete(sid, id); err != nil {
		t.Fatal(err)
	}
	if err := a.objectDelete(sid, id); err != nil {
		t.Fatalf("second delete: %v", err)
	}
	if _, err := patch(a, sid, map[string]any{"id": id}, []any{map[string]any{"xkey": "doc", "value": "x"}}); codeOf(err) != codeDeleted {
		t.Fatalf("patch of a deleted object: %v", err)
	}
	if err := a.objectDelete(sid, "bafyreinosuchobject"); codeOf(err) != codeNotFound {
		t.Fatalf("delete unknown: %v", err)
	}
}

// A create whose values did not all land is deleted again, and the call
// fails: the check is the same one that runs after every create.
func TestObjectPatchHalfMadeCreateIsDeleted(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "half")
	ids := mustRagBundles(t, a, sid, true)
	// What a create looks like to the check when the apply layer dropped
	// one value: the op names a property the row does not carry.
	sp, _ := a.space(sid)
	id, err := sp.Objects().Create(a.ctx, space.CreateObjectOpts{Type: ids.doc,
		InitialProperties: map[string]map[string]any{ids.doc: {ids.docProp: "x"}}})
	if err != nil {
		t.Fatal(err)
	}
	err = checkLanded(a.ctx, sp, id, ids.doc, []resolvedOp{{propId: ids.docProp, xkey: "doc"}, {propId: ids.vecs, leaf: "h", xkey: "vecs"}})
	if codeOf(err) != codeRefused || !strings.Contains(err.Error(), "vecs") {
		t.Fatalf("checkLanded: %v", err)
	}
	// And the patch path deletes such an object: hook the check.
	orig := checkLandedHook
	checkLandedHook = func(ctx context.Context, sp space.Space, id, typeId string, ops []resolvedOp) error {
		return withCode(codeRefused, "simulated rejection")
	}
	defer func() { checkLandedHook = orig }()
	before := countType(t, a, sid, ids.doc)
	if _, err := patch(a, sid, map[string]any{"create": map[string]any{"type": ids.doc}}, []any{map[string]any{"xkey": "doc", "value": "y"}}); codeOf(err) != codeRefused {
		t.Fatalf("half-made create: %v", err)
	}
	if after := countType(t, a, sid, ids.doc); after != before {
		t.Fatalf("the half-made object was not deleted: %d -> %d", before, after)
	}
}

// Rejections in a ModifyResult mean the change committed and the op did
// not: never OK.
func TestRejectionsAreNotOK(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "rej")
	ids := mustRagBundles(t, a, sid, true)
	r, err := patch(a, sid, map[string]any{"create": map[string]any{"type": ids.doc}}, []any{map[string]any{"xkey": "doc", "value": "d"}})
	if err != nil {
		t.Fatal(err)
	}
	id := r["id"].(string)
	sp, _ := a.space(sid)
	if err := setBody(a.ctx, sp, id, "one line"); err != nil {
		t.Fatal(err)
	}
	blocks, _ := sp.Query(id, editor.Dataset).All(a.ctx)
	if len(blocks) != 1 {
		t.Fatalf("%d blocks", len(blocks))
	}
	bid := string(blocks[0].GetStringBytes("id"))
	// The editor handler drops a $set of a path it does not allow.
	err = a.recordsModify(sid, id, editor.Dataset, `[{"id":"`+bid+`","set":{"bogus":1}}]`)
	if codeOf(err) != codeRefused || !strings.Contains(err.Error(), "rejected") {
		t.Fatalf("rejected op: code %d (%v), want REFUSED", codeOf(err), err)
	}
	if rejectionsErr([]space.OpRejection{{RecordId: "r", ReasonErr: space.ErrRecordDeleted, Reason: "deleted"}}) == nil ||
		codeOf(rejectionsErr([]space.OpRejection{{RecordId: "r", ReasonErr: space.ErrRecordDeleted}})) != codeDeleted {
		t.Fatal("a deleted-record rejection is not DELETED")
	}
}

func TestObjectSetBodyReadAndSyncState(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "read")
	ids := mustRagBundles(t, a, sid, true)
	var made []string
	for i := 0; i < 5; i++ {
		r, err := patch(a, sid, map[string]any{"create": map[string]any{"type": ids.doc}},
			[]any{map[string]any{"xkey": "doc", "value": `{"n":` + string(rune('0'+i)) + `}`}})
		if err != nil {
			t.Fatal(err)
		}
		made = append(made, r["id"].(string))
	}
	sp, _ := a.space(sid)
	if err := setBody(a.ctx, sp, made[0], "line one\n\n line two\r\n"); err != nil {
		t.Fatalf("set body on the document type: %v", err)
	}
	blocks, _ := sp.Query(made[0], editor.Dataset).Sort(editor.FieldNav + "." + editor.NavPos).All(a.ctx)
	if len(blocks) != 2 || string(blocks[1].GetStringBytes("text")) != " line two" {
		t.Fatalf("body blocks: %v", blocks)
	}
	if err := setBody(a.ctx, sp, made[0], "replaced"); err != nil {
		t.Fatal(err)
	}
	if blocks, _ := sp.Query(made[0], editor.Dataset).All(a.ctx); len(blocks) != 1 {
		t.Fatalf("body not replaced: %d blocks", len(blocks))
	}

	// A type page, ordered by id, in pages of 2.
	var seen []string
	after := ""
	for {
		req, _ := json.Marshal(map[string]any{"type": ids.doc, "after": after, "limit": 2, "xkeys": []string{"doc", "vecs", "nope"}})
		r, err := a.objectRead(sid, string(req))
		if err != nil {
			t.Fatal(err)
		}
		anchor := r["anchor"].(map[string]any)
		if anchor["generation"] == "" || anchor["maxApplySeq"].(uint64) == 0 {
			t.Fatalf("anchor = %v", anchor)
		}
		for _, it := range r["items"].([]map[string]any) {
			seen = append(seen, it["id"].(string))
			p := it["props"].(map[string]any)
			if p["doc"] == nil || it["state"] != "ok" || it["typeId"] != ids.doc {
				t.Fatalf("item %v", it)
			}
			if _, ok := p["nope"]; !ok || p["nope"] != nil {
				t.Fatalf("undeclared xkey: %v", p)
			}
		}
		if r["next"] == nil {
			break
		}
		after = r["next"].(string)
	}
	if len(seen) != 5 {
		t.Fatalf("paged %d items: %v", len(seen), seen)
	}
	for i := 1; i < len(seen); i++ {
		if seen[i-1] >= seen[i] {
			t.Fatalf("not in id order: %v", seen)
		}
	}
	// By ids: ok, deleted, missing.
	if err := a.objectDelete(sid, made[1]); err != nil {
		t.Fatal(err)
	}
	req, _ := json.Marshal(map[string]any{"ids": []string{made[0], made[1], "bafyreinosuchobject"}, "xkeys": []string{"doc"}})
	r, err := a.objectRead(sid, string(req))
	if err != nil {
		t.Fatal(err)
	}
	items := r["items"].([]map[string]any)
	if items[0]["state"] != "ok" || items[1]["state"] != "deleted" || items[2]["state"] != "missing" || r["next"] != nil {
		t.Fatalf("by ids: %v", items)
	}
	for _, bad := range []string{`{}`, `{"ids":[],"type":"x"}`, `{"ids":["a"],"limit":2}`, `{"type":"x","limit":5000}`, `{"ids":[""]}`} {
		if _, err := a.objectRead(sid, bad); codeOf(err) != codeInvalidArgument {
			t.Errorf("%s: %v", bad, err)
		}
	}
	st, err := a.objectSyncState(sid, made[0])
	if err != nil {
		t.Fatal(err)
	}
	switch st["state"] {
	case "syncing", "synced", "offline", "unknown", "error":
	default:
		t.Fatalf("sync state %v", st)
	}
}

// The tombstone dataset: records merge with $addToSet, the key stays
// writable by every remove, deletes are refused.
func TestTombstoneRecords(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "tomb")
	ids := mustRagBundles(t, a, sid, true)
	m, err := patch(a, sid, map[string]any{"derive": map[string]any{"seed": "flutter_edge_ai.rag/manifest/x", "type": ids.loc}}, []any{})
	if err != nil {
		t.Fatal(err)
	}
	man := m["id"].(string)
	k1 := strings.Repeat("a", 64)
	k2 := strings.Repeat("b", 64)
	rec := func(id string, rev int) string {
		return `[{"id":"` + id + `","set":{"key":"doc-` + id[:1] + `"},"addToSet":{"revs":` + string(rune('0'+rev)) + `}}]`
	}
	if err := a.recordsModify(sid, man, ids.tombstones, rec(k1, 1)); err != nil {
		t.Fatal(err)
	}
	// The second remove of the key: key is set again (mutable by anyone).
	if err := a.recordsModify(sid, man, ids.tombstones, rec(k1, 2)); err != nil {
		t.Fatalf("second remove of a key: %v", err)
	}
	if err := a.recordsModify(sid, man, ids.tombstones, `[{"id":"clear","addToSet":{"revs":7}},{"id":"`+k2+`","set":{"key":"doc-b"},"addToSet":{"revs":3}}]`); err != nil {
		t.Fatal(err)
	}
	r, err := a.recordsRead(sid, man, ids.tombstones, "", 0, 2)
	if err != nil {
		t.Fatal(err)
	}
	recs := r["records"].([]map[string]any)
	if len(recs) != 2 || recs[0]["id"] != k1 || r["next"] != k2 {
		t.Fatalf("page 1: %v", r)
	}
	revs := recs[0]["revs"].([]any)
	if len(revs) != 2 || recs[0]["key"] != "doc-a" {
		t.Fatalf("merged record: %v", recs[0])
	}
	seq, ok := recs[0]["_applySeq"].(float64)
	if !ok || seq == 0 {
		t.Fatalf("no _applySeq: %v", recs[0])
	}
	for k := range recs[0] {
		if strings.HasPrefix(k, "_") && k != "_applySeq" {
			t.Fatalf("bookkeeping field %q in %v", k, recs[0])
		}
	}
	r, _ = a.recordsRead(sid, man, ids.tombstones, k2, 0, 0)
	if recs := r["records"].([]map[string]any); len(recs) != 1 || recs[0]["id"] != "clear" || r["next"] != nil {
		t.Fatalf("after %s: %v", k2, r)
	}
	// k1's last write is seq; k2 and clear came in one later change.
	r, _ = a.recordsRead(sid, man, ids.tombstones, "", uint64(seq), 0)
	if recs := r["records"].([]map[string]any); len(recs) != 2 || recs[0]["id"] != k2 {
		t.Fatalf("since %v: %v", seq, r)
	}
	// Frozen rules: no delete; ids are sha256 hex or "clear".
	sp, _ := a.space(sid)
	if _, err := sp.Delete(a.ctx, space.DeleteBatch{ObjectId: man, Dataset: ids.tombstones, RecordIds: []string{k1}}); !errors.Is(err, space.ErrDatasetUndeletable) {
		t.Fatalf("delete of a tombstone: %v", err)
	}
	if err := a.recordsModify(sid, man, ids.tombstones, `[{"id":"Not-A-Hash","set":{"key":"x"}}]`); err == nil {
		t.Fatal("a record id outside the pattern was accepted")
	}
	for _, bad := range []string{`[]`, `[{"id":"","set":{"key":"x"}}]`, `[{"id":"clear"}]`, `[{"id":"clear","set":{"_x":1}}]`, `{`} {
		if err := a.recordsModify(sid, man, ids.tombstones, bad); codeOf(err) != codeInvalidArgument {
			t.Errorf("%s: %v", bad, err)
		}
	}
}

func TestChangesWatchFilesOffline(t *testing.T) {
	a := openOffline(t)
	sid := mustCreateSpace(t, a, "files")
	ids := mustRagBundles(t, a, sid, true)
	w, err := a.watchChanges(sid)
	if err != nil {
		t.Fatal(err)
	}
	r, err := patch(a, sid, map[string]any{"create": map[string]any{"type": ids.doc}}, []any{map[string]any{"xkey": "doc", "value": "d"}})
	if err != nil {
		t.Fatal(err)
	}
	id := r["id"].(string)
	deadline := time.Now().Add(5 * time.Second)
	seen := false
	for !seen && time.Now().Before(deadline) {
		evs, err := a.events.poll(0, maxWait)
		if err != nil {
			t.Fatal(err)
		}
		for _, ev := range evs {
			if ev["kind"] == "change" && ev["objectId"] == id && ev["watch"] == w {
				seen = true
			}
		}
	}
	if !seen {
		t.Fatal("no change event for the new object")
	}
	if err := a.unwatch(w); err != nil {
		t.Fatal(err)
	}
	if err := a.unwatch(w); codeOf(err) != codeNotFound {
		t.Fatalf("second unwatch: %v", err)
	}
	feed, err := a.changesSince(sid, 0, 0)
	if err != nil || len(feed["changes"].([]map[string]any)) == 0 {
		t.Fatalf("feed: %v %v", feed, err)
	}

	src := filepath.Join(t.TempDir(), "blob.bin")
	payload := []byte(strings.Repeat("any-sync file payload ", 10000))
	if err := os.WriteFile(src, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	fi, err := a.fileAttach(sid, id, src, "")
	if err != nil {
		t.Fatal(err)
	}
	if l, err := a.fileList(sid, id); err != nil || len(l) != 1 {
		t.Fatalf("list: %v %v", l, err)
	}
	sp, _ := a.space(sid)
	dst := filepath.Join(t.TempDir(), "out.bin")
	h := a.startOp(func(ctx context.Context) (any, error) {
		n, err := fileRead(ctx, sp, fi.FileId, dst, 10*time.Second)
		return map[string]any{"bytes": n}, err
	})
	res, err := waitOpDone(t, h, 15*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	back, _ := os.ReadFile(dst)
	if res.(map[string]any)["bytes"] != int64(len(payload)) || string(back) != string(payload) {
		t.Fatalf("read back %v", res)
	}
	if _, err := a.fileStatus(sid, fi.FileId); err != nil {
		t.Fatal(err)
	}
}

func TestEventsCarryLastSyncedAt(t *testing.T) {
	ev := spaceStatusJSON(space.SpaceSyncStatus{SpaceId: "s"})
	if v, ok := ev["lastSyncedAt"]; !ok || v != nil {
		t.Fatalf("zero LastSyncedAt: %v", ev)
	}
	now := time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)
	if ev := spaceStatusJSON(space.SpaceSyncStatus{LastSyncedAt: now}); ev["lastSyncedAt"] != "2026-11-20T10:00:00Z" {
		t.Fatalf("lastSyncedAt = %v", ev["lastSyncedAt"])
	}
}
