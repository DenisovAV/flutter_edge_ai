// The native seam: what the provider logic calls, and nothing it can see of
// how. Two implementations: the FFI runtime (lib/src/native/ffi_runtime.dart:
// libany_shim on an SDK isolate, an index isolate and an events isolate per
// account) and the in-memory fake the unit tests use
// (test/support/fake_native.dart).
//
// The logic never calls native code directly. It hands a JOB (a closure) to
// the runtime, which runs it where the handle lives: SDK jobs on the SDK
// isolate against an [AnySdk], index jobs on the index isolate against an
// [AnyIndexHost]. A job therefore must be sendable: it may capture only
// plain data (strings, numbers, lists, maps, records, instances of plain
// classes), never the store, the account, a port or a Completer. The fake
// sends every job through a port too, so a capture that would break on the
// real isolates breaks the unit tests first.
//
// Inside a job the calls are synchronous: each returns within a local
// database operation, or, for the calls that may wait on the network, starts
// an op that [awaitOp] waits for in slices of at most 250 ms (any_shim.h).
//
// Pure Dart: no dart:ffi here, so the web build compiles it.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'any_status.dart';

export 'any_status.dart';

typedef SdkJob<T> = FutureOr<T> Function(AnySdk sdk);
typedef IndexJob<T> = FutureOr<T> Function(AnyIndexHost host);

/// Waits for the ops of any_shim.h (one op table per process: account,
/// space and index ops alike).
abstract interface class OpWaiter {
  OpPoll opWait(int op, int waitMs);
  void opCancel(int op);
}

/// The SDK side of one account, as seen from its SDK isolate.
///
/// Every call on a space or object needs an open account; with none (never
/// opened, or closed) it throws [AnyShimException] with
/// [AnyShimStatus.closed], as the native library does for a closed handle.
abstract interface class AnySdk implements OpWaiter {
  /// Starts opening the account (any_shim_account_open_start): the claims
  /// and the lock are taken now (BUSY / REFUSED at once). Returns the op.
  int openAccountStart(Map<String, Object?> options);

  /// Keeps the account an open op answered (`{account}`) for the calls
  /// below. Returns its handle.
  int adoptAccount(Map<String, Object?> openResult);

  /// The open account's handle, or null.
  int? get accountHandle;

  /// Starts the close and forgets the handle; returns the op. With
  /// [waitLoadsMs] > 0 the op first lets space loads in flight finish.
  int closeAccountStart({int waitLoadsMs = 0});

  Map<String, Object?> accountInfo();
  Map<String, Object?> spaceCreate(String name);
  Map<String, Object?> spaceList();
  int spaceListSyncStart(int timeoutMs);
  int spaceResolveStart(String spaceId);
  Map<String, Object?> spaceStatus(String spaceId);
  int syncHeadsStart(String spaceId, int timeoutMs);
  Map<String, Object?> ragBundles(String spaceId, {required bool ensure});
  Map<String, Object?> objectPatch(
    String spaceId,
    Map<String, Object?> target,
    List<Object?> ops,
  );
  void objectSetBody(String spaceId, String objectId, String text);

  /// `{id}` of the object [seed] derives, without a write.
  Map<String, Object?> objectDeriveId(String spaceId, String seed);
  Map<String, Object?> objectRead(String spaceId, Map<String, Object?> request);
  void objectDelete(String spaceId, String objectId);
  Map<String, Object?> objectSyncState(String spaceId, String objectId);
  void recordsModify(
    String spaceId,
    String objectId,
    String collection,
    List<Object?> records,
  );
  Map<String, Object?> recordsRead(
    String spaceId,
    String objectId,
    String collection, {
    String? after,
    int sinceApplySeq = 0,
    int limit = 0,
  });
  Map<String, Object?> changesSince(String spaceId, int since, {int limit = 0});
  int watchChanges(String spaceId);
  int watchSyncStatus();
  void unwatch(int watch);

  /// Runs [job] on the index isolate and returns its result here, so data
  /// read on this isolate reaches the index without crossing the caller's.
  Future<T> toIndex<T>(IndexJob<T> job);
}

/// The index side of one account: its open index files.
abstract interface class AnyIndexHost implements OpWaiter {
  /// any_shim_index_open; returns the handle.
  int open(Map<String, Object?> options);

  /// The index behind [handle]; a closed or unknown handle fails on its
  /// first call with [AnyShimStatus.closed].
  AnyIndexApi index(int handle);
}

/// One open local index (any_shim_index_*), with the get and scan results
/// already normalised: a state entry is its string value, a row its map.
abstract interface class AnyIndexApi {
  /// Starts the close; returns the op ([AnyIndexHost.opWait]).
  int closeStart();

  /// Starts a bind; the op's result is the bound configuration.
  int bindStart(Map<String, Object?> config);

  /// Drops orphan generations within [budgetMs]: `{done}`.
  Map<String, Object?> gc(int budgetMs);
  Map<String, Object?> info();
  Map<String, Object?> apply(Map<String, Object?> ops, Float32List vectors);

  /// A state value of `state` (or `shadowState`), null when absent.
  String? getState(String key, {bool shadow = false});

  /// A row of `docs` (or `shadow`), without its vector; null when absent.
  Map<String, Object?>? getRow(String id, {bool shadow = false});

  /// State entries by key, in key order: `(entries, next)`.
  ({List<(String, String)> entries, String? next}) scanState({
    String? prefix,
    String? after,
    int limit = 0,
    bool shadow = false,
  });

  /// Rows by id, in id order, without their vectors.
  ({List<Map<String, Object?>> rows, String? next}) scanRows({
    String? after,
    int limit = 0,
  });

  int count();
  int countVectors();
  Map<String, Object?> knn(
    Float32List query,
    int k,
    Map<String, Object?>? filter,
  );
  Map<String, Object?> text(String query, int k, Map<String, Object?>? filter);
  void flush(int waitMs);
}

/// One account's runtime: where its jobs run.
abstract interface class AnyRuntime {
  Future<T> sdk<T>(SdkJob<T> job);
  Future<T> index<T>(IndexJob<T> job);

  /// any_shim_account_cancel: stops every SDK call and space load in flight.
  /// Never blocks; runs on the caller's isolate.
  void cancelAccount(int handle);

  /// The account's events (any_shim_events_poll, polled on the events
  /// isolate in slices of at most 250 ms). The stream ends when the account
  /// is closed.
  Stream<Map<String, Object?>> events(int handle);

  /// Ties [handle] to [owner]: if [owner] is collected (a hot restart drops
  /// every isolate) before [detachAccount], the native release runs.
  void attachAccount(Object owner, int handle);
  void detachAccount(Object owner);
  void attachIndex(Object owner, int handle);
  void detachIndex(Object owner);

  /// Stops the isolates. Jobs still queued fail with [StateError].
  Future<void> dispose();
}

/// Creates runtimes, and the process-wide calls that need no account.
abstract interface class AnyNative {
  Future<AnyRuntime> start();
  Future<String> newMnemonic();
  Future<String> newDeviceKey();

  /// Whether this platform has the native library at all (false on the
  /// web).
  bool get supported;
}

/// A random owner token for this isolate group's opens (any_shim.h,
/// ownerToken). A hot restart starts a new group, so a directory still held
/// by the previous one carries another token. Static fields are per
/// isolate; the opens all happen on the SDK and index isolates the caller's
/// isolate spawned, so the caller passes its token along with each open.
String ownerToken() => _ownerToken;
final String _ownerToken = _randomHex(16);

String _randomHex(int bytes) {
  final r = Random.secure();
  return [
    for (var i = 0; i < bytes; i++)
      r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Waits for [op] in slices of at most [sliceMs], yielding to the event
/// loop between slices so other jobs on the same isolate run. Stops (and
/// cancels the op) once [deadline] passes, returning null, or when
/// [cancelled] says so, throwing [AnyShimException] with
/// [AnyShimStatus.closed]. The op's own failure is thrown as its status.
Future<Map<String, Object?>?> awaitOp(
  OpWaiter sdk,
  int op, {
  DateTime? deadline,
  bool Function()? cancelled,
  int sliceMs = 250,
}) async {
  while (true) {
    if (cancelled != null && cancelled()) {
      try {
        sdk.opCancel(op);
      } on AnyShimException {
        // Already finished or released; nothing to stop.
      }
      throw AnyShimException(
        'any_shim_op_wait',
        AnyShimStatus.closed.code,
        'cancelled',
      );
    }
    var wait = sliceMs;
    if (deadline != null) {
      final left = deadline.difference(DateTime.now()).inMilliseconds;
      if (left <= 0) {
        try {
          sdk.opCancel(op);
        } on AnyShimException {
          // Finished in between; its result is discarded either way.
        }
        return null;
      }
      if (left < wait) wait = left;
    }
    final poll = sdk.opWait(op, wait);
    if (poll.done) return poll.result;
    await Future<void>.delayed(Duration.zero);
  }
}

/// Runs [job] against [host]. An index call answering PENDING (a bind or a
/// swap holds the index exclusively and readers are refused at once, not
/// blocked) runs the whole job again after a 250 ms slice, for at most
/// [max]; then the PENDING is thrown. Index jobs commit once at their end,
/// so a refused one changed nothing.
///
/// The worker does not retry by itself: the caller decides how long a
/// job may wait ([pendingRetrying]): reads briefly, writes and pages long.
Future<T> runIndexJob<T>(
  IndexJob<T> job,
  AnyIndexHost host, {
  Duration max = const Duration(minutes: 10),
}) async {
  final end = DateTime.now().add(max);
  while (true) {
    try {
      return await job(host);
    } on AnyShimException catch (e) {
      if (e.status != AnyShimStatus.pending ||
          !e.operation.startsWith('any_shim_index_') ||
          DateTime.now().isAfter(end)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}

/// The event a poller emits once after its first successful poll: it
/// works, even if nothing happens. Not an any_shim.h event.
const Map<String, Object?> pollerReadyEvent = {'kind': 'pollerReady'};

/// [job], retrying index PENDING answers for at most [max].
IndexJob<T> pendingRetrying<T>(IndexJob<T> job, Duration max) =>
    (h) => runIndexJob(job, h, max: max);

/// How long a read waits for a bind or swap, and how long a write or a
/// follower page does (D3-3).
Duration readPendingMax = const Duration(seconds: 10); // a test seam
const writePendingMax = Duration(minutes: 10);

/// Test seam: the first restart delay of the events poller (doubling to
/// 60 s). Not exported.
Duration debugEventsBackoffBase = const Duration(seconds: 1);

/// Debug seam: the native log level ("debug", "info", "warn", "error")
/// accounts are opened with; null keeps the shim's default ("error").
/// Process-wide in the shim, applied by the first open. "debug" also logs
/// the iOS suspend load-wait decision (any_shim: suspend load wait …).
/// Not exported.
String? debugNativeLogLevel;

/// Test seam: a clock skew per data directory (absolute path), in ms, added
/// to the time an account allocates revs with. Not exported.
final Map<String, int> debugAccountClockSkewMs = {};

/// Test seam: when set, AnySyncAccount uses it instead of the FFI runtime.
/// Not exported from the barrel.
AnyNative? debugAnyNativeOverride;
