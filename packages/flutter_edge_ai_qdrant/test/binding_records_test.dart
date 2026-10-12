// The qdrant store's binding records (R5 §6.2, §6.4): what an image or audio
// binding writes beside the shard, how every row of the reader truth table
// reads, the repair of an interrupted bind, and how a binding combines with an
// existing dimension reservation.
//
// Run: flutter test test/binding_records_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_qdrant/src/atomic_directory_record.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _storeDirName = 'qdrant_edge_v1';
const _profileDirectoryName = '.flutter_edge_ai_rag.embedding_profile.v1';
const _dimensionDirectoryName = '.flutter_edge_ai_rag.embedding_dimension.v1';
const _bindingDirectoryName = '.flutter_edge_ai_rag.binding.v2';
const _recordTempPrefix = '.flutter_edge_ai_rag.record.tmp.';

final _profileA = EmbeddingProfile(id: 'embedder-a-v1', dimension: 4);
final _profileB = EmbeddingProfile(id: 'embedder-b-v1', dimension: 4);

VectorStoreBinding _binding(
  EmbeddingProfile profile, [
  EmbeddingModality documents = EmbeddingModality.text,
]) => VectorStoreBinding(profile: profile, documents: documents);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('qdrant_binding_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String recordPath(String name) =>
      p.join(temp.path, _storeDirName, name, AtomicDirectoryRecord.fileName);

  Map<String, Object?>? record(String name) {
    final file = File(recordPath(name));
    if (!file.existsSync()) return null;
    return (jsonDecode(file.readAsStringSync()) as Map).cast();
  }

  Future<void> writeRecord(String name, Map<String, Object> json) =>
      AtomicDirectoryRecord.publish(
        parentDirectory: p.join(temp.path, _storeDirName),
        finalDirectory: p.join(temp.path, _storeDirName, name),
        tempPrefix: _recordTempPrefix,
        json: json,
      );

  Future<void> writeV1(String id, [int dimension = 4]) =>
      writeRecord(_profileDirectoryName, {
        'schema': 'flutter_edge_ai_rag.embedding_profile',
        'version': 1,
        'id': id,
        'dimension': dimension,
      });

  Future<void> writeV2(String id, String documents, [int dimension = 4]) =>
      writeRecord(_bindingDirectoryName, {
        'schema': 'flutter_edge_ai_rag.binding',
        'version': 2,
        'id': id,
        'dimension': dimension,
        'documents': documents,
      });

  Future<QdrantVectorStore> openStore() async {
    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(temp.path);
    return store;
  }

  group('what a bind writes', () {
    test('text: the 2.0 profile record, no binding record', () async {
      final store = await openStore();
      await store.bind(_binding(_profileA));

      expect(record(_profileDirectoryName), {
        'schema': 'flutter_edge_ai_rag.embedding_profile',
        'version': 1,
        'id': 'embedder-a-v1',
        'dimension': 4,
      });
      expect(record(_dimensionDirectoryName), {
        'schema': 'flutter_edge_ai_rag.embedding_dimension',
        'version': 1,
        'dimension': 4,
      });
      expect(record(_bindingDirectoryName), isNull);
    });

    for (final documents in [
      EmbeddingModality.image,
      EmbeddingModality.audio,
    ]) {
      test(
        '${documents.name}: qualified profile record + binding record v2',
        () async {
          final binding = _binding(_profileA, documents);
          final store = await openStore();
          await store.bind(binding);
          await store.bind(binding);

          expect(record(_profileDirectoryName), {
            'schema': 'flutter_edge_ai_rag.embedding_profile',
            'version': 1,
            'id': 'embedder-a-v1\u001F${documents.name}',
            'dimension': 4,
          });
          expect(record(_bindingDirectoryName), {
            'schema': 'flutter_edge_ai_rag.binding',
            'version': 2,
            'id': 'embedder-a-v1',
            'dimension': 4,
            'documents': documents.name,
          });
          expect(await store.readBinding(), binding);
          await store.close();

          final reopened = await openStore();
          expect(await reopened.readBinding(), binding);
          await expectLater(
            reopened.bind(_binding(_profileA)),
            throwsA(
              isA<VectorStoreException>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('already bound to $binding'),
                  contains('Use a different location.'),
                ),
              ),
            ),
          );
        },
      );
    }

    test(
      'a text binding refuses an image bind and writes nothing more',
      () async {
        final store = await openStore();
        await store.bind(_binding(_profileA));

        await expectLater(
          store.bind(_binding(_profileA, EmbeddingModality.image)),
          throwsA(isA<VectorStoreException>()),
        );
        expect(record(_bindingDirectoryName), isNull);
        expect(await store.readBinding(), _binding(_profileA));
      },
    );

    test('two stores binding text and image concurrently: one wins', () async {
      final first = await openStore();
      final second = await openStore();

      final outcomes = await Future.wait([
        first
            .bind(_binding(_profileA))
            .then<Object>((_) => 'text', onError: (Object e) => e),
        second
            .bind(_binding(_profileA, EmbeddingModality.image))
            .then<Object>((_) => 'image', onError: (Object e) => e),
      ]);

      expect(outcomes.whereType<String>(), hasLength(1), reason: '$outcomes');
      expect(outcomes.whereType<VectorStoreException>(), hasLength(1));
      final winner = outcomes.whereType<String>().single;
      expect(
        await first.readBinding(),
        winner == 'text'
            ? _binding(_profileA)
            : _binding(_profileA, EmbeddingModality.image),
      );
    });

    test('clear keeps an image binding', () async {
      final binding = _binding(_profileA, EmbeddingModality.image);
      final store = await openStore();
      await store.bind(binding);
      await store.addDocument(
        id: 'photo',
        content: 'content://media/1',
        embedding: const [1, 0, 0, 0],
      );
      await store.clear();

      expect((await store.getStats()).documentCount, 0);
      expect(await store.readBinding(), binding);
    });
  });

  group('reader truth table', () {
    Matcher corrupt(String detail) => throwsA(
      isA<VectorStoreException>().having(
        (error) => error.message,
        'message',
        allOf(contains('corrupt'), contains(detail)),
      ),
    );

    test('v1 absent, v2 absent: unbound', () async {
      expect(await (await openStore()).readBinding(), isNull);
    });

    test('v1 absent, v2 present: corrupt', () async {
      await writeV2('embedder-a-v1', 'image');
      expect((await openStore()).readBinding(), corrupt('without the profile'));
    });

    test('v1 unqualified, v2 absent: text', () async {
      await writeV1('embedder-a-v1');
      expect(await (await openStore()).readBinding(), _binding(_profileA));
    });

    test('v1 unqualified, v2 present: corrupt', () async {
      await writeV1('embedder-a-v1');
      await writeV2('embedder-a-v1', 'image');
      expect((await openStore()).readBinding(), corrupt('to text documents'));
    });

    test('v1 qualified, v2 agreeing: audio', () async {
      await writeV1('embedder-a-v1\u001Faudio');
      await writeV2('embedder-a-v1', 'audio');
      expect(
        await (await openStore()).readBinding(),
        _binding(_profileA, EmbeddingModality.audio),
      );
    });

    for (final (name, id, documents, dimension) in [
      ('id', 'embedder-b-v1', 'image', 4),
      ('documents', 'embedder-a-v1', 'audio', 4),
      ('dimension', 'embedder-a-v1', 'image', 8),
    ]) {
      test('v1 qualified, v2 disagreeing ($name): corrupt', () async {
        await writeV1('embedder-a-v1\u001Fimage');
        await writeV2(id, documents, dimension);
        expect((await openStore()).readBinding(), corrupt('says'));
      });
    }

    test('v1 qualified, v2 absent: v2 is republished from v1', () async {
      await writeV1('embedder-a-v1\u001Fimage');

      final store = await openStore();
      expect(
        await store.readBinding(),
        _binding(_profileA, EmbeddingModality.image),
      );
      expect(record(_bindingDirectoryName), {
        'schema': 'flutter_edge_ai_rag.binding',
        'version': 2,
        'id': 'embedder-a-v1',
        'dimension': 4,
        'documents': 'image',
      });
    });

    group('v1 qualified, v2 absent, the location holds documents', () {
      Matcher ambiguous() => throwsA(
        isA<VectorStoreException>().having(
          (error) => error.message,
          'message',
          allOf(contains('ambiguous'), contains(r'\u001Fimage')),
        ),
      );

      test('a lost binding record is not guessed back', () async {
        final store = await openStore();
        await store.bind(_binding(_profileA, EmbeddingModality.image));
        await store.addDocument(
          id: 'photo',
          content: 'content://media/1',
          embedding: const [1, 0, 0, 0],
        );
        await store.close();
        Directory(
          p.join(temp.path, _storeDirName, _bindingDirectoryName),
        ).deleteSync(recursive: true);

        final reopened = await openStore();
        expect(reopened.readBinding(), ambiguous());
        expect(
          reopened.bind(_binding(_profileA, EmbeddingModality.image)),
          ambiguous(),
        );
        expect(record(_bindingDirectoryName), isNull);
      });

      test(
        'an older text store whose id contains U+001F stays text-only',
        () async {
          // What flutter_edge_ai_qdrant 2.0.1 could write: a TEXT binding with
          // documents, under an id that happens to end in "\u001Fimage".
          final store = await openStore();
          await store.bind(_binding(_profileA));
          await store.addDocument(
            id: 'text',
            content: 'a text chunk',
            embedding: const [1, 0, 0, 0],
          );
          await store.close();
          Directory(
            p.join(temp.path, _storeDirName, _profileDirectoryName),
          ).deleteSync(recursive: true);
          await writeV1('legacy-v1\u001Fimage');

          final reopened = await openStore();
          expect(reopened.readBinding(), ambiguous());
          expect(
            reopened.addDocument(
              id: 'photo',
              content: 'content://media/1',
              embedding: const [0, 1, 0, 0],
            ),
            throwsA(isA<VectorStoreException>()),
            reason: 'no media vector may land next to the text ones',
          );
          expect(record(_bindingDirectoryName), isNull);
          expect((await reopened.getStats()).documentCount, 1);
        },
      );
    });

    test('concurrent repairs agree on one record', () async {
      await writeV1('embedder-a-v1\u001Faudio');
      final stores = [for (var i = 0; i < 4; i++) await openStore()];

      final reads = await Future.wait([
        for (final store in stores) store.readBinding(),
      ]);

      expect(reads, everyElement(_binding(_profileA, EmbeddingModality.audio)));
      final leftovers = Directory(p.join(temp.path, _storeDirName))
          .listSync()
          .map((entry) => p.basename(entry.path))
          .where((name) => name.startsWith(_recordTempPrefix));
      expect(leftovers, isEmpty);
    });

    test('a bind interrupted between the records completes on retry', () async {
      await writeV1('embedder-a-v1\u001Fimage');
      final store = await openStore();
      await store.bind(_binding(_profileA, EmbeddingModality.image));
      expect(record(_bindingDirectoryName)?['documents'], 'image');
    });

    for (final suffix in ['video', 'text', '']) {
      test('v1 qualified with unknown modality "$suffix": newer', () async {
        await writeV1('embedder-a-v1\u001F$suffix');
        await writeV2('embedder-a-v1', 'image');
        expect(
          (await openStore()).readBinding(),
          throwsA(
            isA<VectorStoreException>().having(
              (error) => error.message,
              'message',
              contains('written by a newer version'),
            ),
          ),
        );
      });
    }

    test('a binding record of another version is corrupt', () async {
      await writeV1('embedder-a-v1\u001Fimage');
      await writeRecord(_bindingDirectoryName, {
        'schema': 'flutter_edge_ai_rag.binding',
        'version': 3,
        'id': 'embedder-a-v1',
        'dimension': 4,
        'documents': 'image',
      });
      expect(
        (await openStore()).readBinding(),
        throwsA(
          isA<VectorStoreException>().having(
            (error) => error.message,
            'message',
            contains('corrupt or unreadable'),
          ),
        ),
      );
    });
  });

  group('binding x existing dimension record', () {
    Future<void> reserve(int dimension) =>
        writeRecord(_dimensionDirectoryName, {
          'schema': 'flutter_edge_ai_rag.embedding_dimension',
          'version': 1,
          'dimension': dimension,
        });

    for (final documents in EmbeddingModality.values) {
      test('${documents.name} binds over a matching reservation', () async {
        await reserve(4);
        final store = await openStore();
        await store.bind(_binding(_profileA, documents));
        expect(await store.readBinding(), _binding(_profileA, documents));
      });

      test('${documents.name} is refused by a different reservation', () async {
        await reserve(8);
        final store = await openStore();
        await expectLater(
          store.bind(_binding(_profileA, documents)),
          throwsA(
            isA<VectorStoreException>().having(
              (error) => error.message,
              'message',
              contains('reserved for 8D vectors'),
            ),
          ),
        );
        expect(record(_profileDirectoryName), isNull);
        expect(record(_bindingDirectoryName), isNull);
        expect(await store.readBinding(), isNull);
      });
    }

    test('a binding that contradicts the reservation is corrupt', () async {
      await reserve(8);
      await writeV1('embedder-a-v1\u001Fimage');
      await writeV2('embedder-a-v1', 'image');
      expect(
        (await openStore()).readBinding(),
        throwsA(
          isA<VectorStoreException>().having(
            (error) => error.message,
            'message',
            contains('8D dimension reservation'),
          ),
        ),
      );
    });

    test('an image binding enforces its dimension on documents', () async {
      final store = await openStore();
      await store.bind(_binding(_profileB, EmbeddingModality.image));
      await expectLater(
        store.addDocument(
          id: 'wrong',
          content: 'photo.jpg',
          embedding: List<double>.filled(8, 0),
        ),
        throwsArgumentError,
      );
      await store.addDocument(
        id: 'right',
        content: 'photo.jpg',
        embedding: const [0, 1, 0, 0],
      );
      final hits = await store.searchSimilar(
        queryEmbedding: const [0, 1, 0, 0],
        topK: 1,
      );
      expect(hits.single.content, 'photo.jpg');
    });
  });

  group('shard detection', () {
    test('a binding-only directory is not mistaken for a shard', () async {
      final first = await openStore();
      await first.bind(_binding(_profileA, EmbeddingModality.image));
      await first.close();

      final reopened = await openStore();
      expect((await reopened.getStats()).documentCount, 0);
      expect(
        await reopened.readBinding(),
        _binding(_profileA, EmbeddingModality.image),
      );
    });

    test('a binding-only directory does not hide a legacy store', () async {
      final first = await openStore();
      await first.bind(_binding(_profileA, EmbeddingModality.audio));
      await first.close();
      File(p.join(temp.path, 'edge_config.json')).writeAsStringSync(
        '{"vectors":{"":{"size":4,"distance":"Cosine","on_disk":false}}}',
      );
      Directory(p.join(temp.path, 'wal')).createSync();

      final reopened = QdrantVectorStore();
      addTearDown(reopened.close);
      await expectLater(
        reopened.initialize(temp.path),
        throwsA(isA<QdrantLegacyStoreException>()),
      );
    });
  });
}
