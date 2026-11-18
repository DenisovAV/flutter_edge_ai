package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anyproto/any-sync-sdk/auth"
	"github.com/anyproto/any-sync-sdk/space"
)

func deadNodeConf(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("testdata/nodeconf-dead.yml")
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// openOffline opens a fresh test account with p2p off: no network at all.
func openOffline(t *testing.T) *account {
	t.Helper()
	m, err := auth.GenerateMnemonic()
	if err != nil {
		t.Fatal(err)
	}
	dev, err := auth.GenerateDeviceKey(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	opts, _ := json.Marshal(map[string]any{
		"dataDir": t.TempDir(), "mnemonic": m, "deviceKeyHex": hex.EncodeToString(dev),
		"nodeConfYaml": deadNodeConf(t), "p2p": map[string]any{"enabled": false},
	})
	a, err := openAccount(string(opts))
	if err != nil {
		t.Fatalf("openAccount: %v", err)
	}
	t.Cleanup(func() { _ = a.close() })
	return a
}

func TestOpenRefusesBadOptions(t *testing.T) {
	nc := deadNodeConf(t)
	prod := strings.Replace(nc, "N4N1wDHFpFpovXBqdbq2TDXE9tXdXbtV1eTJFpKJW4YeaJqR", "N83gJpVd9MuNRZAuJLZ7LiMntTThhPc6DtzWWVjb1M3PouVU", 1)
	base := map[string]any{"dataDir": t.TempDir(), "mnemonic": "x", "deviceKeyHex": "00", "nodeConfYaml": nc}
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
}

func TestDocumentLifecycleOffline(t *testing.T) {
	a := openOffline(t)
	sp, err := a.sdk.Spaces().Create(a.ctx, space.CreateRequest{Name: "notes"})
	if err != nil {
		t.Fatal(err)
	}
	sid := sp.Id()
	list, err := a.spaceList(false)
	if err != nil || len(list) == 0 {
		t.Fatalf("space list: %v %v", list, err)
	}

	r, err := a.objectPut(sid, docIn{Name: "Titan", Text: "methane lakes\n\nnitrogen air", Meta: json.RawMessage(`{"cat":"space","n":1}`)})
	if err != nil {
		t.Fatal(err)
	}
	id := r["id"].(string)
	if r["created"] != true {
		t.Fatalf("first put: %v", r)
	}
	got, err := a.objectGet(sid, id)
	if err != nil {
		t.Fatal(err)
	}
	if got["isDocument"] != true || got["name"] != "Titan" || got["text"] != "methane lakes\nnitrogen air" || got["meta"] != `{"cat":"space","n":1}` {
		t.Fatalf("get = %v", got)
	}

	// Update by id replaces the body.
	if _, err := a.objectPut(sid, docIn{Id: id, Name: "Titan", Text: "one line"}); err != nil {
		t.Fatal(err)
	}
	if got, _ := a.objectGet(sid, id); got["text"] != "one line" || got["meta"] != nil {
		t.Fatalf("after update: %v", got)
	}

	// A seed derives the same id each time; the second put is an update.
	r1, err := a.objectPut(sid, docIn{Seed: "doc-42", Name: "Seeded", Text: "v1"})
	if err != nil {
		t.Fatal(err)
	}
	r2, err := a.objectPut(sid, docIn{Seed: "doc-42", Name: "Seeded", Text: "v2"})
	if err != nil {
		t.Fatal(err)
	}
	if r1["id"] != r2["id"] || r1["created"] != true || r2["created"] != false {
		t.Fatalf("seeded puts: %v then %v", r1, r2)
	}
	if got, _ := a.objectGet(sid, r2["id"].(string)); got["text"] != "v2" {
		t.Fatalf("seeded get: %v", got)
	}

	if _, err := a.objectPut(sid, docIn{Id: id, Seed: "x"}); codeOf(err) != codeInvalidArgument {
		t.Fatalf("id and seed: %v", err)
	}
	if _, err := a.objectPut(sid, docIn{Name: "x", Meta: json.RawMessage(`[1]`)}); codeOf(err) != codeInvalidArgument {
		t.Fatalf("array meta: %v", err)
	}

	rows, err := a.objectQuery(sid, "", 0)
	if err != nil || len(rows) < 2 {
		t.Fatalf("query: %d rows, %v", len(rows), err)
	}

	feed, err := a.changesSince(sid, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(feed["changes"].([]map[string]any)) == 0 || feed["generation"] == "" {
		t.Fatalf("feed: %v", feed)
	}

	spc, _ := a.space(sid)
	if err := spc.Objects().Delete(a.ctx, r2["id"].(string)); codeOf(err) != codeRefused {
		t.Fatalf("delete a seeded object: code %d (%v), want refused", codeOf(err), err)
	}
	if err := spc.Objects().Delete(a.ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := a.objectGet(sid, id); codeOf(err) != codeDeleted && codeOf(err) != codeNotFound {
		t.Fatalf("get after delete: code %d (%v)", codeOf(err), err)
	}
	if _, err := a.objectGet(sid, "bafyreinotanobjectid"); codeOf(err) != codeNotFound && codeOf(err) != codeInvalidArgument {
		t.Fatalf("get unknown: code %d (%v)", codeOf(err), err)
	}
}

func TestWatchAndFilesOffline(t *testing.T) {
	a := openOffline(t)
	sp, err := a.sdk.Spaces().Create(a.ctx, space.CreateRequest{Name: "files"})
	if err != nil {
		t.Fatal(err)
	}
	sid := sp.Id()
	w, err := a.watchChanges(sid)
	if err != nil {
		t.Fatal(err)
	}
	r, err := a.objectPut(sid, docIn{Name: "with file", Text: "see attachment"})
	if err != nil {
		t.Fatal(err)
	}
	id := r["id"].(string)
	deadline := time.Now().Add(5 * time.Second)
	seen := false
	for !seen && time.Now().Before(deadline) {
		evs, err := a.events.poll(0, 500*time.Millisecond)
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

	src := filepath.Join(t.TempDir(), "blob.bin")
	payload := []byte(strings.Repeat("any-sync file payload ", 10000))
	if err := os.WriteFile(src, payload, 0o600); err != nil {
		t.Fatal(err)
	}
	fi, err := a.fileAttach(sid, id, src, "")
	if err != nil {
		t.Fatal(err)
	}
	if fi.Name != "blob.bin" || fi.Size != int64(len(payload)) {
		t.Fatalf("attach: %+v", fi)
	}
	l, err := a.fileList(sid, id)
	if err != nil || len(l) != 1 {
		t.Fatalf("list: %v %v", l, err)
	}
	dst := filepath.Join(t.TempDir(), "out.bin")
	n, err := a.fileRead(sid, fi.FileId, dst, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	back, _ := os.ReadFile(dst)
	if n != int64(len(payload)) || string(back) != string(payload) {
		t.Fatalf("read back %d bytes, want %d identical", n, len(payload))
	}
	// Again onto the same path: the rename replaces the file (on Windows
	// too: Go renames with MOVEFILE_REPLACE_EXISTING).
	if n, err := a.fileRead(sid, fi.FileId, dst, 10*time.Second); err != nil || n != int64(len(payload)) {
		t.Fatalf("second read onto %s: %d bytes, %v", dst, n, err)
	}
	if _, err := a.fileStatus(sid, fi.FileId); err != nil {
		t.Fatal(err)
	}
}

func TestCloseEndsCallsAndPollers(t *testing.T) {
	a := openOffline(t)
	h := handles.add(a)
	done := make(chan error)
	go func() {
		_, err := a.events.poll(0, 30*time.Second)
		done <- err
	}()
	time.Sleep(50 * time.Millisecond)
	handles.remove(h)
	if err := a.close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if codeOf(err) != codeClosed {
			t.Fatalf("poller: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("close did not wake the poller")
	}
	if _, err := a.enter(); codeOf(err) != codeClosed {
		t.Fatalf("enter after close: %v", err)
	}
	if _, err := lookup[*account](h, "an account"); codeOf(err) != codeClosed {
		t.Fatalf("lookup after close: %v", err)
	}
	if err := a.close(); codeOf(err) != codeClosed {
		t.Fatalf("second close: %v", err)
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

func TestSpaceStatusAndListOffline(t *testing.T) {
	a := openOffline(t)
	sp, err := a.sdk.Spaces().Create(a.ctx, space.CreateRequest{Name: "s"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.spaceStatus(sp.Id()); err != nil {
		t.Fatalf("known space: %v", err)
	}
	if _, err := a.spaceStatus("bafyreinosuchspace.abc"); codeOf(err) != codeNotFound {
		t.Fatalf("unknown space: code %d (%v)", codeOf(err), err)
	}
	l, err := a.spaceList(true)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := l["syncError"]; !ok || len(l["spaces"].([]map[string]any)) == 0 {
		t.Fatalf("list: %v", l)
	}
}

// A document type left without its properties (its creator stopped
// halfway) is completed by the next put, not waited on forever.
func TestIncompleteDocTypeIsCompleted(t *testing.T) {
	a := openOffline(t)
	sp, err := a.sdk.Spaces().Create(a.ctx, space.CreateRequest{Name: "half"})
	if err != nil {
		t.Fatal(err)
	}
	half, err := sp.Types().Create(a.ctx, space.TypeCreateParams{Name: docTypeName, XKey: docTypeXKey})
	if err != nil {
		t.Fatal(err)
	}
	r, err := a.objectPut(sp.Id(), docIn{Name: "after a crash", Text: "body", Meta: json.RawMessage(`{"k":1}`)})
	if err != nil {
		t.Fatalf("put over a half-created type: %v", err)
	}
	got, err := a.objectGet(sp.Id(), r["id"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if got["type"] != half || got["meta"] != `{"k":1}` || got["text"] != "body" {
		t.Fatalf("got %v, want a document of the completed type %s", got, half)
	}
	types, _ := sp.Types().List(a.ctx)
	n := 0
	for _, ti := range types {
		if ti.XKey == docTypeXKey {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("%d document types, want the one completed", n)
	}
}
