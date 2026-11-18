# libany_shim

A Go library over [any-sync-sdk](https://github.com/anyproto/any-sync-sdk)
and [any-store](https://github.com/anyproto/any-store) v2, with a C ABI for
`dart:ffi`. One process runs the SDK (an account, its spaces, p2p) and any
number of local indexes.

| file | what |
|---|---|
| `include/any_shim.h` | the C ABI (version 1): the contract, documented per function |
| `shim.go`, `errors.go`, `registry.go` | exports, status codes, the handle registry |
| `account.go`, `objects.go`, `files.go`, `events.go` | SDK side |
| `index.go`, `values.go` | the any-store local index |
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
4. Download the assets back, `release.py verify <dir> <version>`.
5. Put the checksums into `_checksums` in `hook/build.dart` and run
   `release.py verify <dir> <version> --hook ../../hook/build.dart`.
