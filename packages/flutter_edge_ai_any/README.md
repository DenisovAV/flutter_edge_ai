# flutter_edge_ai_any

**Status: native layer only, not published.** This package will connect
flutter_edge_ai to [any-sync](https://github.com/anyproto/any-sync): documents
and files in an end-to-end encrypted space that syncs between a user's
devices, and a vector + BM25 index that each device keeps locally. What is
here is the part under that: a native library and its Dart bindings. There is
no public API yet, no RAG provider and no ecosystem API; those, and the
network the package may join, are separate decisions.

## What is here

- `native/any_shim/`: **libany_shim**, a Go library that runs
  [any-sync-sdk](https://github.com/anyproto/any-sync-sdk) v0.7.4 and an
  [any-store](https://github.com/anyproto/any-store) v2 local index in
  process (no server, no HTTP). Its C API is `include/any_shim.h`: accounts,
  spaces, document objects, files, the change feed and sync status, and the
  local index. See [native/any_shim/README.md](native/any_shim/README.md).
- `hook/build.dart`: the Native Assets hook. It registers a local build
  (`native/any_shim/prebuilt/<target>/`) or downloads the release archive for
  the target from the `native-any-v0.1.0` release and checks its SHA256.
- `lib/src/ffi/`: the `@Native` bindings (one per C function) and a thin
  internal wrapper (`AnyShimAccount`, `AnyShimIndex`). Nothing is exported
  from `lib/flutter_edge_ai_any.dart`. `lib/` imports no Flutter.

Platforms: Android arm64, iOS arm64 (device and Apple-silicon simulator),
macOS arm64, Linux x64 and arm64, Windows x64. No web: any-sync's transports
(QUIC, TCP, mDNS) and its tree storage have no browser build.

## Network

An account needs a nodeconf; there is no default network. The shim refuses
the production any-sync network (the one Anytype and `any` use) until its
terms for third-party apps are known, and never enables global p2p (relays).
What works today is LAN p2p between devices of one account (mDNS + QUIC),
with a nodeconf whose nodes are unreachable, as the tests do.

## Testing

```bash
# Go unit tests (shim, index, offline account)
cd native/any_shim && go test ./...

# Dart: build the library for this Mac first, then
native/any_shim/build.sh macos_arm64
dart test                              # bindings vs header + offline suite
dart test -t lan --run-skipped         # two processes syncing over LAN
```

Without a local build, the hook downloads the pinned release for the host;
a host whose archive the hook does not pin skips the native suites with the
reason, and on a pinned host a missing library fails them.

## Known limits

- The first open of a space on a second device can wait ~60 s for the SDK's
  periodic re-handshake (about half of the LAN test runs here).
- Objects written with a `seed` (an id derived from a caller key, the same on
  every device) can never be deleted: any-sync refuses to delete a derived
  object.
- The SDK keeps document text in plaintext in its own database (`sdk.db`);
  the local index can be encrypted (`passphrase`).
- No pause/resume for mobile backgrounding: close the account and reopen it.
- ~33-37 MB per ABI (12-13 MB compressed).
- The body format is `any`'s editor module, copied from `any` v0.4.1
  (`native/any_shim/third_party/any_editor`, MIT).
