package main

/*
#include "any_shim.h"
*/
import "C"

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"strings"
	"sync"
	"sync/atomic"

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
	Mnemonic     string  `json:"mnemonic"`
	AccountIndex *uint32 `json:"accountIndex"`
	DeviceKeyHex string  `json:"deviceKeyHex"`
	NodeConfYAML string  `json:"nodeConfYaml"`
	P2P          p2pOpts `json:"p2p"`
	LogLevel     string  `json:"logLevel"`
}

// account is one open SDK instance.
//
// Calls hold ops for reading while they run; close takes it for writing
// after cancelling ctx, so the SDK is never closed under a call, and a
// call blocked on the network returns at once instead of holding close.
type account struct {
	sdk    *anysyncsdk.SDK
	ctx    context.Context
	cancel context.CancelFunc
	events *eventQueue

	ops    sync.RWMutex
	closed atomic.Bool

	mu       sync.Mutex
	docTypes map[string]*docTypeCache // spaceId ->
	watches  map[int64]func()
	watchSeq int64
}

var loggerOnce sync.Once

func decodeStrict(s string, v any) error {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return invalid("options: %v", err)
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

func openAccount(optsJSON string) (*account, error) {
	var o openOpts
	if err := decodeStrict(optsJSON, &o); err != nil {
		return nil, err
	}
	if o.DataDir == "" {
		return nil, invalid("dataDir is required")
	}
	if o.Mnemonic == "" {
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
	prov, err := auth.NewMnemonicProvider(auth.MnemonicConfig{Mnemonic: o.Mnemonic, Index: idx, DeviceKey: dev})
	if err != nil {
		return nil, invalid("account: %v", err)
	}
	off := false
	cfg := config.Config{
		Storage: config.Storage{DataDir: o.DataDir, Topology: config.StorageShared},
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
	ctx, cancel := context.WithCancel(context.Background())
	s, err := anysyncsdk.Open(ctx, cfg, prov)
	if err != nil {
		cancel()
		return nil, err
	}
	return &account{
		sdk:      s,
		ctx:      ctx,
		cancel:   cancel,
		events:   newEventQueue(defaultQueueCapacity),
		docTypes: map[string]*docTypeCache{},
		watches:  map[int64]func(){},
	}, nil
}

// enter marks a call in progress; the returned func ends it.
func (a *account) enter() (func(), error) {
	a.ops.RLock()
	if a.closed.Load() {
		a.ops.RUnlock()
		return nil, errClosed
	}
	return a.ops.RUnlock, nil
}

func (a *account) close() error {
	if a.closed.Swap(true) {
		return errClosed
	}
	a.cancel()
	a.events.close()
	a.ops.Lock()
	defer a.ops.Unlock()
	a.mu.Lock()
	for _, stop := range a.watches {
		stop()
	}
	a.watches = map[int64]func(){}
	a.mu.Unlock()
	return a.sdk.Close()
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

func (a *account) space(id string) (space.Space, error) {
	if id == "" {
		return nil, invalid("space id is empty")
	}
	return a.sdk.Spaces().Get(a.ctx, id)
}

func spaceStatusJSON(st space.SpaceSyncStatus) map[string]any {
	return map[string]any{
		"spaceId": st.SpaceId, "state": st.State.String(), "p2p": st.P2P.String(),
		"localPeers": st.LocalPeers, "networkPeers": st.NetworkPeers,
		"globalPeers": st.GlobalPeers, "synced": st.Synced, "total": st.Total,
	}
}

func (a *account) spaceList(syncFirst bool) ([]map[string]any, error) {
	if syncFirst {
		// Best effort by contract: with no peer reachable this fails,
		// and the local list is still the answer.
		_ = a.sdk.Spaces().SyncSpaceList(a.ctx)
	}
	list, err := a.sdk.Spaces().List(a.ctx)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(list))
	for _, i := range list {
		out = append(out, map[string]any{"id": i.Id, "name": i.Name, "status": i.Status.String()})
	}
	return out, nil
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

//export any_shim_account_open
func any_shim_account_open(optsJSON *C.char, outAccount *C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		if outAccount == nil {
			return invalid("out_account is NULL")
		}
		a, err := openAccount(goStr(optsJSON))
		if err != nil {
			return err
		}
		*outAccount = C.uint64_t(handles.add(a))
		return nil
	})
}

//export any_shim_account_close
func any_shim_account_close(h C.uint64_t, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		a, err := lookup[*account](uint64(h), "an account")
		if err != nil {
			return err
		}
		handles.remove(uint64(h))
		return a.close()
	})
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

//export any_shim_space_create
func any_shim_space_create(h C.uint64_t, name *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			sp, err := a.sdk.Spaces().Create(a.ctx, space.CreateRequest{Name: goStr(name)})
			if err != nil {
				return err
			}
			return putJSON(outJSON, map[string]any{"id": sp.Id()})
		})
	})
}

//export any_shim_space_list
func any_shim_space_list(h C.uint64_t, syncFirst C.int32_t, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			l, err := a.spaceList(syncFirst != 0)
			if err != nil {
				return err
			}
			return putJSON(outJSON, l)
		})
	})
}

//export any_shim_space_status
func any_shim_space_status(h C.uint64_t, spaceID *C.char, outJSON, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			id := goStr(spaceID)
			if id == "" {
				return invalid("space id is empty")
			}
			return putJSON(outJSON, spaceStatusJSON(a.sdk.Spaces().Status(id)))
		})
	})
}

//export any_shim_space_sync_heads
func any_shim_space_sync_heads(h C.uint64_t, spaceID *C.char, outErr **C.char) C.any_shim_status {
	return guard(outErr, func() error {
		return withAccount(h, func(a *account) error {
			sp, err := a.space(goStr(spaceID))
			if err != nil {
				return err
			}
			return sp.SyncHeads(a.ctx)
		})
	})
}
