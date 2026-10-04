import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_qdrant/src/profile_operation_test_hook.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _storeDirName = 'qdrant_edge_v1';
const _profileDirectoryName = '.flutter_edge_ai_rag.embedding_profile.v1';
const _dimensionDirectoryName = '.flutter_edge_ai_rag.embedding_dimension.v1';
const _recordFileName = 'record.json';
const _recordTempPrefix = '.flutter_edge_ai_rag.record.tmp.';
final _profileA = EmbeddingProfile(id: 'embedder-a-v1', dimension: 4);
final _profileB = EmbeddingProfile(id: 'embedder-b-v1', dimension: 4);

void _writeLegacyStore(String databasePath) {
  File(p.join(databasePath, 'edge_config.json')).writeAsStringSync(
    '{"on_disk_payload":false,'
    '"vectors":{"":{"size":4,"distance":"Cosine","on_disk":false}},'
    '"sparse_vectors":{}}',
  );
  Directory(p.join(databasePath, 'wal')).createSync(recursive: true);
  Directory(p.join(databasePath, 'segments')).createSync(recursive: true);
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('qdrant_profile_'));
  tearDown(() {
    qdrantProfileOperationCheckpointForTesting = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('provider identifies qdrant and creates fresh stores', () async {
    const provider = QdrantVectorStoreProvider();
    final qdrant = VectorStoreSpec(providerId: 'qdrant', location: temp.path);
    final other = VectorStoreSpec(providerId: 'sqlite', location: temp.path);

    expect(provider.id, 'qdrant');
    expect(provider.name, 'qdrant-edge');
    expect(provider.priority, 0);
    expect(provider.canHandle(qdrant), isTrue);
    expect(provider.canHandle(other), isFalse);

    final first = await provider.createStore(qdrant);
    final second = await provider.createStore(qdrant);
    expect(first, isA<QdrantVectorStore>());
    expect(second, isA<QdrantVectorStore>());
    expect(identical(first, second), isFalse);
  });

  test('low-level mutations require an explicit profile binding', () async {
    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(temp.path);

    expect((await store.getStats()).documentCount, 0);
    await expectLater(
      store.addDocument(
        id: 'unbound',
        content: 'unbound',
        embedding: const [1, 0, 0, 0],
      ),
      throwsStateError,
    );
    await expectLater(
      store.searchSimilar(queryEmbedding: const [1, 0, 0, 0], topK: 1),
      throwsStateError,
    );
    await expectLater(store.removeDocument(id: 'unbound'), throwsStateError);
    await expectLater(store.clear(), throwsStateError);

    await store.bindEmbeddingProfile(_profileA);
    await store.addDocument(
      id: 'bound',
      content: 'bound',
      embedding: const [1, 0, 0, 0],
    );
    expect((await store.getStats()).documentCount, 1);
  });

  test('old-path profile cannot authorize an add after reinitialize', () async {
    final oldPath = Directory(p.join(temp.path, 'old'))..createSync();
    final newPath = Directory(p.join(temp.path, 'new'))..createSync();
    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(oldPath.path);
    await store.bindEmbeddingProfile(_profileA);

    final reached = Completer<void>();
    final release = Completer<void>();
    qdrantProfileOperationCheckpointForTesting = (operation) async {
      if (operation != 'addDocument') return;
      reached.complete();
      await release.future;
    };
    final add = store.addDocument(
      id: 'wrong-location',
      content: 'must not cross the lifecycle boundary',
      embedding: const [1, 0, 0, 0],
    );
    await reached.future;
    await store.initialize(newPath.path);
    await store.bindEmbeddingProfile(_profileB);
    release.complete();

    await expectLater(add, throwsA(isA<VectorStoreException>()));
    expect((await store.getStats()).documentCount, 0);

    final oldReader = QdrantVectorStore();
    addTearDown(oldReader.close);
    await oldReader.initialize(oldPath.path);
    expect((await oldReader.getStats()).documentCount, 0);
  });

  test(
    'old-path profile cannot authorize search or remove after reinitialize',
    () async {
      final oldPath = Directory(p.join(temp.path, 'old'))..createSync();
      final newPath = Directory(p.join(temp.path, 'new'))..createSync();
      final store = QdrantVectorStore();
      addTearDown(store.close);
      await store.initialize(oldPath.path);
      await store.bindEmbeddingProfile(_profileA);
      await store.addDocument(
        id: 'keep',
        content: 'must remain',
        embedding: const [1, 0, 0, 0],
      );

      Future<void> expectInterrupted(
        String operation,
        Future<void> Function() start,
      ) async {
        final reached = Completer<void>();
        final release = Completer<void>();
        qdrantProfileOperationCheckpointForTesting = (current) async {
          if (current != operation) return;
          reached.complete();
          await release.future;
        };
        final pending = start();
        await reached.future;
        await store.initialize(newPath.path);
        await store.bindEmbeddingProfile(_profileB);
        release.complete();
        await expectLater(pending, throwsA(isA<VectorStoreException>()));
        qdrantProfileOperationCheckpointForTesting = null;
      }

      await expectInterrupted('searchSimilar', () async {
        await store.searchSimilar(queryEmbedding: const [1, 0, 0, 0], topK: 1);
      });

      await store.initialize(oldPath.path);
      await expectInterrupted(
        'removeDocument',
        () => store.removeDocument(id: 'keep'),
      );

      await store.initialize(oldPath.path);
      final hits = await store.searchSimilar(
        queryEmbedding: const [1, 0, 0, 0],
        topK: 1,
      );
      expect(hits.map((hit) => hit.id), contains('keep'));
    },
  );

  test('same profile bind is idempotent and survives reopen', () async {
    final first = QdrantVectorStore();
    await first.initialize(temp.path);
    await first.bindEmbeddingProfile(_profileA);
    await first.bindEmbeddingProfile(_profileA);
    expect(await first.readEmbeddingProfile(), _profileA);
    await first.close();

    final reopened = QdrantVectorStore();
    addTearDown(reopened.close);
    await reopened.initialize(temp.path);
    expect(await reopened.readEmbeddingProfile(), _profileA);
  });

  test('conflicting profile bind is refused without overwrite', () async {
    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(temp.path);
    await store.bindEmbeddingProfile(_profileA);

    await expectLater(
      store.bindEmbeddingProfile(_profileB),
      throwsA(isA<VectorStoreException>()),
    );
    expect(await store.readEmbeddingProfile(), _profileA);
  });

  test('concurrent stores cannot silently bind different profiles', () async {
    final first = QdrantVectorStore();
    final second = QdrantVectorStore();
    addTearDown(first.close);
    addTearDown(second.close);
    await first.initialize(temp.path);
    await second.initialize(temp.path);

    final outcomes = await Future.wait([
      first
          .bindEmbeddingProfile(_profileA)
          .then<Object>((_) => _profileA)
          .catchError((Object error) => error),
      second
          .bindEmbeddingProfile(_profileB)
          .then<Object>((_) => _profileB)
          .catchError((Object error) => error),
    ]);

    expect(outcomes.whereType<EmbeddingProfile>(), hasLength(1));
    expect(outcomes.whereType<VectorStoreException>(), hasLength(1));
    final persisted = await first.readEmbeddingProfile();
    expect(persisted, outcomes.whereType<EmbeddingProfile>().single);
  });

  test('different isolates cannot bind different profiles', () async {
    Future<String> bind(String id) => Isolate.run(() async {
      final store = QdrantVectorStore();
      try {
        await store.initialize(temp.path);
        await store.bindEmbeddingProfile(
          EmbeddingProfile(id: id, dimension: 4),
        );
        return 'bound:$id';
      } on VectorStoreException {
        return 'conflict:$id';
      } finally {
        await store.close();
      }
    });

    final outcomes = await Future.wait([
      bind(_profileA.id),
      bind(_profileB.id),
    ]);
    expect(
      outcomes.where((outcome) => outcome.startsWith('bound:')),
      hasLength(1),
    );
    expect(
      outcomes.where((outcome) => outcome.startsWith('conflict:')),
      hasLength(1),
    );

    final reader = QdrantVectorStore();
    addTearDown(reader.close);
    await reader.initialize(temp.path);
    final persisted = await reader.readEmbeddingProfile();
    expect(
      'bound:${persisted!.id}',
      outcomes.firstWhere((value) => value.startsWith('bound:')),
    );
  });

  test('different processes cannot bind different profiles', () async {
    final worker = p.join(
      Directory.current.path,
      'test',
      'support',
      'profile_process_worker.dart',
    );
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot == null) {
      fail('FLUTTER_ROOT is required for the process-level CAS test');
    }
    final dartExecutable = p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    final workerExecutable = p.join(
      temp.path,
      Platform.isWindows
          ? 'profile_process_worker.exe'
          : 'profile_process_worker',
    );
    final compilation = await Process.run(dartExecutable, [
      'compile',
      'exe',
      worker,
      '-o',
      workerExecutable,
    ], workingDirectory: Directory.current.path);
    expect(
      compilation.exitCode,
      0,
      reason: '${compilation.stdout}\n${compilation.stderr}',
    );
    Future<Process> start(String id) => Process.start(workerExecutable, [
      temp.path,
      id,
      '4',
    ], workingDirectory: Directory.current.path);

    final processes = await Future.wait([
      start(_profileA.id),
      start(_profileB.id),
    ]);
    final results = await Future.wait([
      for (final process in processes)
        Future.wait<Object>([
          process.exitCode,
          process.stdout.transform(systemEncoding.decoder).join(),
          process.stderr.transform(systemEncoding.decoder).join(),
        ]),
    ]);

    expect(results.map((result) => result[0]), unorderedEquals([0, 2]));
    final output = results.map((result) => result[1] as String).join();
    expect(RegExp('bound:').allMatches(output), hasLength(1));
    expect(RegExp('conflict:').allMatches(output), hasLength(1));

    final reader = QdrantVectorStore();
    addTearDown(reader.close);
    await reader.initialize(temp.path);
    final persisted = await reader.readEmbeddingProfile();
    expect(output, contains('bound:${persisted!.id}'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('isolate bind and first shard creation share dimension CAS', () async {
    final bind = Isolate.run(() async {
      final store = QdrantVectorStore();
      try {
        await store.initialize(temp.path);
        await store.bindEmbeddingProfile(
          EmbeddingProfile(id: 'four-dimensional', dimension: 4),
        );
        return 'bound-4';
      } on ArgumentError {
        return 'rejected-4';
      } finally {
        await store.close();
      }
    });
    final add = Isolate.run(() async {
      final store = QdrantVectorStore();
      try {
        await store.initialize(temp.path);
        await store.bindEmbeddingProfile(
          EmbeddingProfile(id: 'eight-dimensional', dimension: 8),
        );
        await store.addDocument(
          id: 'eight',
          content: 'eight-dimensional',
          embedding: List<double>.filled(8, 0),
        );
        return 'added-8';
      } on Object {
        return 'rejected-8';
      } finally {
        await store.close();
      }
    });

    final outcomes = await Future.wait([bind, add]);
    expect(
      outcomes,
      anyOf(
        unorderedEquals(['bound-4', 'rejected-8']),
        unorderedEquals(['rejected-4', 'added-8']),
      ),
    );
  });

  test('concurrent readers see no profile or the complete profile', () async {
    final writer = QdrantVectorStore();
    final reader = QdrantVectorStore();
    addTearDown(writer.close);
    addTearDown(reader.close);
    await writer.initialize(temp.path);
    await reader.initialize(temp.path);

    final binding = writer.bindEmbeddingProfile(_profileA);
    final observations = await Future.wait([
      for (var index = 0; index < 100; index++) reader.readEmbeddingProfile(),
    ]);
    await binding;

    expect(observations, everyElement(anyOf(isNull, equals(_profileA))));
    expect(await reader.readEmbeddingProfile(), _profileA);
  });

  test('corrupt profile sidecar is reported loudly', () async {
    final owned = Directory(p.join(temp.path, _storeDirName))
      ..createSync(recursive: true);
    final profileDirectory = Directory(
      p.join(owned.path, _profileDirectoryName),
    )..createSync();
    File(
      p.join(profileDirectory.path, _recordFileName),
    ).writeAsStringSync('{bad json');

    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(temp.path);
    await expectLater(
      store.readEmbeddingProfile(),
      throwsA(
        isA<VectorStoreException>().having(
          (error) => error.message,
          'message',
          contains('corrupt or unreadable'),
        ),
      ),
    );
  });

  test('corrupt dimension reservation is reported loudly', () async {
    final dimensionDirectory = Directory(
      p.join(temp.path, _storeDirName, _dimensionDirectoryName),
    )..createSync(recursive: true);
    File(
      p.join(dimensionDirectory.path, _recordFileName),
    ).writeAsStringSync('{bad json');

    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(temp.path);
    await expectLater(
      store.readEmbeddingProfile(),
      throwsA(isA<VectorStoreException>()),
    );
  });

  test('interrupted temp artifacts are invisible and recoverable', () async {
    final owned = Directory(p.join(temp.path, _storeDirName))
      ..createSync(recursive: true);
    final partial = Directory(p.join(owned.path, '${_recordTempPrefix}crashed'))
      ..createSync();
    File(p.join(partial.path, _recordFileName)).writeAsStringSync('{"schema":');

    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(temp.path);
    expect(await store.readEmbeddingProfile(), isNull);

    await store.bindEmbeddingProfile(_profileA);
    expect(await store.readEmbeddingProfile(), _profileA);
    expect(partial.existsSync(), isTrue);
  });

  test('bound profile dimension is enforced before shard creation', () async {
    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(temp.path);
    await store.bindEmbeddingProfile(_profileA);

    await expectLater(
      store.addDocument(
        id: 'wrong',
        content: 'wrong dimension',
        embedding: List<double>.filled(8, 0),
      ),
      throwsArgumentError,
    );
    expect((await store.getStats()).documentCount, 0);

    await store.addDocument(
      id: 'right',
      content: 'right dimension',
      embedding: List<double>.filled(4, 0),
    );
    expect((await store.getStats()).documentCount, 1);
  });

  test('an unbound empty vector cannot reserve an invalid dimension', () async {
    final store = QdrantVectorStore();
    addTearDown(store.close);
    await store.initialize(temp.path);

    await expectLater(
      store.addDocument(id: 'empty', content: 'empty', embedding: const []),
      throwsStateError,
    );
    expect(
      Directory(
        p.join(temp.path, _storeDirName, _dimensionDirectoryName),
      ).existsSync(),
      isFalse,
    );
  });

  test('clear removes documents but preserves the profile', () async {
    final store = QdrantVectorStore();
    await store.initialize(temp.path);
    await store.bindEmbeddingProfile(_profileA);
    await store.addDocument(
      id: 'doc',
      content: 'content',
      embedding: const [1, 0, 0, 0],
    );
    await store.clear();
    expect((await store.getStats()).documentCount, 0);
    expect(await store.readEmbeddingProfile(), _profileA);
    await store.close();

    final reopened = QdrantVectorStore();
    addTearDown(reopened.close);
    await reopened.initialize(temp.path);
    expect(await reopened.readEmbeddingProfile(), _profileA);
  });

  test('profile-only directory is not mistaken for a qdrant shard', () async {
    final first = QdrantVectorStore();
    await first.initialize(temp.path);
    await first.bindEmbeddingProfile(_profileA);
    await first.close();

    final reopened = QdrantVectorStore();
    addTearDown(reopened.close);
    await reopened.initialize(temp.path);
    expect((await reopened.getStats()).documentCount, 0);
    expect(await reopened.readEmbeddingProfile(), _profileA);
  });

  test('profile-only directory does not hide a legacy bare store', () async {
    final first = QdrantVectorStore();
    await first.initialize(temp.path);
    await first.bindEmbeddingProfile(_profileA);
    await first.close();
    Directory(
      p.join(temp.path, _storeDirName, '${_recordTempPrefix}interrupted'),
    ).createSync();
    _writeLegacyStore(temp.path);

    final reopened = QdrantVectorStore();
    addTearDown(reopened.close);
    await expectLater(
      reopened.initialize(temp.path),
      throwsA(isA<QdrantLegacyStoreException>()),
    );
  });
}
