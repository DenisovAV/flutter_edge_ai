// Minimal Dart web app for the web vec0 gate (driven by tool/verify_web_vec0.mjs).
// Loads the custom sqlite3.wasm (sqlite-vec linked in), creates a vec0 table
// with a TEXT primary key, inserts 3 vectors, runs a KNN MATCH, and logs
// RESULT=PASS iff the nearest-two come back as the expected TEXT ids. This is
// the web-arm twin of test/vec0_text_pk_test.dart.
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'package:sqlite3/wasm.dart';

void _write(String s) {
  web.console.log(s as dynamic);
  final el = web.document.getElementById('out');
  if (el != null) el.textContent = s;
}

Uint8List _f32(List<double> v) {
  final b = ByteData(v.length * 4);
  for (var i = 0; i < v.length; i++) {
    b.setFloat32(i * 4, v[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

Future<void> main() async {
  try {
    final sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
    sqlite3.registerVirtualFileSystem(InMemoryFileSystem(), makeDefault: true);
    final db = sqlite3.open('test');
    final ver = db.select('SELECT vec_version() AS v');
    final buf = StringBuffer('vec_version=${ver.first['v']}\n');
    db.execute(
      'CREATE VIRTUAL TABLE vd USING vec0(id TEXT PRIMARY KEY, embedding float[4])',
    );
    final stmt = db.prepare('INSERT INTO vd(id, embedding) VALUES (?, ?)');
    stmt.execute([
      'alpha',
      _f32([1, 0, 0, 0]),
    ]);
    stmt.execute([
      'beta',
      _f32([0, 1, 0, 0]),
    ]);
    stmt.execute([
      'gamma',
      _f32([0.9, 0.1, 0, 0]),
    ]);
    stmt.close();
    final rows = db.select(
      'SELECT id, distance FROM vd WHERE embedding MATCH ? AND k = 2 ORDER BY distance',
      [
        _f32([1, 0, 0, 0]),
      ],
    );
    buf.write(
      'KNN=${rows.map((r) => '${r['id']}:${r['distance']}').toList()}\n',
    );
    final knnOk = rows.first['id'] == 'alpha' && rows[1]['id'] == 'gamma';

    // --- #2: distance_metric=cosine → similarity = 1 - distance in [0,2] ---
    // A cosine table must report distance 0 for an exact match. (An L2 table
    // would too at unit vectors, so also check an orthogonal pair: cosine
    // distance of [1,0,0,0] vs [0,1,0,0] is 1.0, not sqrt(2).)
    db.execute(
      'CREATE VIRTUAL TABLE vc USING '
      'vec0(id TEXT PRIMARY KEY, embedding float[4] distance_metric=cosine)',
    );
    final cs = db.prepare('INSERT INTO vc(id, embedding) VALUES (?, ?)');
    cs.execute([
      'a',
      _f32([1, 0, 0, 0]),
    ]);
    cs.execute([
      'b',
      _f32([0, 1, 0, 0]),
    ]);
    cs.close();
    final cos = db.select(
      'SELECT id, distance FROM vc WHERE embedding MATCH ? AND k = 2 '
      'ORDER BY distance',
      [
        _f32([1, 0, 0, 0]),
      ],
    );
    final exactDist = cos.first['distance'] as double;
    final orthoDist = cos[1]['distance'] as double;
    final cosineOk = exactDist.abs() < 1e-4 && (orthoDist - 1.0).abs() < 1e-4;
    buf.write('COSINE exact=$exactDist ortho=$orthoDist ok=$cosineOk\n');

    // --- #3: delete-then-insert upsert on a TEXT pk does not throw ---
    var upsertOk = false;
    try {
      db.execute('DELETE FROM vc WHERE id = ?', ['a']);
      db.execute('INSERT INTO vc(id, embedding) VALUES (?, ?)', [
        'a',
        _f32([0.5, 0.5, 0, 0]),
      ]);
      final n = db.select('SELECT count(*) AS c FROM vc').first['c'];
      upsertOk = n == 2; // still 2 rows, 'a' replaced not duplicated
    } catch (_) {
      upsertOk = false;
    }
    buf.write('UPSERT ok=$upsertOk\n');

    buf.write(knnOk && cosineOk && upsertOk ? 'RESULT=PASS' : 'RESULT=FAIL');
    db.close();
    _write(buf.toString());
  } catch (e, st) {
    _write('RESULT=ERROR\n$e\n$st');
  }
}
