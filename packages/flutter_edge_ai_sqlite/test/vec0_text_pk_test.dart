// Load-bearing facts for the single-engine vec0 store. Both must hold or the
// "TEXT primary key, no JOIN, no rowid bridge" design is wrong:
//   (a) the bundled sqlite3 (Native Assets) can load the prebuilt vec0 extension
//       via the static-entrypoint path (NOT runtime `SELECT load_extension`,
//       which sqlite3_flutter_libs omits for security);
//   (b) a vec0 virtual table with `id TEXT PRIMARY KEY` round-trips: insert,
//       KNN MATCH, and the TEXT id comes back from the query directly.
//
// This is the native half of the migration's keystone proof (the web half is
// tool/verify_web_vec0.mjs). Keep it green — it gates the design, not a feature.
//
// The loadable extension comes from this repo's own
// native/sqlite_vec/prebuilt/<platform>/ (see test/vec0_locator.dart);
// $VEC0_DYLIB overrides it. It used to default to /tmp/vec0_poc/vec0.dylib —
// a path from the migration proof-of-concept that nothing creates — so this
// "keep it green" test was red wherever nobody had hand-downloaded a copy.
// Run from the package dir:
//   flutter test test/vec0_text_pk_test.dart
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vec0_locator.dart';

void main() {
  test('vec0 loads + TEXT PRIMARY KEY + KNN returns the text id', () {
    final resolved = vec0Path;
    expect(resolved, isNotNull, reason: vec0SkipReason);
    final vec0Lib = resolved!;

    // (a) Static-entrypoint load (the path sqlite3_flutter_libs supports — NOT
    // runtime SELECT load_extension, which the bundled libs omit). Register the
    // extension's init symbol BEFORE opening any database.
    final lib = DynamicLibrary.open(vec0Lib);
    sqlite3.ensureExtensionLoaded(
      SqliteExtension.inLibrary(lib, 'sqlite3_vec_init'),
    );

    final db = sqlite3.openInMemory();
    try {
      // sanity: vec0 registered
      final ver = db.select('SELECT vec_version() AS v');
      // ignore: avoid_print
      print('[vec0] vec_version = ${ver.first['v']}');

      // (b) TEXT PRIMARY KEY vec0 table.
      db.execute('''
        CREATE VIRTUAL TABLE vec_documents USING vec0(
          id TEXT PRIMARY KEY,
          embedding float[4]
        );
      ''');

      // insert 3 docs with TEXT ids + float32 embeddings
      final stmt = db.prepare(
        'INSERT INTO vec_documents(id, embedding) VALUES (?, ?)',
      );
      stmt.execute([
        'doc-alpha',
        _f32([1.0, 0.0, 0.0, 0.0]),
      ]);
      stmt.execute([
        'doc-beta',
        _f32([0.0, 1.0, 0.0, 0.0]),
      ]);
      stmt.execute([
        'doc-gamma',
        _f32([0.9, 0.1, 0.0, 0.0]),
      ]);
      stmt.close();

      // KNN: query closest to [1,0,0,0] → expect doc-alpha then doc-gamma.
      final rows = db.select(
        '''
        SELECT id, distance
        FROM vec_documents
        WHERE embedding MATCH ? AND k = 2
        ORDER BY distance
        ''',
        [
          _f32([1.0, 0.0, 0.0, 0.0]),
        ],
      );

      // ignore: avoid_print
      print(
        '[vec0] KNN rows: ${rows.map((r) => '${r['id']}:${r['distance']}').toList()}',
      );

      // THE assertions: TEXT ids come back, ordered by distance, no JOIN.
      expect(rows.length, 2);
      expect(rows.first['id'], 'doc-alpha'); // exact match, distance 0
      expect(rows[1]['id'], 'doc-gamma'); // nearest after
      expect(rows.first['id'], isA<String>()); // it's the TEXT id, not an int
    } finally {
      db.close();
    }
  });
}

/// float32 little-endian BLOB (same encoding the real store uses).
List<int> _f32(List<double> v) {
  final bytes = ByteData(v.length * 4);
  for (var i = 0; i < v.length; i++) {
    bytes.setFloat32(i * 4, v[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}
