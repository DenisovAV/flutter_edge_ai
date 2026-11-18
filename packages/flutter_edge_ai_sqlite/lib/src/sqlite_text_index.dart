import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:sqlite3/common.dart';

import 'package:flutter_edge_ai_sqlite/src/filter_to_vec0.dart';
import 'package:flutter_edge_ai_sqlite/src/sqlite_log.dart';
import 'package:flutter_edge_ai_sqlite/src/sqlite_text_tokenizer.dart';

/// The text index of one SQLite location, shared by the native and the web
/// store: a canonical text table plus an FTS5 index over it.
///
/// ```sql
/// rag_text_documents(_rag_rowid INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
///                    content TEXT NOT NULL, metadata TEXT, <filter fields>)
/// rag_text_fts USING fts5(content, content='rag_text_documents',
///                         content_rowid='_rag_rowid', tokenize='…')
/// ```
///
/// vec0 stays the source of the vectors and of every document; this index is
/// derived from it. The text table holds each document's id, content and raw
/// metadata, plus one column per declared filter field, typed as in vec0
/// (TEXT, REAL, INTEGER) and written from the same
/// [FilterToVec0.declaredColumnValues], so a filter means the same in both
/// legs. FTS5 is external-content: the text is stored once, in the text table.
///
/// `_rag_rowid` starts with an underscore, which no filter field name can
/// ([FilterToVec0.namePattern]), so it never collides with one.
///
/// Every write is the caller's to wrap in a transaction together with the
/// vec0 write ([runInTransaction]); [open] reconciles the index with vec0, so
/// writes made by a release without text search (which update vec0 only) are
/// picked up on the next open.
final class SqliteTextIndex {
  SqliteTextIndex._(this._db, this._schema, this.tokenizer);

  static const String documentsTable = 'rag_text_documents';
  static const String ftsTable = 'rag_text_fts';
  static const String rowidColumn = '_rag_rowid';

  /// The vec0 table this index mirrors.
  static const String vecTable = 'vec_documents';

  final CommonDatabase _db;
  final FilterSchema _schema;

  /// The FTS5 `tokenize` argument this location's index was created with.
  final String tokenizer;

  /// Opens this location's text index, or returns null when it has none and
  /// [enable] is false.
  ///
  /// Creates the index when [enable] is set and it is missing, and recreates
  /// it when its stored schema differs from [schema]. Then reconciles it with
  /// vec0 (`id`, `content`, `metadata`): rows vec0 has that the index lacks or
  /// holds differently are rewritten, rows vec0 no longer has are deleted. All
  /// in one transaction.
  ///
  /// Throws [VectorStoreException] when this SQLite build has no FTS5, and
  /// when [requestedTokenizer] differs from the one the index was created
  /// with.
  static SqliteTextIndex? open(
    CommonDatabase db, {
    required bool enable,
    required FilterSchema schema,
    SqliteTextTokenizer? requestedTokenizer,
  }) {
    final storedFts = _tableSql(db, ftsTable);
    final storedDocuments = _tableSql(db, documentsTable);
    final exists = storedFts != null || storedDocuments != null;
    if (!exists && !enable) return null;

    _requireFts5(db);

    final storedTokenizer = storedFts == null
        ? null
        : RegExp(r"tokenize='([^']*)'").firstMatch(storedFts)?.group(1);
    if (storedTokenizer != null &&
        requestedTokenizer != null &&
        storedTokenizer != requestedTokenizer.fts5) {
      throw VectorStoreException(
        'This location\'s text index was created with the FTS5 tokenizer '
        '"$storedTokenizer", not "${requestedTokenizer.fts5}". A tokenizer is '
        'fixed when the index is created: open it with the same '
        'SqliteTextTokenizer, or leave textTokenizer null to use the stored '
        'one.',
      );
    }
    final tokenizer =
        storedTokenizer ??
        requestedTokenizer?.fts5 ??
        SqliteTextTokenizer.unicode61.fts5;

    final index = SqliteTextIndex._(db, schema, tokenizer);
    runInTransaction(db, () {
      final documentsSql = index._documentsDdl();
      final ftsSql = index._ftsDdl();
      final rebuild = storedDocuments != documentsSql || storedFts != ftsSql;
      if (rebuild) {
        if (exists) {
          sqliteLog(
            '[SqliteTextIndex] the stored text index does not match this '
            'schema; rebuilding it from vec_documents',
          );
        }
        db.execute('DROP TABLE IF EXISTS $ftsTable');
        db.execute('DROP TABLE IF EXISTS $documentsTable');
        db.execute(documentsSql);
        db.execute(ftsSql);
      }
      final repaired = index._reconcile();
      if (repaired > 0 && !rebuild) {
        sqliteLog(
          '[SqliteTextIndex] reconciled $repaired document(s) that were '
          'written without the text index',
        );
      }
    });
    return index;
  }

  /// Runs [body] in `BEGIN IMMEDIATE … COMMIT`, rolling back on any error.
  /// Inside an open transaction, runs [body] as part of it.
  static T runInTransaction<T>(CommonDatabase db, T Function() body) {
    if (!db.autocommit) return body();
    db.execute('BEGIN IMMEDIATE');
    final T result;
    try {
      result = body();
    } catch (_) {
      try {
        db.execute('ROLLBACK');
      } catch (rollbackError) {
        sqliteLog('[SqliteTextIndex] ROLLBACK failed: $rollbackError');
      }
      rethrow;
    }
    db.execute('COMMIT');
    return result;
  }

  /// Writes [id] into the index, replacing any previous row for it.
  void upsert({required String id, required String content, String? metadata}) {
    delete(id);
    final values = FilterToVec0.declaredColumnValues(metadata, _schema);
    final columns = <String>['id', 'content', 'metadata'];
    final placeholders = <String>['?', '?', '?'];
    final binds = <Object?>[id, content, metadata];
    for (final field in _schema.fields) {
      columns.add(FilterToVec0.quoteColumn(field.name));
      final value = values[field.name];
      if (field.type == FilterFieldType.number) {
        // As in the web store's vec0 insert: a non-finite value is the
        // absent-number sentinel and goes in as a literal (binding -Infinity
        // throws on the web), and a finite one is CAST because dart2js cannot
        // tell 10.0 from 10.
        if (value is num && !value.isFinite) {
          placeholders.add(FilterToVec0.absentNumberSql);
          continue;
        }
        placeholders.add('CAST(? AS REAL)');
      } else {
        placeholders.add('?');
      }
      binds.add(value);
    }
    _db.execute(
      'INSERT INTO $documentsTable (${columns.join(', ')}) '
      'VALUES (${placeholders.join(', ')})',
      binds,
    );
    _db.execute('INSERT INTO $ftsTable (rowid, content) VALUES (?, ?)', [
      _db.lastInsertRowId,
      content,
    ]);
  }

  /// Removes [id] from the index; no-op when it is absent.
  void delete(String id) {
    // External content: FTS5 removes a row's terms only when told the exact
    // values it indexed, so read them from the text table first.
    _db.execute(
      "INSERT INTO $ftsTable ($ftsTable, rowid, content) "
      "SELECT 'delete', $rowidColumn, content FROM $documentsTable "
      'WHERE id = ?',
      [id],
    );
    _db.execute('DELETE FROM $documentsTable WHERE id = ?', [id]);
  }

  /// Removes every document from the index.
  void clear() {
    _db.execute("INSERT INTO $ftsTable ($ftsTable) VALUES ('delete-all')");
    _db.execute('DELETE FROM $documentsTable');
  }

  /// The documents matching any term of [text], best first, at most [topK].
  List<TextSearchResult> search({
    required String text,
    required int topK,
    Filter? filter,
  }) {
    final match = ftsQuery(text);
    if (match == null) return const [];
    final translated = FilterToVec0.translate(filter, _schema);
    if (translated.matchesNothing) return const [];
    // The filter runs in a subquery over the text table alone, so its
    // unqualified column names cannot meet FTS5's hidden columns.
    final whereFilter = translated.whereSql.isEmpty
        ? ''
        : ' AND d.$rowidColumn IN (SELECT $rowidColumn FROM $documentsTable '
              'WHERE ${translated.whereSql})';
    final rows = _db.select(
      'SELECT d.id AS id, d.content AS content, d.metadata AS metadata, '
      'bm25($ftsTable) AS score '
      'FROM $ftsTable JOIN $documentsTable d '
      'ON d.$rowidColumn = $ftsTable.rowid '
      'WHERE $ftsTable MATCH ?$whereFilter '
      'ORDER BY score, d.id LIMIT ?',
      [match, ...translated.binds, topK],
    );
    return [
      for (final row in rows)
        TextSearchResult(
          id: row['id'] as String,
          content: row['content'] as String,
          metadata: row['metadata'] as String?,
          // bm25() is lower-is-better; relevanceScore is higher-is-better.
          relevanceScore: -(row['score'] as num).toDouble(),
        ),
    ];
  }

  /// [text] as an FTS5 query: every whitespace-separated term as a quoted
  /// string (`"` doubled), joined with `OR`, so user input never reaches FTS5
  /// syntax. Null when [text] has no term.
  static String? ftsQuery(String text) {
    final terms = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    if (terms.isEmpty) return null;
    return terms.map((t) => '"${t.replaceAll('"', '""')}"').join(' OR ');
  }

  /// Rewrites the rows that differ from vec0 and deletes the ones vec0 no
  /// longer has; returns how many rows changed.
  int _reconcile() {
    if (_tableSql(_db, vecTable) == null) {
      // No vec0 table: nothing was ever added, or a release without text
      // search cleared the store (clear() drops the table).
      final count =
          _db.select('SELECT COUNT(*) AS c FROM $documentsTable').first['c']
              as int;
      if (count > 0) clear();
      return count;
    }
    final drifted = _db.select(
      'SELECT v.id AS id, v.content AS content, v.metadata AS metadata '
      'FROM $vecTable v LEFT JOIN $documentsTable t ON t.id = v.id '
      'WHERE t.id IS NULL OR t.content IS NOT coalesce(v.content, \'\') '
      'OR t.metadata IS NOT v.metadata',
    );
    final orphans = _db.select(
      'SELECT id FROM $documentsTable '
      'WHERE id NOT IN (SELECT id FROM $vecTable)',
    );
    for (final row in orphans) {
      delete(row['id'] as String);
    }
    for (final row in drifted) {
      upsert(
        id: row['id'] as String,
        content: row['content'] as String? ?? '',
        metadata: row['metadata'] as String?,
      );
    }
    return drifted.length + orphans.length;
  }

  String _documentsDdl() {
    final columns = <String>[
      '$rowidColumn INTEGER PRIMARY KEY',
      'id TEXT NOT NULL UNIQUE',
      'content TEXT NOT NULL',
      'metadata TEXT',
      for (final field in _schema.fields)
        '${FilterToVec0.quoteColumn(field.name)} ${switch (field.type) {
          FilterFieldType.string => 'TEXT',
          FilterFieldType.number => 'REAL',
          FilterFieldType.bool => 'INTEGER',
        }}',
    ];
    return 'CREATE TABLE $documentsTable(${columns.join(', ')})';
  }

  String _ftsDdl() =>
      'CREATE VIRTUAL TABLE $ftsTable USING fts5(content, '
      "content='$documentsTable', content_rowid='$rowidColumn', "
      "tokenize='$tokenizer')";

  static String? _tableSql(CommonDatabase db, String name) {
    final rows = db.select(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
      [name],
    );
    return rows.isEmpty ? null : rows.first['sql'] as String?;
  }

  static void _requireFts5(CommonDatabase db) {
    try {
      db.execute('CREATE VIRTUAL TABLE temp.rag_text_fts5_probe USING fts5(x)');
      db.execute('DROP TABLE temp.rag_text_fts5_probe');
    } on SqliteException catch (error) {
      throw VectorStoreException(
        'This SQLite build has no FTS5, which text search needs. The '
        'package:sqlite3 default binaries and this package\'s web '
        'sqlite3.wasm include it; a `hooks: user_defines: sqlite3: source:` '
        'build (system SQLite, SQLCipher) may not.',
        error,
      );
    }
  }
}
