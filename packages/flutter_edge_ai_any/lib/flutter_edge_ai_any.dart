/// A flutter_edge_ai_rag vector-store provider over any-sync: documents
/// sync end-to-end encrypted between a user's devices, and each device
/// keeps a local vector + BM25 index of them.
///
/// ```dart
/// final account = await AnySyncAccount.open(
///   dataDirectory: '$support/any/sdk',
///   indexDirectory: '$support/any/index',
///   mnemonic: mnemonic,
///   deviceKey: deviceKey,
///   nodeConfYaml: nodeConf,
/// );
/// final rag = FlutterEdgeAiRag(providers: [AnyVectorStoreProvider(account)]);
/// ```
///
/// Native platforms only: on the web `AnyVectorStoreProvider.canHandle` is
/// false and `AnySyncAccount.open` throws `UnsupportedError`. The app
/// lifecycle helper is a separate library,
/// `package:flutter_edge_ai_any/lifecycle.dart`.
library;

export 'src/api/any_sync.dart'
    show
        AnySyncAccount,
        AnySyncAccountState,
        AnySyncBackfill,
        AnySyncBusyException,
        AnySyncBusyReason,
        AnySyncClockExhaustedException,
        AnySyncClosedException,
        AnySyncCommittedException,
        AnySyncCompaction,
        AnySyncConflict,
        AnySyncConflictException,
        AnySyncException,
        AnySyncLocalIndexErrorKind,
        AnySyncLocalIndexException,
        AnySyncLocation,
        AnySyncLocationStatus,
        AnySyncManifest,
        AnySyncManifestProfile,
        AnySyncMissingVector,
        AnySyncMissingVectors,
        AnySyncNotReadyException,
        AnySyncNotReadyReason,
        AnySyncP2p,
        AnySyncPull,
        AnySyncReadOnlyException,
        AnySyncSpace,
        AnySyncSpaceList,
        AnySyncSpaceState,
        AnySyncStatus,
        AnySyncSuspendedException,
        AnySyncSyncResult,
        AnySyncUnindexableReason,
        AnySyncVectorFailure,
        AnySyncVectorItem,
        AnySyncVectorWrite,
        AnyVectorStoreProvider;
