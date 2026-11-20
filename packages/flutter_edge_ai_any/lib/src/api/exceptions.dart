part of 'any_sync.dart';

/// The base of every error this package raises. rag rethrows store errors
/// unchanged, so an app catches these through `RagIndex` too.
@experimental
class AnySyncException extends VectorStoreException {
  const AnySyncException(
    String message, {
    required this.retryable,
    Object? cause,
  }) : super(message, cause);

  /// Whether the same call may succeed later (after `resume()`, after the
  /// space loaded, after a peer sync, ...).
  final bool retryable;

  @override
  String toString() =>
      '$runtimeType: $message${cause != null ? '\nCause: $cause' : ''}';
}

/// The call needs the SDK and the account is suspended, or `suspend()`
/// cancelled it. Retry after `resume()`; copy-on-write makes that safe.
@experimental
final class AnySyncSuspendedException extends AnySyncException {
  const AnySyncSuspendedException._([String? detail])
    : super(
        'The account is suspended${detail == null ? '' : ': $detail'}. '
        'Call resume() first.',
        retryable: true,
      );
}

@experimental
enum AnySyncNotReadyReason {
  /// The space is not known to this account yet: `spaces(sync: true)`.
  unknownSpace,

  /// Known, still loading.
  loading,

  /// The location's manifest has not arrived and cannot be published yet.
  manifestNotSynced,

  /// A new local file: writes wait for its first full pull.
  firstPullPending,

  /// The RAG bundle definitions have not synced to this device.
  definitionsNotSynced,
}

/// Retryable: the space or location is not ready for this call yet.
@experimental
final class AnySyncNotReadyException extends AnySyncException {
  AnySyncNotReadyException._(this.spaceId, this.reason, [String? detail])
    : super(
        'Space $spaceId is not ready: ${reason.name}'
        '${detail == null ? '' : ' ($detail)'}.',
        retryable: true,
      );

  final String spaceId;
  final AnySyncNotReadyReason reason;
}

@experimental
enum AnySyncBusyReason {
  /// This process already has the account, or the location's store, open.
  alreadyOpenInProcess,

  /// Another process holds the directory's lock.
  lockedByAnotherProcess,

  /// A previous instance (a hot restart) still holds or closes it.
  previousInstanceClosing,
}

/// The directory or the location is held by someone else.
@experimental
final class AnySyncBusyException extends AnySyncException {
  AnySyncBusyException._(this.reason, String detail, {super.cause})
    : super(
        'Busy (${reason.name}): $detail',
        retryable: reason != AnySyncBusyReason.alreadyOpenInProcess,
      );

  final AnySyncBusyReason reason;
}

/// The account was closed.
@experimental
final class AnySyncClosedException extends AnySyncException {
  const AnySyncClosedException._()
    : super('The account is closed.', retryable: false);
}

/// The location's manifest disagrees with this binding: another modality, a
/// field with two types, or a profile with two dimensions. Use a different
/// location.
@experimental
final class AnySyncConflictException extends AnySyncException {
  AnySyncConflictException._(
    this.manifest,
    this.conflictingDocuments,
    this.reasons,
  ) : super(
        'The location is bound differently by another device '
        '(${reasons.join(', ')}). Use a different location.',
        retryable: false,
      );

  final AnySyncManifest? manifest;
  final int conflictingDocuments;
  final List<String> reasons;
}

/// This account may not write to the space (a reader).
@experimental
final class AnySyncReadOnlyException extends AnySyncException {
  const AnySyncReadOnlyException._(String detail)
    : super('Read-only: $detail', retryable: false);
}

/// The space write committed but the local apply failed. The follower
/// applies it later; never retry the write.
@experimental
final class AnySyncCommittedException extends AnySyncException {
  AnySyncCommittedException._(this.key, this.rev, this.objectId, Object cause)
    : super(
        'The write of "$key" (rev ${rev ?? '-'}, object $objectId) committed '
        'to the '
        'space, but the local index did not take it; the follower applies '
        'it later. Do not retry the write.',
        retryable: false,
        cause: cause,
      );

  final String key;

  /// The rev written; null for a vector-leaf write, which takes none.
  final int? rev;

  /// The object written: the new document object, or for a remove or clear
  /// the manifest object the tombstone record lives on.
  final String objectId;
}

/// A rev would pass 2^53 − 2.
@experimental
final class AnySyncClockExhaustedException extends AnySyncException {
  const AnySyncClockExhaustedException._()
    : super('The location clock is exhausted (2^53 - 2).', retryable: false);
}

@experimental
enum AnySyncLocalIndexErrorKind {
  /// Written with another key, or with none. Not retryable.
  keyMismatch,

  /// Damaged. Not retryable; the index directory is derived data and may be
  /// deleted.
  corrupt,

  /// Needs its key and none was given (iOS before the first unlock).
  keyMissing,

  /// The file system refused (permission, disk full).
  io,
}

/// The location's local index file cannot be used.
@experimental
final class AnySyncLocalIndexException extends AnySyncException {
  AnySyncLocalIndexException._(this.kind, String detail)
    : super(
        'Local index: ${kind.name}: $detail',
        retryable:
            kind == AnySyncLocalIndexErrorKind.keyMissing ||
            kind == AnySyncLocalIndexErrorKind.io,
      );

  final AnySyncLocalIndexErrorKind kind;
}
