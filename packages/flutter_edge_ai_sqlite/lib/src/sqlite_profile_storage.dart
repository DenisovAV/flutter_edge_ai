import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:sqlite3/common.dart';

/// The version-1 profile record: one row `(profile_id, dimension)`. Every
/// bound location has it, flutter_edge_ai_sqlite 2.0 reads and writes it, and
/// its schema never changes. An image or audio binding stores the qualified
/// id (`VectorStoreBinding.v1RecordId`) here, which a 2.0 reader cannot match.
const String sqliteEmbeddingProfileTable = 'flutter_edge_ai_rag_profile';

/// The version-2 binding record: one row `(profile_id, dimension, documents)`
/// with the UNqualified profile id. Created only by an image or audio bind,
/// inside that bind's transaction, so a text location never has the table.
const String sqliteBindingV2Table = 'flutter_edge_ai_rag_binding_v2';

/// The binding COMMIT succeeded, but the web persistence layer could not
/// confirm that the committed bytes reached durable storage.
final class SqliteProfileDurabilityException extends VectorStoreException {
  const SqliteProfileDurabilityException(Object cause)
    : super(
        'The SQLite embedding profile was committed but could not be made '
        'durable.',
        cause,
      );
}

void ensureSqliteEmbeddingProfileTable(CommonDatabase db) {
  db.execute('''
CREATE TABLE IF NOT EXISTS $sqliteEmbeddingProfileTable (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  profile_id TEXT NOT NULL,
  dimension INTEGER NOT NULL CHECK (dimension > 0)
)
''');
}

/// Reads the location's binding (the reader truth table documented on
/// [VectorStoreBinding]); null for a never-bound location.
///
/// Both records are written in one transaction, so a qualified version-1 id
/// without its version-2 record is corruption here, not an interrupted bind.
VectorStoreBinding? readSqliteBinding(CommonDatabase db) {
  try {
    final v1 = _readV1(db);
    final v2 = _readV2(db);
    if (v1 == null) {
      if (v2 != null) {
        throw const VectorStoreException(
          'The SQLite vector-store binding is corrupt: a version-2 binding '
          'record exists without the version-1 profile record.',
        );
      }
      return null;
    }
    final binding = VectorStoreBinding.fromV1Record(
      id: v1.id,
      dimension: v1.dimension,
    );
    if (binding.documents == EmbeddingModality.text) {
      if (v2 != null) {
        throw VectorStoreException(
          'The SQLite vector-store binding is corrupt: the profile record '
          'binds ${binding.profile} to text documents, but a version-2 '
          'binding record names ${v2.documents} documents.',
        );
      }
      return binding;
    }
    if (v2 == null) {
      throw VectorStoreException(
        'The SQLite vector-store binding is corrupt: the profile record binds '
        '${binding.profile} to ${binding.documents.name} documents, but the '
        'version-2 binding record is missing.',
      );
    }
    if (v2.id != binding.profile.id ||
        v2.dimension != binding.profile.dimension ||
        v2.documents != binding.documents.name) {
      throw VectorStoreException(
        'The SQLite vector-store binding is corrupt: the profile record says '
        '$binding, the version-2 binding record says '
        '(${v2.id}, ${v2.dimension}D, ${v2.documents}).',
      );
    }
    return binding;
  } on VectorStoreException {
    rethrow;
  } catch (error) {
    throw VectorStoreException(
      'Failed to read the SQLite vector-store binding.',
      error,
    );
  }
}

/// Atomically binds one SQLite location to exactly one [binding].
///
/// `BEGIN IMMEDIATE` serializes competing writers, including writers of
/// flutter_edge_ai_sqlite 2.0, which run the same version-1 insert. The
/// inserts never update an existing row; the read-back inside the transaction
/// is the compare-and-set check for the profile id, the dimension and the
/// document modality. Every bound location has a version-1 row, so an older
/// writer's insert is a no-op and its read-back refuses a qualified id,
/// whichever of the two runs first — no trigger is needed.
Future<void> bindSqliteBinding(
  CommonDatabase db,
  VectorStoreBinding binding, {
  Future<void> Function()? durabilityFence,
}) async {
  try {
    db.execute('BEGIN IMMEDIATE');
    db.execute(
      'INSERT INTO $sqliteEmbeddingProfileTable '
      '(singleton, profile_id, dimension) VALUES (1, ?, ?) '
      'ON CONFLICT(singleton) DO NOTHING',
      [binding.v1RecordId, binding.profile.dimension],
    );
    final v1 = _readV1(db);
    final ownsV1 =
        v1 != null &&
        v1.id == binding.v1RecordId &&
        v1.dimension == binding.profile.dimension;
    if (ownsV1 && binding.documents != EmbeddingModality.text) {
      db.execute('''
CREATE TABLE IF NOT EXISTS $sqliteBindingV2Table (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  profile_id TEXT NOT NULL,
  dimension INTEGER NOT NULL CHECK (dimension > 0),
  documents TEXT NOT NULL
)
''');
      db.execute(
        'INSERT INTO $sqliteBindingV2Table '
        '(singleton, profile_id, dimension, documents) VALUES (1, ?, ?, ?) '
        'ON CONFLICT(singleton) DO NOTHING',
        [binding.profile.id, binding.profile.dimension, binding.documents.name],
      );
    }
    final stored = readSqliteBinding(db);
    if (stored != binding) {
      throw VectorStoreException(
        'This SQLite vector store is already bound to $stored and cannot be '
        'rebound to $binding. Use a different location.',
      );
    }
    db.execute('COMMIT');
  } catch (error) {
    if (!db.autocommit) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {
        // Preserve the binding failure; rollback is best-effort cleanup.
      }
    }
    if (error is VectorStoreException) rethrow;
    throw VectorStoreException(
      'Failed to bind the SQLite vector-store binding.',
      error,
    );
  }

  try {
    await durabilityFence?.call();
  } catch (error) {
    throw SqliteProfileDurabilityException(error);
  }
}

({String id, int dimension})? _readV1(CommonDatabase db) {
  final rows = db.select(
    'SELECT singleton, profile_id, dimension '
    'FROM $sqliteEmbeddingProfileTable',
  );
  if (rows.isEmpty) return null;
  if (rows.length != 1 || rows.first['singleton'] != 1) {
    throw const VectorStoreException(
      'The SQLite embedding-profile table is corrupt: expected one '
      'singleton row.',
    );
  }
  final id = rows.first['profile_id'];
  final dimension = rows.first['dimension'];
  if (id is! String || dimension is! int) {
    throw const VectorStoreException(
      'The SQLite embedding-profile table contains invalid value types.',
    );
  }
  return (id: id, dimension: dimension);
}

({String id, int dimension, String documents})? _readV2(CommonDatabase db) {
  final tables = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [sqliteBindingV2Table],
  );
  if (tables.isEmpty) return null;
  final rows = db.select(
    'SELECT singleton, profile_id, dimension, documents '
    'FROM $sqliteBindingV2Table',
  );
  if (rows.isEmpty) return null;
  if (rows.length != 1 || rows.first['singleton'] != 1) {
    throw const VectorStoreException(
      'The SQLite version-2 binding table is corrupt: expected one singleton '
      'row.',
    );
  }
  final id = rows.first['profile_id'];
  final dimension = rows.first['dimension'];
  final documents = rows.first['documents'];
  if (id is! String || dimension is! int || documents is! String) {
    throw const VectorStoreException(
      'The SQLite version-2 binding table contains invalid value types.',
    );
  }
  return (id: id, dimension: dimension, documents: documents);
}
