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
	"io"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/anyproto/any-sync/app/logger"
	"gopkg.in/yaml.v3"

	anysyncsdk "github.com/anyproto/any-sync-sdk"
	"github.com/anyproto/any-sync-sdk/auth"
	"github.com/anyproto/any-sync-sdk/config"
	"github.com/anyproto/any-sync-sdk/handler"
	"github.com/anyproto/any-sync-sdk/space"

	editor "anyshim/third_party/any_editor"
)

// refusedNetworkIds are networks this shim will not join. The production
// any-sync network (the one Anytype and `any` use by default) is here
// until its terms for third-party apps are known; anyproto/any pins the
// same id in internal/config/nodeconf_embed_test.go.
var refusedNetworkIds = map[string]string{
	"N83gJpVd9MuNRZAuJLZ7LiMntTThhPc6DtzWWVjb1M3PouVU": "the production any-sync network",
}

type p2pOpts struct {
	Enabled        *bool  `json:"enabled"`
	LocalDiscovery *bool  `json:"localDiscovery"`
	ServiceName    string `json:"serviceName"`
	Port           int    `json:"port"`
}

type openOpts struct {
	DataDir      string  `json:"dataDir"`
	IndexDir     string  `json:"indexDir"`
	OwnerToken   string  `json:"ownerToken"`
	Mnemonic     string  `json:"mnemonic"`
	AccountIndex *uint32 `json:"accountIndex"`
	DeviceKeyHex string  `json:"deviceKeyHex"`
	NodeConfYAML string  `json:"nodeConfYaml"`
	P2P          p2pOpts `json:"p2p"`
	LogLevel     string  `json:"logLevel"`
}

// account is one open SDK instance.
//
// Calls hold ops for reading while they run; the close takes it for
// writing after cancelling ctx, so the SDK is never closed under a call,
// and a call blocked on the network returns at once instead of holding
// the close. A call never waits for ops: once the close holds it, or is
// waiting for it, the call is ANY_SHIM_ERR_CLOSED.
type account struct {
	sdk    *anysyncsdk.SDK
	ctx    context.Context
	cancel context.CancelFunc
	events *eventQueue
	state  *accountState
	lock   *os.File
	claims []*dirClaim

	ops    sync.RWMutex
	closed atomic.Bool

	mu       sync.Mutex // watches, watchSeq
	watches  map[int64]func()
	watchSeq int64

	// Space loads, single-flight per space (spaces.go). loadsClosed is
	// set, under loadsMu, before the close waits for loadWG, so no load
	// starts after the wait began.
	loadsMu     sync.Mutex
	loads       map[string]*spaceLoad
	loadsClosed bool
	loadWG      sync.WaitGroup

	stopStatus func() // the account's own sync-status subscription

	opHandles map[uint64]struct{} // ops started on this account (a.mu)

	closeOnce sync.Once
	closeDone chan struct{}
	closeErr  error
	bgEnd     func()
}

var loggerOnce sync.Once

func decodeStrict(s string, v any) error {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return invalid("options: %v", err)
	}
	if dec.More() {
		return invalid("options: trailing data after the JSON value")
	}
	if _, err := dec.Token(); err != io.EOF {
		return invalid("options: trailing data after the JSON value")
	}
	return nil
}

func checkNetwork(nodeConf string) error {
	if strings.TrimSpace(nodeConf) == "" {
		return invalid("nodeConfYaml is required: there is no default network")
	}
	var nc struct {
		NetworkId string `yaml:"networkId"`
	}
	if err := yaml.Unmarshal([]byte(nodeConf), &nc); err != nil {
		return invalid("nodeConfYaml: %v", err)
	}
	if nc.NetworkId == "" {
		return invalid("nodeConfYaml has no networkId")
	}
	if what, ok := refusedNetworkIds[nc.NetworkId]; ok {
		return withCode(codeRefused, "nodeConfYaml names %s (%s), which this build refuses to join", what, nc.NetworkId)
	}
	return nil
}

// ------------------------------------------------------- directory claims

// dirClaim is one directory (an account's data or index directory, or a
// local index file) held by an open handle in this process. A claim of
// another owner token, or one still closing, is ANY_SHIM_ERR_BUSY: after
// a Dart hot restart the previous isolate group's handles are released
// by their finalizers and close on a goroutine; the new group retries
// until they are gone.
type dirClaim struct {
	key     string
	token   string
	holder  string // what holds it, for messages
	closing atomic.Bool
}

var claims = struct {
	sync.Mutex
	m map[string]*dirClaim
}{m: map[string]*dirClaim{}}

// canonicalDir creates dir if needed and returns its absolute path with
// symlinks resolved, so two spellings of one directory are one claim.
func canonicalDir(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(abs)
}

// claim takes every key for token, or none.
func claim(token, holder string, keys ...string) ([]*dirClaim, error) {
	claims.Lock()
	defer claims.Unlock()
	for _, k := range keys {
		c, ok := claims.m[k]
		if !ok {
			continue
		}
		what := strings.SplitN(k, ":", 2)
		switch {
		case c.closing.Load():
			return nil, withCode(codeBusy, "%s %s is still closing (held by %s); retry", what[0], what[1], c.holder)
		case c.token != token:
			return nil, withCode(codeBusy, "%s %s is held by another owner (%s), e.g. the previous generation of a hot restart; retry", what[0], what[1], c.holder)
		default:
			return nil, withCode(codeRefused, "%s %s is already open in this isolate group (%s)", what[0], what[1], c.holder)
		}
	}
	out := make([]*dirClaim, 0, len(keys))
	for _, k := range keys {
		c := &dirClaim{key: k, token: token, holder: holder}
		claims.m[k] = c
		out = append(out, c)
	}
	return out, nil
}

func markClosing(cs []*dirClaim) {
	for _, c := range cs {
		c.closing.Store(true)
	}
}

func unclaim(cs []*dirClaim) {
	claims.Lock()
	defer claims.Unlock()
	for _, c := range cs {
		if claims.m[c.key] == c {
			delete(claims.m, c.key)
		}
	}
}

// ------------------------------------------------------------------ open

// dataDirLockName is the shim's own lock file in dataDir. Not ".lock":
// that suffix is any-store's sentinel file name.
const dataDirLockName = ".shimlock"

// pendingAccount is an account whose directories are claimed and locked
// (synchronously, in the start call) and whose SDK is not open yet.
type pendingAccount struct {
	o       openOpts
	dev     []byte
	dataDir string
	claims  []*dirClaim
	lock    *os.File
	state   *accountState
}

func (p *pendingAccount) release() {
	_ = unlockFile(p.lock)
	unclaim(p.claims)
}

// prepareAccount validates the options, claims both directories and takes
// the data directory's lock. BUSY and REFUSED come from here.
func prepareAccount(optsJSON string) (_ *pendingAccount, err error) {
	var o openOpts
	if err := decodeStrict(optsJSON, &o); err != nil {
		return nil, err
	}
	switch {
	case o.DataDir == "":
		return nil, invalid("dataDir is required")
	case o.IndexDir == "":
		return nil, invalid("indexDir is required")
	case o.OwnerToken == "":
		return nil, invalid("ownerToken is required")
	case o.Mnemonic == "":
		return nil, invalid("mnemonic is required")
	}
	if err := checkNetwork(o.NodeConfYAML); err != nil {
		return nil, err
	}
	dev, err := hex.DecodeString(o.DeviceKeyHex)
	if err != nil || len(dev) == 0 {
		return nil, invalid("deviceKeyHex must be the hex of a device key (any_shim_new_device_key)")
	}
	switch o.LogLevel {
	case "", "debug", "info", "warn", "error":
	default:
		return nil, invalid("logLevel %q: expected debug, info, warn or error", o.LogLevel)
	}
	dataDir, err := canonicalDir(o.DataDir)
	if err != nil {
		return nil, ioOr(err, codeInternal, "dataDir")
	}
	indexDir, err := canonicalDir(o.IndexDir)
	if err != nil {
		return nil, ioOr(err, codeInternal, "indexDir")
	}
	if dataDir == indexDir {
		return nil, invalid("dataDir and indexDir must differ")
	}
	cl, err := claim(o.OwnerToken, "the account in "+dataDir, "dataDir:"+dataDir, "indexDir:"+indexDir)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			unclaim(cl)
		}
	}()
	lock, err := lockFile(filepath.Join(dataDir, dataDirLockName))
	if err != nil {
		if codeOf(err) == codeBusy {
			return nil, err
		}
		return nil, ioOr(err, codeInternal, "lock %s", dataDir)
	}
	defer func() {
		if err != nil {
			_ = unlockFile(lock)
		}
	}()
	st, err := loadAccountState(dataDir)
	if err != nil {
		return nil, err
	}
	return &pendingAccount{o: o, dev: dev, dataDir: dataDir, claims: cl, lock: lock, state: st}, nil
}

// open opens the SDK. Cancelling opCtx cancels the open; an account that
// opened anyway is closed again. On any failure the claims and the lock
// are released.
func (p *pendingAccount) open(opCtx context.Context) (_ *account, err error) {
	defer func() {
		if err != nil {
			p.release()
		}
	}()
	o := p.o
	loggerOnce.Do(func() {
		lvl := o.LogLevel
		if lvl == "" {
			lvl = "error"
		}
		logger.Config{DefaultLevel: lvl}.ApplyGlobal()
	})
	idx := auth.DefaultAccountIndex
	if o.AccountIndex != nil {
		idx = *o.AccountIndex
	}
	prov, err := auth.NewMnemonicProvider(auth.MnemonicConfig{Mnemonic: o.Mnemonic, Index: idx, DeviceKey: p.dev})
	if err != nil {
		return nil, invalid("account: %v", err)
	}
	off := false
	cfg := config.Config{
		Storage: config.Storage{DataDir: p.dataDir, Topology: config.StorageShared},
		Network: config.Network{NodeConfYAML: []byte(o.NodeConfYAML)},
		P2P: config.P2P{
			Enabled:        o.P2P.Enabled,
			LocalDiscovery: o.P2P.LocalDiscovery,
			ServiceName:    o.P2P.ServiceName,
			Port:           o.P2P.Port,
			// Internet-wide p2p goes through relays; none is ours.
			Global: config.GlobalP2P{Enabled: &off},
		},
		// The editor module `any` registers, so `any` renders the
		// bodies we write and we read the ones it writes.
		Modules: []handler.Module{editor.NewModule()},
	}
	// The account's context outlives the op; the op's cancel reaches the
	// open only while it runs.
	ctx, cancel := context.WithCancel(context.Background())
	stop := context.AfterFunc(opCtx, cancel)
	s, err := anysyncsdk.Open(ctx, cfg, prov)
	cancelledByOp := !stop()
	if err != nil {
		cancel()
		if cancelledByOp {
			return nil, opCtx.Err()
		}
		return nil, err
	}
	if cancelledByOp {
		cancel()
		_ = s.Close()
		return nil, opCtx.Err()
	}
	a := &account{
		sdk:       s,
		ctx:       ctx,
		cancel:    cancel,
		events:    newEventQueue(defaultQueueCapacity),
		state:     p.state,
		lock:      p.lock,
		claims:    p.claims,
		watches:   map[int64]func(){},
		loads:     map[string]*spaceLoad{},
		opHandles: map[uint64]struct{}{},
		closeDone: make(chan struct{}),
	}
	// everPeerSynced is set without a caller: the first non-zero
	// LastSyncedAt of a space, seen on the account-wide status feed.
	a.stopStatus = s.Spaces().SubscribeStatus(func(st space.SpaceSyncStatus) {
		if !st.LastSyncedAt.IsZero() {
			_ = a.markPeerSynced(st.SpaceId, false)
		}
	})
	return a, nil
}

// openAccount prepares and opens on the calling goroutine (tests).
func openAccount(optsJSON string) (*account, error) {
	p, err := prepareAccount(optsJSON)
	if err != nil {
		return nil, err
	}
	return p.open(context.Background())
}

// markPeerSynced sets everPeerSynced. sync=true saves before returning
// and reports a failed save; sync=false saves on a goroutine and a
// failure shows up as stateSaveError.
func (a *account) markPeerSynced(spaceId string, sync bool) error {
	if spaceId == "" {
		return nil
	}
	return a.state.update(spaceId, sync, func(st *spaceState) { st.EverPeerSynced = true })
}

// enter marks a call in progress; the returned func ends it. It never
// waits: an account that is closing (or cancelled) is ANY_SHIM_ERR_CLOSED.
func (a *account) enter() (func(), error) {
	if a.closed.Load() || a.ctx.Err() != nil {
		return nil, errClosed
	}
	if !a.ops.TryRLock() {
		// Only the close takes ops for writing.
		return nil, errClosed
	}
	if a.closed.Load() || a.ctx.Err() != nil {
		a.ops.RUnlock()
		return nil, errClosed
	}
	return a.ops.RUnlock, nil
}

// cancelCalls cancels every call and space load in flight. Never blocks.
func (a *account) cancelCalls() {
	a.cancel()
}

// beginClose does the synchronous part of a close: the handle is
// already out of the registry; calls are refused (CLOSED), the
// directories read as closing (a new open is ANY_SHIM_ERR_BUSY) and the
// iOS background task begins. cancelNow also cancels calls and loads and
// wakes pollers (a close that waits for loads cancels later, in
// finishClose). Never blocks. Reports false when the close had begun
// already.
func (a *account) beginClose(cancelNow bool) bool {
	if a.closed.Swap(true) {
		return false
	}
	a.bgEnd = beginBackgroundTask("flutter_edge_ai_any account close")
	markClosing(a.claims)
	if cancelNow {
		a.cancel()
		a.events.close()
	}
	return true
}

// finishClose optionally waits up to waitLoads for space loads in flight
// (a suspend lets a joining device finish its first load), then cancels,
// waits for the calls in flight, stops watches, ops and loads, closes the
// SDK and releases the lock and the directories. The release runs
// whatever happens before it, a failed or panicking SDK close included.
// Runs once; later callers wait for the first and get its result.
func (a *account) finishClose(waitLoads time.Duration) error {
	a.closeOnce.Do(func() {
		defer close(a.closeDone)
		var errs []error
		defer func() { a.closeErr = errors.Join(errs...) }()
		// First registered, so it runs last: the lock and the claims go
		// even when anything below panics.
		defer func() {
			errs = append(errs, unlockFile(a.lock))
			unclaim(a.claims)
		}()
		defer func() {
			if a.bgEnd != nil {
				a.bgEnd()
			}
		}()
		defer func() {
			if r := recover(); r != nil {
				errs = append(errs, &shimError{code: codePanic, err: fmt.Errorf("panic while closing: %v\n%s", r, debug.Stack())})
			}
		}()
		a.loadsMu.Lock()
		a.loadsClosed = true // no load starts from here on
		a.loadsMu.Unlock()
		loadsDone := make(chan struct{})
		go func() { a.loadWG.Wait(); close(loadsDone) }()
		if waitLoads > 0 {
			t := time.NewTimer(waitLoads)
			select {
			case <-loadsDone:
			case <-t.C:
			}
			t.Stop()
		}
		a.cancel()
		a.events.close()
		a.dropOps()
		a.ops.Lock()
		defer a.ops.Unlock()
		a.mu.Lock()
		for _, stop := range a.watches {
			stop()
		}
		a.watches = map[int64]func(){}
		a.mu.Unlock()
		if a.stopStatus != nil {
			a.stopStatus()
		}
		select {
		case <-loadsDone:
		case <-time.After(10 * time.Second):
			// A load that ignores its cancelled context; the SDK close
			// below cancels its bootstrap and joins its own work.
		}
		errs = append(errs, closeSDKHook(a.sdk), a.state.flush())
	})
	<-a.closeDone
	return a.closeErr
}

// closeSDKHook is closeSDK; a test replaces it to make the close panic.
var closeSDKHook = func(s *anysyncsdk.SDK) error { return closeSDK(s) }

// closeSDK closes the SDK, turning a panic into an error.
func closeSDK(s interface{ Close() error }) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = &shimError{code: codePanic, err: fmt.Errorf("panic in SDK close: %v\n%s", r, debug.Stack())}
		}
	}()
	return s.Close()
}

// startOp starts an op on the account's context and tracks it, so the
// close drops it with the account. The op holds no call lock: the close
// cancels it through the context.
func (a *account) startOp(f func(ctx context.Context) (any, error)) uint64 {
	h, _ := startOpWith(a.ctx, f, nil)
	a.mu.Lock()
	if len(a.opHandles) > 64 {
		// Forget handles already delivered or cancelled.
		handles.mu.Lock()
		for k := range a.opHandles {
			if _, ok := handles.m[k]; !ok {
				delete(a.opHandles, k)
			}
		}
		handles.mu.Unlock()
	}
	a.opHandles[h] = struct{}{}
	a.mu.Unlock()
	return h
}

// dropOps takes the account's ops out of the registry and cancels them.
func (a *account) dropOps() {
	a.mu.Lock()
	hs := a.opHandles
	a.opHandles = map[uint64]struct{}{}
	a.mu.Unlock()
	for h := range hs {
		if o, ok := takeIf[*op](h); ok {
			o.abandon()
		}
	}
}

// closeNow closes the account on the calling goroutine (tests).
func (a *account) closeNow() error {
	if !a.beginClose(true) {
		<-a.closeDone
		return errClosed
	}
	return a.finishClose(0)
}

func (a *account) info() map[string]any {
	st := a.sdk.P2PStatus()
	peers := make([]map[string]any, 0, len(st.Peers))
	for _, p := range st.Peers {
		peers = append(peers, map[string]any{"peerId": p.PeerId, "connected": p.Connected, "spaceIds": nonNil(p.SpaceIds)})
	}
	return map[string]any{
		"accountId":   a.sdk.Account().Id(),
		"peerId":      a.sdk.PeerId(),
		"techSpaceId": a.sdk.TechSpaceId(),
		"p2p": map[string]any{
			"enabled":        st.Enabled,
			"listening":      st.ListenerStarted,
			"port":           st.Port,
			"state":          st.State.String(),
			"localDiscovery": st.LocalDiscovery,
			"peers":          peers,
		},
	}
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// cleanupCtx is for undoing a half-done write: it outlives a close that
// cancelled the call, but not by much.
func cleanupCtx() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 10*time.Second)
}

// ---------------------------------------------------------------- exports

func withAccount(h C.uint64_t, f func(a *account) error) error {
	a, err := lookup[*account](uint64(h), "an account")
	if err != nil {
		return err
	}
	leave, err := a.enter()
	if err != nil {
		return err
	}
	defer leave()
	return f(a)
}

//export any_shim_account_cancel
func any_shim_account_cancel(h C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		a, err := lookup[*account](uint64(h), "an account")
		if err != nil {
			return err
		}
		a.cancelCalls()
		return nil
	})
}

// accountOpenStart is any_shim_account_open_start without the cgo types.
func accountOpenStart(optsJSON string) (uint64, error) {
	p, err := prepareAccount(optsJSON)
	if err != nil {
		return 0, err
	}
	h, _ := startOpWith(context.Background(), func(ctx context.Context) (any, error) {
		a, err := p.open(ctx)
		if err != nil {
			return nil, err
		}
		return map[string]any{"account": handles.add(a)}, nil
	}, func(r any) {
		// Opened, but nobody will take it: close it again.
		if m, ok := r.(map[string]any); ok {
			if h, ok := m["account"].(uint64); ok {
				releaseAccount(h)
			}
		}
	})
	return h, nil
}

// accountCloseStart is any_shim_account_close_start without the cgo types.
func accountCloseStart(h uint64, waitLoadsMs int32) (uint64, error) {
	a, err := take[*account](h, "an account")
	if err != nil {
		return 0, err
	}
	wait := time.Duration(max(waitLoadsMs, 0)) * time.Millisecond
	a.beginClose(wait == 0)
	return startOp(context.Background(), func(context.Context) (any, error) {
		if err := a.finishClose(wait); err != nil {
			return nil, err
		}
		return map[string]any{}, nil
	}), nil
}

//export any_shim_account_open_start
func any_shim_account_open_start(optsJSON *C.char, outOp *C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		if outOp == nil {
			return invalid("out_op is NULL")
		}
		h, err := accountOpenStart(goStr(optsJSON))
		if err != nil {
			return err
		}
		putOp(outOp, h)
		return nil
	})
}

//export any_shim_account_close_start
func any_shim_account_close_start(h C.uint64_t, waitLoadsMs C.int32_t, outOp *C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		if outOp == nil {
			return invalid("out_op is NULL")
		}
		op, err := accountCloseStart(uint64(h), int32(waitLoadsMs))
		if err != nil {
			return err
		}
		putOp(outOp, op)
		return nil
	})
}

// releaseAccount is any_shim_account_release without the cgo types.
func releaseAccount(h uint64) {
	defer func() { _ = recover() }()
	a, ok := takeIf[*account](h)
	if !ok {
		return
	}
	a.beginClose(true)
	go func() {
		defer func() { _ = recover() }()
		_ = a.finishClose(0)
	}()
}

//export any_shim_account_release
func any_shim_account_release(h C.uintptr_t) {
	releaseAccount(uint64(h))
}

//export any_shim_account_info
func any_shim_account_info(h C.uint64_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error { return putJSON(outJSON, a.info()) })
	})
}

//export any_shim_set_local_discovery
func any_shim_set_local_discovery(h C.uint64_t, enabled C.int32_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			a.sdk.SetLocalDiscoveryEnabled(enabled != 0)
			return nil
		})
	})
}
