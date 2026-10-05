import 'package:flutter_gemma_rag_qdrant/src/point_id_hasher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PointIdHasher', () {
    test('is deterministic — same input maps to same UUID', () {
      expect(
        PointIdHasher.hash('doc_42'),
        equals(PointIdHasher.hash('doc_42')),
      );
      expect(
        PointIdHasher.hash('the quick brown fox'),
        equals(PointIdHasher.hash('the quick brown fox')),
      );
    });

    test('different inputs produce different UUIDs', () {
      expect(
        PointIdHasher.hash('doc_42'),
        isNot(equals(PointIdHasher.hash('doc_43'))),
      );
      expect(PointIdHasher.hash('a'), isNot(equals(PointIdHasher.hash('b'))));
    });

    test('output is a canonical lowercase UUIDv5 string', () {
      // RFC 4122: 8-4-4-4-12 hex chars, version nibble = 5, variant nibble in {8,9,a,b}.
      final uuid = PointIdHasher.hash('doc_42');
      final re = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(re.hasMatch(uuid), isTrue, reason: 'got: $uuid');
    });

    test('empty string throws AssertionError in debug mode', () {
      // M11: PointIdHasher.hash asserts userId.isNotEmpty to catch callers
      // that pass an uninitialised / default-constructed ID before it silently
      // produces a UUID that maps to a real qdrant point.
      expect(() => PointIdHasher.hash(''), throwsA(isA<AssertionError>()));
    });

    test('unicode strings hash without errors', () {
      final uuid1 = PointIdHasher.hash('Привет, мир!');
      final uuid2 = PointIdHasher.hash('你好世界');
      final uuid3 = PointIdHasher.hash('emoji 🦀');
      expect(uuid1.length, equals(36));
      expect(uuid2.length, equals(36));
      expect(uuid3.length, equals(36));
      expect(
        {uuid1, uuid2, uuid3}.length,
        equals(3),
        reason: 'all three must produce distinct UUIDs',
      );
    });

    test('namespace constant is RFC 4122 DNS — locks the hash space', () {
      // If anyone changes the namespace in PointIdHasher, every existing
      // shard becomes orphaned. This test pins the hash for a known input
      // computed against the locked namespace so accidental changes are
      // caught in CI before they reach production.
      //
      // Computed via `uuid` package v5 with namespace
      // 6ba7b810-9dad-11d1-80b4-00c04fd430c8 and name "flutter_gemma".
      expect(
        PointIdHasher.hash('flutter_gemma'),
        equals('7911b3a2-96cc-561e-bb23-faaa00421558'),
      );
    });
  });
}
