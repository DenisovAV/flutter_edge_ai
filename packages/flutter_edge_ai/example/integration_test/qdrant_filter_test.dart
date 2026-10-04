// Full Filter DSL coverage against the real qdrant backend on macOS.
//
// Existing qdrant_client_smoke_test covers the FFI path end-to-end;
// this one exercises every Filter variant (FieldEquals / FieldRange /
// FieldMatchAny) in every bucket (must / should / mustNot) through the
// QdrantEdgeClient directly. Run on macOS:
//
//   cd example && flutter test integration_test/qdrant_filter_test.dart -d macos

import 'dart:io';

import 'package:flutter_edge_ai_qdrant/src/filter_codec.dart';
import 'package:flutter_edge_ai_qdrant/src/point_id_hasher.dart';
import 'package:flutter_edge_ai_qdrant/src/qdrant_edge_client.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// Declares every field these tests filter on, so FilterCodec.encode keeps them
// (an undeclared key is now skipped as a no-op).
final _schema = FilterSchema(
  fields: [
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'price', type: FilterFieldType.number),
    FilterField(name: 'type', type: FilterFieldType.string),
  ],
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late QdrantEdgeClient client;
  late Directory shardDir;

  setUp(() async {
    final base = await getApplicationSupportDirectory();
    shardDir = Directory(
      '${base.path}/qdrant_filter_${DateTime.now().microsecondsSinceEpoch}',
    );
    client = await QdrantEdgeClient.open(path: shardDir.path, dim: 4);

    // Seed corpus: same vector (we test filtering, not similarity), varied
    // payload fields so each Filter variant has something to match against.
    await client.upsertBatch([
      (
        id: PointIdHasher.hash('en_book_50'),
        vector: [1.0, 0.0, 0.0, 0.0],
        payload: {'lang': 'en', 'type': 'book', 'price': 50.0},
      ),
      (
        id: PointIdHasher.hash('en_book_200'),
        vector: [1.0, 0.0, 0.0, 0.0],
        payload: {'lang': 'en', 'type': 'book', 'price': 200.0},
      ),
      (
        id: PointIdHasher.hash('en_audio_100'),
        vector: [1.0, 0.0, 0.0, 0.0],
        payload: {'lang': 'en', 'type': 'audio', 'price': 100.0},
      ),
      (
        id: PointIdHasher.hash('fr_book_75'),
        vector: [1.0, 0.0, 0.0, 0.0],
        payload: {'lang': 'fr', 'type': 'book', 'price': 75.0},
      ),
      (
        id: PointIdHasher.hash('de_video_300'),
        vector: [1.0, 0.0, 0.0, 0.0],
        payload: {'lang': 'de', 'type': 'video', 'price': 300.0},
      ),
    ]);
    expect(await client.count(), equals(5));
  });

  tearDown(() async {
    await client.close();
    if (shardDir.existsSync()) shardDir.deleteSync(recursive: true);
  });

  Future<Set<String>> matchedHashedIds(Filter filter) async {
    final hits = await client.search(
      queryVector: const [1.0, 0.0, 0.0, 0.0],
      topK: 100,
      filterJson: FilterCodec.encode(filter, _schema),
    );
    return hits.map((h) => h.id).toSet();
  }

  test('must FieldEquals narrows to a single value', () async {
    final ids = await matchedHashedIds(
      Filter(
        must: [FieldEquals(key: 'lang', value: 'en')],
      ),
    );
    expect(ids, hasLength(3));
    expect(ids, contains(PointIdHasher.hash('en_book_50')));
    expect(ids, contains(PointIdHasher.hash('en_book_200')));
    expect(ids, contains(PointIdHasher.hash('en_audio_100')));
  });

  test('must FieldRange narrows by inclusive bounds', () async {
    final ids = await matchedHashedIds(
      Filter(must: [FieldRange(key: 'price', gte: 100.0, lte: 250.0)]),
    );
    expect(ids, hasLength(2));
    expect(ids, contains(PointIdHasher.hash('en_book_200')));
    expect(ids, contains(PointIdHasher.hash('en_audio_100')));
  });

  test('must with multiple conditions is AND', () async {
    final ids = await matchedHashedIds(
      Filter(
        must: [
          FieldEquals(key: 'lang', value: 'en'),
          FieldEquals(key: 'type', value: 'book'),
        ],
      ),
    );
    expect(ids, hasLength(2));
    expect(ids, contains(PointIdHasher.hash('en_book_50')));
    expect(ids, contains(PointIdHasher.hash('en_book_200')));
  });

  test('should with FieldMatchAny is OR over values', () async {
    final ids = await matchedHashedIds(
      Filter(
        should: [
          FieldMatchAny(key: 'lang', values: ['fr', 'de']),
        ],
      ),
    );
    expect(ids, hasLength(2));
    expect(ids, contains(PointIdHasher.hash('fr_book_75')));
    expect(ids, contains(PointIdHasher.hash('de_video_300')));
  });

  test('mustNot excludes matching docs', () async {
    final ids = await matchedHashedIds(
      Filter(
        mustNot: [FieldEquals(key: 'lang', value: 'en')],
      ),
    );
    expect(ids, hasLength(2));
    expect(ids, contains(PointIdHasher.hash('fr_book_75')));
    expect(ids, contains(PointIdHasher.hash('de_video_300')));
  });

  test('must + mustNot combines AND + NOT', () async {
    // English docs but exclude audio.
    final ids = await matchedHashedIds(
      Filter(
        must: [FieldEquals(key: 'lang', value: 'en')],
        mustNot: [FieldEquals(key: 'type', value: 'audio')],
      ),
    );
    expect(ids, hasLength(2));
    expect(ids, contains(PointIdHasher.hash('en_book_50')));
    expect(ids, contains(PointIdHasher.hash('en_book_200')));
  });

  test('range one-sided (gte only) is honored', () async {
    final ids = await matchedHashedIds(
      Filter(must: [FieldRange(key: 'price', gte: 200.0)]),
    );
    expect(ids, hasLength(2));
    expect(ids, contains(PointIdHasher.hash('en_book_200')));
    expect(ids, contains(PointIdHasher.hash('de_video_300')));
  });

  test('non-matching filter narrows to zero hits without error', () async {
    final ids = await matchedHashedIds(
      Filter(
        must: [FieldEquals(key: 'lang', value: 'xx')],
      ),
    );
    expect(ids, isEmpty);
  });
}
