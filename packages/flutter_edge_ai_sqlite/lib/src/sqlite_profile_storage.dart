import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:sqlite3/common.dart';

const String sqliteEmbeddingProfileTable = 'flutter_edge_ai_rag_profile';

/// The profile COMMIT succeeded, but the web persistence layer could not
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

EmbeddingProfile? readSqliteEmbeddingProfile(CommonDatabase db) {
  try {
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
    return EmbeddingProfile(id: id, dimension: dimension);
  } on VectorStoreException {
    rethrow;
  } catch (error) {
    throw VectorStoreException(
      'Failed to read the SQLite embedding profile.',
      error,
    );
  }
}

/// Atomically binds one SQLite location to exactly one embedding profile.
///
/// `BEGIN IMMEDIATE` serializes competing writers. The insert never updates an
/// existing row; the read-back supplies the compare-and-set check for both the
/// profile ID and vector dimension.
Future<void> bindSqliteEmbeddingProfile(
  CommonDatabase db,
  EmbeddingProfile profile, {
  Future<void> Function()? durabilityFence,
}) async {
  try {
    db.execute('BEGIN IMMEDIATE');
    db.execute(
      'INSERT INTO $sqliteEmbeddingProfileTable '
      '(singleton, profile_id, dimension) VALUES (1, ?, ?) '
      'ON CONFLICT(singleton) DO NOTHING',
      [profile.id, profile.dimension],
    );
    final stored = readSqliteEmbeddingProfile(db);
    if (stored != profile) {
      throw VectorStoreException(
        'This SQLite vector store is already bound to $stored and cannot be '
        'rebound to $profile. Use a different location.',
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
      'Failed to bind the SQLite embedding profile.',
      error,
    );
  }

  try {
    await durabilityFence?.call();
  } catch (error) {
    throw SqliteProfileDurabilityException(error);
  }
}
