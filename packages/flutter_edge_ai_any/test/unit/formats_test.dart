// The synced formats of design §2 (Formats) and AnySyncLocation.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/logic/formats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnySyncLocation', () {
    test('canonical round trip', () {
      final l = AnySyncLocation(
        spaceId: 'bafyreiabc.2x3',
        indexName: 'a.b_c-1',
      );
      expect(l.value, 'any:bafyreiabc.2x3/a.b_c-1');
      expect(AnySyncLocation.parse(l.value), l);
    });

    test('anything else is refused, never normalised', () {
      for (final v in [
        'any:space/',
        'any:/idx',
        'ANY:space/idx',
        'any:space/Idx',
        'any:space/idx/more',
        'any:spa ce/idx',
        'any:space/${'x' * 65}',
        'sqlite:space/idx',
      ]) {
        expect(
          () => AnySyncLocation.parse(v),
          throwsFormatException,
          reason: v,
        );
      }
      expect(
        () => AnySyncLocation(spaceId: 's', indexName: 'UPPER'),
        throwsArgumentError,
      );
    });
  });

  test('leaf keys are full hashes of [0-9a-z-]', () {
    final f = fieldLeafKey('a.b*', 'string');
    expect(f, matches(RegExp(r'^[0-9a-f]{64}-string$')));
    expect(f, isNot(fieldLeafKey('a.b*', 'number')));
    final h = profileLeafKey('p\u001Fimage', 768);
    expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(h, sha256Hex('p\u001Fimage\n768'));
    expect(h, isNot(profileLeafKey('p\u001Fimage', 384)));
  });

  test('doc: every format a reader can meet', () {
    String doc(Map<String, Object?> m) => jsonEncode(m);
    final ok = DocValue.parse(
      DocValue.encode(
        loc: 'n',
        key: 'k',
        rev: 5,
        mod: 'text',
        content: 'c',
        meta: null,
      ),
    );
    expect(ok.kind, DocKind.ok);
    expect(ok.content, 'c');
    expect(
      DocValue.parse(doc({'fmt': 2, 'loc': 'n', 'key': 'k', 'rev': 5})).kind,
      DocKind.newerFormat,
    );
    expect(
      DocValue.parse(
        doc({
          'fmt': 1,
          'loc': 'n',
          'key': 'k',
          'rev': maxRev + 1,
          'mod': 'text',
          'content': '',
        }),
      ).kind,
      DocKind.revOutOfRange,
    );
    expect(DocValue.parse('not json').kind, DocKind.malformed);
    expect(DocValue.parse(doc({'fmt': 1, 'loc': 'n'})).kind, DocKind.malformed);
    expect(revInRange(maxRev), isTrue);
    expect(revInRange(0), isFalse);
    expect(maxRev, (1 << 53) - 2);
  });

  test('vectors: f32le-b64 round trip; bad input is badVector', () {
    final v = Float32List.fromList([1.5, -2, 0, 3.25]);
    final leaf = LeafValue.encode(v, 'ch');
    final back = LeafValue.parse(leaf, 4);
    expect(back.kind, LeafKind.ok);
    expect(back.vector, v);
    expect(LeafValue.parse(leaf, 3).kind, LeafKind.wrongDimension);
    expect(
      LeafValue.parse({...leaf, 'vec': 'AAAA'}, 4).kind,
      LeafKind.badVector,
    );
    expect(LeafValue.parse({...leaf, 'fmt': 9}, 4).kind, LeafKind.newerFormat);
    expect(LeafValue.parse(null, 4).kind, LeafKind.missing);
    final nan = Float32List.fromList([double.nan, 0, 0, 0]);
    expect(decodeVector(encodeVector(nan), 4), isNull);
  });

  test('tombstone records: id must be sha256(key); clear is reserved', () {
    final good = TombRecord.parse({
      'id': sha256Hex('k'),
      'key': 'k',
      'revs': [3, 9, 0],
    });
    expect(good.valid, isTrue);
    expect(good.maxRev, 9);
    expect(
      TombRecord.parse({
        'id': 'x' * 64,
        'key': 'k',
        'revs': [3],
      }).valid,
      isFalse,
    );
    expect(
      TombRecord.parse({
        'id': 'clear',
        'revs': [4],
      }).isClear,
      isTrue,
    );
  });
}
