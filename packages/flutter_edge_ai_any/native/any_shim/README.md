# libany_shim

A Go library over [any-sync-sdk](https://github.com/anyproto/any-sync-sdk)
and [any-store](https://github.com/anyproto/any-store) v2, with a C ABI for
`dart:ffi`. One process runs the SDK (an account, its spaces, p2p) and any
number of local indexes.

| file | what |
|---|---|
| `include/any_shim.h` | the C ABI (version 2): the contract, documented per function |
| `shim.go`, `errors.go`, `registry.go`, `ops.go` | exports, status codes, the handle registry, started ops |
| `account.go`, `state.go`, `lock_unix.go`, `lock_windows.go`, `bgtask_ios.go` | account open/close, directory claims and locks, the account state file, the iOS background task |
| `spaces.go`, `bundles.go`, `objects.go`, `files.go`, `events.go` | SDK side: spaces and their loads, the RAG bundles, objects and records, files, the change feed |
| `index.go`, `keycheck.go`, `values.go` | the any-store local index and its keycheck sidecar |
| `third_party/any_editor/` | `any`'s editor module, copied verbatim (MIT) |
| `build.sh` | one target per call; see its header |
| `check_exports.py` | the gate every build passes: exports equal the header, container fits the target |
| `release.py` | release archives, checksums, manifest, verification |
| `tools/device_smoke.c` | dlopen + the offline path on a device without Dart (an Android emulator over adb) |
| `THIRD_PARTY_NOTICES.md` | licenses of every Go module linked into the library |
| `testdata/nodeconf-dead.yml` | the SDK's local test network with every node on a closed port |

Pinned: Go 1.27.3 (`toolchain` in `go.mod`; `build.sh` refuses another),
any-sync-sdk v0.7.4, any-sync v0.13.8, any-store v2.4.3 (`go.sum`).

## ABI rules

- Every function returns a status (`ANY_SHIM_OK` or an `ANY_SHIM_ERR_*`
  code) and writes results only through out-parameters, only on success.
  An error writes a message to `*out_error`. Strings out are freed with
  `any_shim_free`.
- No panic crosses the boundary: each export recovers and returns
  `ANY_SHIM_ERR_PANIC`. A panic on a goroutine the SDK started itself is
  outside that.
- Handles come from a registry: a stale or forged one is
  `ANY_SHIM_ERR_CLOSED`, never a dereference.
- Changing a signature, a code or a JSON shape incompatibly bumps
  `ANY_SHIM_ABI_VERSION`; the Dart side refuses a library with another.
- Held together by tests: cgo compiles the exports against the header
  (`const` cannot be expressed, so the header has none), `abi_test.go`
  compares the header with the Go exports, the status codes and
  `check_exports.py`, and the Dart package's
  `test/bindings_match_header_test.dart` compares it with the bindings.

## Native API (ABI 2)

`include/any_shim.h` is the reference; this is the shape of it.

**Nothing blocks.** A call that may wait for the network or for a close
is split in two: `*_start` returns an op handle at once, and
`any_shim_op_wait(op, wait_ms)` waits at most 250 ms per call
(`ANY_SHIM_ERR_PENDING` while the op runs; its own status and result once,
then the handle is gone). `any_shim_op_cancel` never blocks; a cancelled
op whose result holds something (an opened account) frees it. The started
calls: `account_open_start`, `account_close_start`,
`space_list_sync_start`, `space_resolve_start`, `space_sync_heads_start`,
`file_read_start`, `index_bind_start`, `index_close_start`. Ops of an
account are dropped with it; a finished op nobody waited for is dropped
after 10 minutes. `events_poll`, `index_flush` and `index_gc` bound their
work to about 250 ms. Everything else returns within local database work,
except `file_attach` (proportional to the file). A worker isolate
therefore never holds a Dart hot restart for longer than one slice.

**Accounts.** `account_open_start` takes `dataDir`, `indexDir` and an
`ownerToken` (random per isolate group). Each directory is claimed in
this process, synchronously in the start call: a claim of another token
(the previous generation of a hot restart) or one still closing is
`ERR_BUSY` (retry); the same token is `ERR_REFUSED`. Across processes,
`<dataDir>/.shimlock` is held with `flock` / `LockFileEx` (`ERR_BUSY`;
not `.lock`, any-store's sentinel name). The SDK opens in the op.
`account_cancel` cancels every call and space load, never blocks, and is
terminal. `account_close_start(h, wait_loads_ms)`: a suspend passes 25000
so a first space load in flight can finish (inside the iOS background
task) before the cancel; a close passes 0. The release of the lock and
the claims runs even when the SDK close fails or panics. `account_release(uintptr_t)` and
`index_release(uintptr_t)` have the `void(void*)` shape of a
`NativeFinalizer`: they take the handle out of the registry (a stale one
is a no-op), mark the directories closing at once and close on a
goroutine; a failed SDK close still releases the claim and the lock. On
iOS the close runs inside a `beginBackgroundTaskWithName:` task
(`UIApplication` found at run time, so the library links no UIKit).

**Account state** (`<dataDir>/any_shim_state.json`, written atomically):
per space `createdHere` and `everPeerSynced`. `everPeerSynced` is set the
first time a space's `LastSyncedAt` is non-zero (the shim subscribes to
the account's sync status itself) or a `sync_heads` round reaches a peer;
it is never cleared. `space_status` reports both, plus `loading`,
`lastSyncedAt` and `stateSaveError` (the last save failed). A
`sync_heads` whose flag could not be saved is not OK; a `space_create`
whose save failed is OK with `stateSaveError` (the space exists).

**Spaces load once.** The first call that needs a space starts one
detached `Spaces().Get` on the account's context (single-flight per space;
a failed load frees the slot; an unknown id fails at once as
`ERR_NOT_FOUND`). A call that needs the space waits for it at most
150 ms, then answers `ERR_PENDING`; `space_resolve_start` is the wait.

**RAG bundles.** `rag_bundles(ensure)` declares
`flutter_edge_ai.rag.location/v1` (object-kind properties `core` (a leaf
per modality), `fields`, `profiles`, `textSearch` (leaf `on`); part
`tomb` with the records dataset `tombstones`: user ids
`[0-9a-f]{64}|[a-z][a-z0-9_]{0,31}`, no deletes, `key` (string) and `revs`
(array of numbers) mutable by anyone) and `flutter_edge_ai.rag.document/v1` (properties
`doc`, `vecs`; part `body` with the editor dataset). Both on their derived
roots, hidden. The declarations are frozen (`TestRagBundleDeclarationsFrozen`
pins them): a change needs a new bundle id. Property ids are read from the
space, never computed.

**Objects and records.** `object_patch` sets declared properties, or
leaves (`[0-9a-z-]+`) of object-kind ones, on an object by id, a new one
(one change) or a derived one. Any SDK error and any op rejection is
non-OK (`ERR_DELETED` for a deleted object or record, else
`ERR_REFUSED`); a create whose values did not all land is deleted again.
`object_read` reads by ids or a type page (by object id) with an anchor
`{generation, maxApplySeq}` read before the page. `object_derive_id`
computes a derived object's id without a write (pinned to
`Objects().Derive` by a test). `records_modify` /
`records_read` work on a records dataset (the tombstones).

**Local index.** One any-store file per location: `meta` (format,
fileId, active generation, bind config), `docs_<n>` (rows: `id`, `text`,
`meta`, `f.<key>`, `embedding`; exact vector index, a range index per
bound field, full text on `text` when bound) and `state_<n>`. A rebuild
fills a new generation and swaps it in by flipping `meta.active` in one
transaction (`shadowBegin`, `shadowSwap`), under an exclusive lock so no
reader meets a closed collection. Old and unswapped generations become
orphans; `index_gc` drops them in bounded steps (also those found at
open). `index_bind_start` builds new indexes over every row in an op.
`index_apply` validates every op and every vector slot (slots tile the
float buffer in order, dimension equals the bound one, finite values)
before one write transaction, and checks its compare-and-set state keys
first. The key is 32 bytes (any-store's raw-key path). The keycheck
sidecar `<path>.keycheck` (`{"fmt":1,"fileId","mode","mac"}`,
`mac = HMAC-SHA256(key, "flutter_edge_ai_any/keycheck/v1" ‖ fileId
bytes)`) is written before the database, so every crash state is
classified (`TestIndexKeycheckCrashMatrix`): a wrong key and a damaged
file are told apart by the sidecar, never by any-store's message; a
file-system refusal (`EACCES`, `EPERM`, `ENOSPC`, `EROFS`, `EDQUOT`,
`EIO`, Windows disk-full) is `ERR_IO` by its errno, and so is any-store's
"database is full" (its sentinel is internal: the text is pinned to the
any-store source by `TestAnystoreFullTextIsCurrent`). The index lock is
`<path>.shimlock`.

**Status codes.** 0 OK, 1 INVALID_ARGUMENT, 2 NOT_FOUND, 3 DELETED,
4 CLOSED, 5 TIMEOUT, 6 REFUSED, 7 INTERNAL, 8 PANIC, 9 CONFLICT,
10 CORRUPT, 11 KEY_MISMATCH, 12 BUSY (retry), 13 PENDING (op not
finished, or space loading), 14 KEY_MISSING (retry), 15 IO (retry). A
caller maps a code it does not know to INTERNAL.

## Testing

```bash
go vet ./... && go test ./...      # -short skips the network tests
```

The network tests use a blackhole address (`10.255.255.1:443`) and LAN
p2p between two accounts in one process, on a random mDNS service name,
with `testdata/nodeconf-dead.yml`; never the production network. In a
sandbox that blocks mDNS, run them outside it.

## Building

```bash
build.sh macos_arm64|ios_arm64|ios_sim_arm64|android_arm64 [<out_dir>]   # on a Mac
build.sh linux_x86_64|linux_arm64 [<out_dir>]                            # on Linux of that arch
build.sh windows_x86_64 [<out_dir>]                                      # on Windows (MinGW-w64)
```

The default `<out_dir>` is `prebuilt/`, where the hook picks a build up
(gitignored). CI builds all seven: `.github/workflows/any-native.yml`.

Sizes (stripped library / release archive), from the first builds:

| target | library | archive |
|---|---|---|
| macos_arm64 | 33.1 MB | 12.6 MB |
| ios_arm64 | 33.0 MB | 12.4 MB |
| ios_sim_arm64 | 33.2 MB | 12.6 MB |
| android_arm64 | 36.5 MB | 12.9 MB |

The weight is the SDK's: any-sync's tree storage (any-store v1 + SQLite),
QUIC, libp2p pieces, iroh and protobuf. `-tags nographviz` already drops
graphviz + wazero on macOS and Linux (4.2 MB on macOS; Android and iOS never
link it).

## Releasing (maintainer, after approval)

A release is the tag `native-any-v<version>` with seven archives,
`checksums_any_shim.txt` and `manifest.json`. `<version>` is `shimVersion`
in `shim.go` and `_bundleVersion` in `../../hook/build.dart`. A tag, once
published, never changes: different bytes go out under a new version with a
letter suffix (`0.1.0-a`).

1. Run `any-native.yml` on the commit; download the `any-shim-release-layout`
   artifact (all archives, checksums and manifest, already verified).
2. Regenerate `THIRD_PARTY_NOTICES.md` when `go.sum` changed (the
   modules `go list -deps -tags nographviz` reports for the seven targets,
   with their license texts).
3. Create the tag and upload the artifact's files.
4. Download the assets back, `release.py verify <dir> <version>` (it also checks that `shim.go`
   says `shimVersion = <version>`, so a `-dev` build is never released,
   and that `abiVersion` equals the header's).
5. Put the checksums into `_checksums` in `hook/build.dart` and run
   `release.py verify <dir> <version> --hook ../../hook/build.dart`.
