import 'package:uuid/uuid.dart';

/// Deterministically maps an arbitrary user-supplied String ID to a
/// qdrant-edge `PointId::Uuid`.
///
/// qdrant-edge stores points keyed by `PointId`, which is either a `u64`
/// integer or a UUID — arbitrary Strings are not accepted. flutter_gemma's
/// public RAG API has always exposed `String id` (e.g. `"doc_42"`,
/// `"section-3-paragraph-7"`), so we need a stable surjection from String
/// to UUID at the storage boundary.
///
/// We use UUIDv5 (RFC 4122) under a fixed namespace, which guarantees:
///
///   * **Determinism**: same input String → same UUID, always, across
///     processes and machines. Reopening a shard finds the same points.
///   * **No collisions in practice**: the SHA-1 → 128-bit space makes
///     accidental collisions astronomically unlikely for any realistic
///     RAG corpus (~10^36 IDs before the birthday bound at 50%).
///   * **Forward compatibility**: if a future release adds Qdrant Cloud
///     sync, the same namespace produces matching IDs server-side.
///
/// The namespace UUID was chosen from RFC 4122 Appendix C (Namespace IDs
/// for Naming Service Authorities) — it is the well-known "DNS namespace"
/// constant used by the same approach in many other databases. We never
/// change it; doing so would orphan all existing shards.
class PointIdHasher {
  /// RFC 4122 "DNS" namespace UUID.
  static const String _namespace = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

  static const Uuid _uuid = Uuid();

  /// Returns the UUIDv5 string for [userId] under the fixed namespace.
  ///
  /// Always returns canonical lowercase form (e.g.
  /// `cfbff0d1-9375-5685-968a-48ce8b50e3ad`). The result is suitable for
  /// passing as the `id` argument to `qe_shard_upsert`,
  /// `qe_shard_delete`, etc.
  static String hash(String userId) {
    assert(userId.isNotEmpty, 'PointIdHasher: userId must not be empty');
    return _uuid.v5(_namespace, userId);
  }
}
