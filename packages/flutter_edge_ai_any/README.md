# flutter_edge_ai_any

**Status: experimental.** A
[flutter_edge_ai_rag](https://pub.dev/packages/flutter_edge_ai_rag) vector-store provider over
[any-sync](https://github.com/anyproto/any-sync): a RAG location's documents
live in an end-to-end encrypted space that syncs between a user's devices,
and each device keeps its own local vector + BM25 index of them. Search never
touches the network.

Every public type is `@experimental`. Native platforms only (Android arm64,
iOS arm64 device and Apple-silicon simulator, macOS arm64, Linux x64 and
arm64, Windows x64); on the web `AnyVectorStoreProvider.canHandle` is false
and `AnySyncAccount.open` throws `UnsupportedError`.

## Install

```yaml
dependencies:
  flutter_edge_ai_rag: ^1.3.0
  flutter_edge_ai_any: ^0.1.0
```

There is no default network yet: see [Network](#network) before you plan on
sync beyond a LAN.

## Use

```dart
final account = await AnySyncAccount.open(
  dataDirectory: '$support/any/sdk',
  indexDirectory: '$support/any/index',   // one per account; derived data
  mnemonic: mnemonic,                     // AnySyncAccount.newMnemonic(), kept by the app
  deviceKey: deviceKey,                   // newDeviceKey(); store it "this device only"
  nodeConfYaml: nodeConf,
  localEncryptionKey: key32,              // optional: encrypts the index files
);
final space = await account.createSpace('notes');
final location = AnySyncLocation(spaceId: space.id, indexName: 'notes');
final rag = FlutterEdgeAiRag(providers: [AnyVectorStoreProvider(account)]);
final index = await rag.open(
  spec: VectorStoreSpec(
    providerId: AnyVectorStoreProvider.providerId,
    location: location.value,             // any:<spaceId>/<indexName>
    enableTextSearch: true,
  ),
  embedder: embedder,
);
```

Another device of the same account finds the space with
`account.spaces(sync: true)` and opens the same location.

## What to know

- **Writes are last-writer-wins by a hybrid clock.** A remove or clear hides
  every version with a lower rev, also ones it never saw; a later write
  survives a remove it never saw. A device whose clock runs ahead wins until
  the others pass its revs; `locationStatus().revsAheadOfClock` counts revs
  read more than 5 minutes ahead of this device's clock.
- **An unchanged add is a no-op.** Adding a document whose content and
  metadata equal the visible version writes nothing, so re-importing a corpus
  at every start is free. It also does not undo a remove or clear this device
  has not received yet: to bring a removed document back, receive the remove
  first, or change the content.
- **Every saved version costs about 32 KB** of the SDK's database on every
  device that was online while it lived, and deleting it gives nothing back
  there (later joiners fetch none of it). Add when the content has settled.
  Superseded versions are deleted once a peer has the new one;
  `account.compact(location)` deletes what is left.
- **The first open of a location** publishes its manifest (modality, filter
  fields, profiles) only after a round with a peer found none, or, on the
  device that created the space while it has never synced with a peer.
  Otherwise the open fails with `AnySyncNotReadyException(manifestNotSynced)`
  (retryable). Several devices may bind several profiles; the same profile id
  with another dimension, another modality, or a filter field with another
  type is an `AnySyncConflictException`: use a different location. A member
  without write permission opens read-only when nothing needs publishing, and
  every write fails with `AnySyncReadOnlyException`.
- **A new local index file takes writes after its first full pull**
  (`AnySyncNotReadyException(firstPullPending)` until then); opening a
  location does that pull, offline too.
- **Text-only rows.** A document synced from a device with another embedding
  profile has no vector for yours: it is found by text search, not by vector
  search, and listed by `account.missingVectors(location)`. Fill them with
  `backfillVectors` (an embedder and `inputFor`, which says what to embed for
  each item: rag lets content and the embedded input differ) or
  `writeMissingVectors` (vectors you computed yourself, any modality). Both
  write only a vector, never re-create a document.
- **Account calls** (`pull`, `syncNow`, `missingVectors`, `writeMissingVectors`,
  `backfillVectors`, `locationStatus`, `compact`) need a location this device
  opened once through `FlutterEdgeAiRag`; `locationStatus` and
  `missingVectors` also work while the account is suspended.
- **Hybrid search** has no snapshot between its two legs: a document arriving
  from a peer in between can be in one leg only. Its topK is at most 2,500
  (each leg asks for 4 × topK; exact search takes at most 10,000).
- **Encryption.** `localEncryptionKey` encrypts the local index files. The
  SDK's own database (`sdk.db`) keeps document text in plaintext; space
  contents are end-to-end encrypted on the wire and on peers.
- **The editor body** each document gets (so the `any` app can show it) is
  display only: the index never reads it, and edits made there change only
  the display.
- **Mobile lifecycle.** `package:flutter_edge_ai_any/lifecycle.dart` has
  `AnySyncLifecycle`, which suspends the account when the app goes to the
  background (iOS at once, Android after 5 s) and resumes it after. On iOS,
  keep the data and index directories out of an App Group container: a
  process suspended holding a lock there is killed (`0xdead10cc`). Searches
  keep working while suspended; anything that needs the SDK fails with
  `AnySyncSuspendedException` until `resume()`. On iOS a suspend waits for a
  space load in flight for at most 25 s, less when iOS reports less
  background time (read after the close's own background task began). Not
  yet measured on a device: the iOS simulator reports unlimited background
  time, so there only the 25 s cap applies.
- **Background sync errors** are reported, never thrown at you: see
  `locationStatus().lastFollowerError` (and `lastFollowerErrorAt`) and the
  `account.followerEvents()` stream (a failure, or `recovered` once a pull
  succeeds again); the follower retries with backoff. A vector the index
  refuses (`rejectedByIndex`) leaves only that document text-only.
- **The account's events can go down** (the native poller, or the sync
  status watch). They restart on their own with backoff (1 s to 60 s, never
  giving up); meanwhile no location hears of a change until a pull, and
  `locationStatus().eventsDownSince` / `eventsDownError` and an account
  event on `followerEvents()` (a null `location`) say so. Only working
  events clear it, not a pull.
- **A bind or a rebuild's swap holds a location's index** exclusively for
  a moment (a growing bind backfills every row). Writes and follower pages
  wait for it; a search waits at most 10 s, then fails with
  `AnySyncNotReadyException(indexBusy)` (retryable).
- **Close errors are not hidden.** `account.close()`, `suspend()` and a
  store's close throw an `AnySyncException` with the native message when
  the native close failed, after their own cleanup (a closed or suspended
  account stays so). A native close that returns an error still releases
  the directory; only a close that panicked leaves it refused for the life
  of the process (`AnySyncBusyException(previousInstanceFailed)`, carrying
  the cause): restart the app.
- **Old index generations** a rebuild leaves behind are dropped in the
  background in bounded steps; `locationStatus().orphanGenerations` and
  `lastGcError` say how that goes.
- **Tombstones are never deleted.** Each remove of a key adds one rev to its
  record (`$addToSet`); bundle v1 cannot compact them, so a key removed very
  often grows its record by a number each time.

## Network

An account needs a nodeconf; there is no default network. The shim refuses
the production any-sync network (the one Anytype and `any` use) until its
terms for third-party apps are known, and never enables global p2p (relays).
What works today is LAN p2p between devices of one account (mDNS + QUIC),
with a nodeconf whose nodes are unreachable, as the tests do. The first open
of a space on a second device can wait ~60 s for the SDK's periodic
re-handshake.

## Native library

`native/any_shim/` is **libany_shim**, a Go library that runs
[any-sync-sdk](https://github.com/anyproto/any-sync-sdk) v0.7.4 and an
[any-store](https://github.com/anyproto/any-store) v2 local index in process.
Its C API is `include/any_shim.h` (ABI 2); see
[native/any_shim/README.md](native/any_shim/README.md). `hook/build.dart`
registers a local build (`native/any_shim/prebuilt/<target>/`) or downloads
the pinned release, `native-any-v0.2.0` (ABI 2), checking each archive's
SHA256. ABI 2 and the `/v1` bundles are frozen at that tag: spaces written by
dev builds before it (including LAN test spaces) must be discarded, not
migrated.

## Testing

```bash
native/any_shim/build.sh macos_arm64          # the ABI-2 library for this Mac
cd native/any_shim && go test ./... && cd -   # Go
flutter test                                  # unit suites on an in-memory fake + native suites
flutter test -t lan --run-skipped test/lan    # two accounts over LAN (needs multicast)
```

The native suites skip, with the reason, when no ABI-2 library is loadable.

## Known limits

- `RagIndex.removeWhere` is not implemented: on this store it throws
  `UnsupportedError`; remove documents by id.
- Objects written with a seed (the location manifests) can never be deleted.
- ~33-37 MB per ABI (12-13 MB compressed).
- The body format is `any`'s editor module, copied from `any` v0.4.1
  (`native/any_shim/third_party/any_editor`, MIT).
