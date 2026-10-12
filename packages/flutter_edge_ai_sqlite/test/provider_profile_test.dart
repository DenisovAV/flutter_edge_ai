import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_sqlite/src/sqlite_profile_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vec0_locator.dart';

final _profileA = EmbeddingProfile(id: 'embedder-a-v1', dimension: 4);
final _profileB = EmbeddingProfile(id: 'embedder-b-v1', dimension: 4);

VectorStoreBinding _binding(
  EmbeddingProfile profile, [
  EmbeddingModality documents = EmbeddingModality.text,
]) => VectorStoreBinding(profile: profile, documents: documents);

void main() {
  group('SqliteVectorStoreProvider', () {
    const provider = SqliteVectorStoreProvider();

    test(
      'selects only the sqlite provider id and creates a native store',
      () async {
        final sqlite = VectorStoreSpec(providerId: 'sqlite', location: 'index');
        final other = VectorStoreSpec(providerId: 'other', location: 'index');

        expect(provider.id, SqliteVectorStoreProvider.providerId);
        expect(provider.canHandle(sqlite), isTrue);
        expect(provider.canHandle(other), isFalse);
        expect(await provider.createStore(sqlite), isA<SqliteVectorStore>());
        await expectLater(provider.createStore(other), throwsUnsupportedError);
      },
    );
  });

  group('SQLite binding records', () {
    late Directory temp;
    late String path;
    late Database db;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('sqlite_binding_record');
      path = '${temp.path}/profile.db';
      db = sqlite3.open(path);
      ensureSqliteEmbeddingProfileTable(db);
    });

    tearDown(() {
      db.close();
      temp.deleteSync(recursive: true);
    });

    List<Map<String, Object?>> v1Rows() => [
      for (final row in db.select('SELECT * FROM $sqliteEmbeddingProfileTable'))
        Map.of(row),
    ];

    bool hasV2Table() => db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [sqliteBindingV2Table],
    ).isNotEmpty;

    test('compare-and-set is exact and idempotent', () async {
      final binding = _binding(_profileA);
      expect(readSqliteBinding(db), isNull);

      await bindSqliteBinding(db, binding);
      await bindSqliteBinding(db, binding);
      expect(readSqliteBinding(db), binding);

      for (final other in [
        _binding(_profileB),
        _binding(EmbeddingProfile(id: 'embedder-a-v1', dimension: 8)),
        _binding(_profileA, EmbeddingModality.image),
        _binding(_profileA, EmbeddingModality.audio),
      ]) {
        await expectLater(
          bindSqliteBinding(db, other),
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
          reason: '$other',
        );
        expect(readSqliteBinding(db), binding);
        expect(db.autocommit, isTrue, reason: 'a rejected CAS must roll back');
      }
      expect(hasV2Table(), isFalse, reason: 'a refused bind left no v2 table');
    });

    test('a text binding writes the 2.0 record and nothing else', () async {
      await bindSqliteBinding(db, _binding(_profileA));

      expect(v1Rows(), [
        {'singleton': 1, 'profile_id': 'embedder-a-v1', 'dimension': 4},
      ]);
      expect(hasV2Table(), isFalse);
    });

    for (final documents in [
      EmbeddingModality.image,
      EmbeddingModality.audio,
    ]) {
      test('an ${documents.name} binding writes v1 qualified and v2', () async {
        final binding = _binding(_profileA, documents);
        await bindSqliteBinding(db, binding);
        await bindSqliteBinding(db, binding);

        expect(v1Rows(), [
          {
            'singleton': 1,
            'profile_id': 'embedder-a-v1\u001F${documents.name}',
            'dimension': 4,
          },
        ]);
        expect(
          [
            for (final row in db.select('SELECT * FROM $sqliteBindingV2Table'))
              Map.of(row),
          ],
          [
            {
              'singleton': 1,
              'profile_id': 'embedder-a-v1',
              'dimension': 4,
              'documents': documents.name,
            },
          ],
        );
        expect(readSqliteBinding(db), binding);
        await expectLater(
          bindSqliteBinding(db, _binding(_profileA)),
          throwsA(isA<VectorStoreException>()),
          reason: 'the same profile as text is a different binding',
        );
      });
    }

    test('the binding persists across database handles', () async {
      final binding = _binding(_profileA, EmbeddingModality.image);
      await bindSqliteBinding(db, binding);
      db.close();

      db = sqlite3.open(path);
      ensureSqliteEmbeddingProfileTable(db);
      expect(readSqliteBinding(db), binding);
    });

    group('reader truth table', () {
      void writeV1(String id, [int dimension = 4]) => db.execute(
        'INSERT INTO $sqliteEmbeddingProfileTable VALUES (1, ?, ?)',
        [id, dimension],
      );

      void writeV2(String id, String documents, [int dimension = 4]) {
        db.execute('''
CREATE TABLE IF NOT EXISTS $sqliteBindingV2Table (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  profile_id TEXT NOT NULL,
  dimension INTEGER NOT NULL CHECK (dimension > 0),
  documents TEXT NOT NULL
)
''');
        db.execute('INSERT INTO $sqliteBindingV2Table VALUES (1, ?, ?, ?)', [
          id,
          dimension,
          documents,
        ]);
      }

      Matcher corrupt(String detail) => throwsA(
        isA<VectorStoreException>().having(
          (error) => error.message,
          'message',
          allOf(contains('corrupt'), contains(detail)),
        ),
      );

      test('v1 absent, v2 absent: unbound', () {
        expect(readSqliteBinding(db), isNull);
      });

      test('v1 absent, v2 present: corrupt', () {
        writeV2('embedder-a-v1', 'image');
        expect(() => readSqliteBinding(db), corrupt('without the version-1'));
      });

      test('v1 unqualified, v2 absent: text', () {
        writeV1('embedder-a-v1');
        expect(readSqliteBinding(db), _binding(_profileA));
      });

      test('v1 unqualified, v2 present: corrupt', () {
        writeV1('embedder-a-v1');
        writeV2('embedder-a-v1', 'image');
        expect(() => readSqliteBinding(db), corrupt('to text documents'));
      });

      test('v1 qualified, v2 agreeing: image', () {
        writeV1('embedder-a-v1\u001Fimage');
        writeV2('embedder-a-v1', 'image');
        expect(
          readSqliteBinding(db),
          _binding(_profileA, EmbeddingModality.image),
        );
      });

      for (final (name, id, documents, dimension) in [
        ('id', 'embedder-b-v1', 'image', 4),
        ('documents', 'embedder-a-v1', 'audio', 4),
        ('dimension', 'embedder-a-v1', 'image', 8),
        ('documents text', 'embedder-a-v1', 'text', 4),
      ]) {
        test('v1 qualified, v2 disagreeing ($name): corrupt', () {
          writeV1('embedder-a-v1\u001Fimage');
          writeV2(id, documents, dimension);
          expect(() => readSqliteBinding(db), corrupt('binding record says'));
        });
      }

      test(
        'v1 qualified, v2 absent: corrupt (one transaction writes both)',
        () {
          writeV1('embedder-a-v1\u001Faudio');
          expect(() => readSqliteBinding(db), corrupt('is missing'));
        },
      );

      test('v1 qualified, v2 table empty: corrupt', () {
        writeV1('embedder-a-v1\u001Fimage');
        writeV2('embedder-a-v1', 'image');
        db.execute('DELETE FROM $sqliteBindingV2Table');
        expect(() => readSqliteBinding(db), corrupt('is missing'));
      });

      for (final suffix in ['video', 'text', '']) {
        test('v1 qualified with an unknown modality "$suffix": newer', () {
          writeV1('embedder-a-v1\u001F$suffix');
          writeV2('embedder-a-v1', 'image');
          expect(
            () => readSqliteBinding(db),
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

      test('a refused bind over a corrupt location names the corruption', () {
        writeV1('embedder-a-v1\u001Fimage');
        expect(
          bindSqliteBinding(db, _binding(_profileB)),
          corrupt('is missing'),
        );
      });
    });

    group('against a flutter_edge_ai_sqlite 2.0.1 writer', () {
      test('a 2.1 image binding refuses a later 2.0.1 bind', () async {
        final binding = _binding(_profileA, EmbeddingModality.image);
        await bindSqliteBinding(db, binding);

        expect(oldWriterBind(db, 'embedder-a-v1', 4), 'refused');
        expect(oldWriterRead(db), (
          'embedder-a-v1\u001Fimage',
          4,
        ), reason: 'a 2.0.1 reader sees an id it can never be asked to open');
        expect(readSqliteBinding(db), binding);
      });

      test('a 2.0.1 binding refuses a later 2.1 image bind', () async {
        expect(oldWriterBind(db, 'embedder-a-v1', 4), 'bound');

        await expectLater(
          bindSqliteBinding(db, _binding(_profileA, EmbeddingModality.image)),
          throwsA(isA<VectorStoreException>()),
        );
        expect(readSqliteBinding(db), _binding(_profileA));
        expect(hasV2Table(), isFalse);
      });

      test('a 2.1 text binding and a 2.0.1 writer agree', () async {
        await bindSqliteBinding(db, _binding(_profileA));
        expect(oldWriterBind(db, 'embedder-a-v1', 4), 'bound');
        expect(oldWriterBind(db, 'embedder-b-v1', 4), 'refused');
        expect(readSqliteBinding(db), _binding(_profileA));
      });

      test('racing a 2.1 bind: exactly one wins, every time, and each side '
          'wins some rounds', () async {
        db.close();
        var oldWins = 0;
        var newWins = 0;
        var round = 0;
        // At least 40 rounds; more (up to 200) only while one side has not
        // won an on-time round yet — a loaded machine slows this test down
        // rather than failing it.
        for (; round < 200; round++) {
          if (round >= 40 && oldWins > 0 && newWins > 0) break;
          final file = '${temp.path}/race_$round.db';
          final setup = sqlite3.open(file);
          ensureSqliteEmbeddingProfileTable(setup);
          setup.close();
          final documents = round.isEven
              ? EmbeddingModality.image
              : EmbeddingModality.audio;

          // Both racers open their connection, then spin until the same
          // instant: isolate start-up must not decide the race. A racer that
          // reaches the start line after that instant reports itself late;
          // such a round still checks the exactly-one-winner invariant but
          // does not count toward "each side wins".
          final startAt =
              DateTime.now().microsecondsSinceEpoch +
              const Duration(milliseconds: 300).inMicroseconds;
          final results = await Future.wait([
            _inIsolateOldWriter(file, startAt),
            _inIsolateNewWriter(file, documents, startAt),
          ]);
          final outcomes = [for (final r in results) r.outcome];
          if (!results.any((r) => r.late)) {
            if (outcomes.first == 'bound') oldWins++;
            if (outcomes.last == 'bound') newWins++;
          }

          expect(
            outcomes.where((outcome) => outcome == 'bound'),
            hasLength(1),
            reason: 'round $round: $outcomes',
          );
          expect(
            outcomes.where((outcome) => outcome == 'refused'),
            hasLength(1),
            reason: 'round $round: $outcomes',
          );
          final reader = sqlite3.open(file);
          try {
            final stored = readSqliteBinding(reader);
            expect(
              stored,
              outcomes.first == 'bound'
                  ? _binding(_profileA)
                  : _binding(_profileA, documents),
              reason: 'round $round: $outcomes',
            );
          } finally {
            reader.close();
          }
        }
        // ignore: avoid_print
        print(
          'race: $round rounds; on time, the 2.0.1 writer won $oldWins and '
          'the 2.1 bind $newWins',
        );
        expect(oldWins, greaterThan(0), reason: 'the old writer never won');
        expect(newWins, greaterThan(0), reason: 'the 2.1 bind never won');
        db = sqlite3.open(path);
      });
    });
  });

  group('SqliteVectorStore binding integration', () {
    final skip = vec0SkipReason;
    late Directory temp;
    late String path;

    setUp(() {
      useHostNativeLibraries();
      temp = Directory.systemTemp.createTempSync('sqlite_profile_store');
      path = '${temp.path}/rag.db';
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('requires a binding, persists it, and clear preserves it', () async {
      final binding = _binding(_profileA, EmbeddingModality.image);
      var store = SqliteVectorStore();
      addTearDown(() => store.close());
      await store.initialize(path);

      expect(await store.readBinding(), isNull);
      await expectLater(
        store.addDocument(
          id: 'unbound',
          content: 'unsafe',
          embedding: const [1, 0, 0, 0],
        ),
        throwsStateError,
      );

      await store.bind(binding);
      await store.addDocument(
        id: 'doc',
        content: 'photo.jpg',
        embedding: const [1, 0, 0, 0],
      );
      await store.clear();
      expect(await store.readBinding(), binding);
      await expectLater(
        store.addDocument(
          id: 'wrong',
          content: 'wrong dimension',
          embedding: const [1, 0],
        ),
        throwsArgumentError,
      );
      await store.close();

      store = SqliteVectorStore();
      await store.initialize(path);
      expect(await store.readBinding(), binding);
      expect((await store.getStats()).documentCount, 0);
      await expectLater(
        store.bind(_binding(_profileA)),
        throwsA(isA<VectorStoreException>()),
      );
    }, skip: skip);

    test('a legacy shard is unbound until explicitly adopted', () async {
      final bootstrap = SqliteVectorStore();
      await bootstrap.initialize(path);
      await bootstrap.close();

      final raw = sqlite3.open(path);
      raw.execute('''
CREATE VIRTUAL TABLE vec_documents USING vec0(
  id TEXT PRIMARY KEY,
  embedding float[4] distance_metric=cosine,
  +content TEXT,
  +metadata TEXT
)
''');
      raw.execute(
        'INSERT INTO vec_documents(id, embedding, content, metadata) '
        "VALUES ('legacy', '[1,0,0,0]', 'legacy', NULL)",
      );
      raw.close();

      final store = SqliteVectorStore();
      addTearDown(store.close);
      await store.initialize(path);
      expect(await store.readBinding(), isNull);
      expect((await store.getStats()).documentCount, 1);

      await expectLater(
        store.bind(
          _binding(EmbeddingProfile(id: 'wrong-dimension-v1', dimension: 8)),
        ),
        throwsA(isA<VectorStoreException>()),
      );
      expect(await store.readBinding(), isNull);

      final binding = _binding(
        EmbeddingProfile(id: 'known-legacy-v1', dimension: 4),
      );
      await store.bind(binding);
      expect(await store.readBinding(), binding);
      await expectLater(
        store.bind(
          _binding(EmbeddingProfile(id: 'wrong-legacy-v1', dimension: 4)),
        ),
        throwsA(isA<VectorStoreException>()),
      );
    }, skip: skip);

    test('two concurrent opens of one location: one binding wins', () async {
      final rag = FlutterEdgeAiRag(
        providers: const [SqliteVectorStoreProvider()],
      );
      VectorStoreSpec spec(EmbeddingModality documents) => VectorStoreSpec(
        providerId: SqliteVectorStoreProvider.providerId,
        location: path,
        documents: documents,
      );

      final same = await Future.wait([
        rag.openVectors(spec: spec(EmbeddingModality.text), profile: _profileA),
        rag.openVectors(spec: spec(EmbeddingModality.text), profile: _profileA),
      ]);
      for (final index in same) {
        expect(index.embeddingProfile, _profileA);
        await index.dispose();
      }

      final otherPath = '${temp.path}/contended.db';
      Future<Object> attempt(EmbeddingModality documents) => rag
          .openVectors(
            spec: VectorStoreSpec(
              providerId: SqliteVectorStoreProvider.providerId,
              location: otherPath,
              documents: documents,
            ),
            profile: _profileA,
          )
          .then<Object>((index) => index, onError: (Object error) => error);
      final outcomes = await Future.wait([
        attempt(EmbeddingModality.text),
        attempt(EmbeddingModality.image),
      ]);
      final winners = outcomes.whereType<RagIndex>().toList();
      expect(winners, hasLength(1), reason: '$outcomes');
      expect(
        outcomes.where((o) => o is StateError || o is VectorStoreException),
        hasLength(1),
        reason: '$outcomes',
      );
      await winners.single.dispose();
    }, skip: skip);

    test(
      'a suspended bind cannot authorize the next database location',
      () async {
        final pathA = '${temp.path}/a.db';
        final pathB = '${temp.path}/b.db';
        final fenceEntered = Completer<void>();
        final releaseFence = Completer<void>();
        final bindingA = _binding(_profileA);
        final store = SqliteVectorStore(
          durabilityFenceForTesting: () async {
            fenceEntered.complete();
            await releaseFence.future;
          },
        );
        addTearDown(store.close);
        await store.initialize(pathA);

        final binding = store.bind(bindingA);
        await fenceEntered.future;
        final switchingToB = store.initialize(pathB);

        expect(store.isInitialized, isFalse);
        await expectLater(store.readBinding(), throwsStateError);
        await expectLater(
          store.addDocument(
            id: 'blocked-during-switch',
            content: 'blocked',
            embedding: const [1, 0, 0, 0],
          ),
          throwsStateError,
        );

        releaseFence.complete();
        await binding;
        await switchingToB;

        expect(await store.readBinding(), isNull);
        await expectLater(
          store.addDocument(
            id: 'must-not-use-a',
            content: 'unbound B',
            embedding: const [1, 0, 0, 0],
          ),
          throwsStateError,
        );

        final reopenedA = SqliteVectorStore();
        addTearDown(reopenedA.close);
        await reopenedA.initialize(pathA);
        expect(await reopenedA.readBinding(), bindingA);

        final reopenedB = SqliteVectorStore();
        addTearDown(reopenedB.close);
        await reopenedB.initialize(pathB);
        expect(await reopenedB.readBinding(), isNull);
      },
      skip: skip,
    );

    test('close waits for a suspended bind and clears its cache', () async {
      final fenceEntered = Completer<void>();
      final releaseFence = Completer<void>();
      final binding = _binding(_profileA);
      final store = SqliteVectorStore(
        durabilityFenceForTesting: () async {
          fenceEntered.complete();
          await releaseFence.future;
        },
      );
      addTearDown(store.close);
      await store.initialize(path);

      final binding0 = store.bind(binding);
      await fenceEntered.future;
      final closing = store.close();

      expect(store.isInitialized, isFalse);
      await expectLater(store.readBinding(), throwsStateError);
      releaseFence.complete();
      await binding0;
      await closing;

      expect(store.isInitialized, isFalse);
      await expectLater(store.readBinding(), throwsStateError);

      final reopened = SqliteVectorStore();
      addTearDown(reopened.close);
      await reopened.initialize(path);
      expect(await reopened.readBinding(), binding);
    }, skip: skip);
  });
}

/// flutter_edge_ai_sqlite 2.0.1's `bindSqliteEmbeddingProfile`, statement for
/// statement (lib/src/sqlite_profile_storage.dart of the published 2.0.1
/// archive): `BEGIN IMMEDIATE`, insert-or-nothing, read back, compare,
/// `COMMIT` — or `ROLLBACK` and refuse.
String oldWriterBind(Database db, String id, int dimension) {
  try {
    db.execute('BEGIN IMMEDIATE');
    db.execute(
      'INSERT INTO flutter_edge_ai_rag_profile '
      '(singleton, profile_id, dimension) VALUES (1, ?, ?) '
      'ON CONFLICT(singleton) DO NOTHING',
      [id, dimension],
    );
    final stored = oldWriterRead(db);
    if (stored != (id, dimension)) {
      throw StateError('already bound to $stored');
    }
    db.execute('COMMIT');
    return 'bound';
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    return 'refused';
  }
}

/// What a 2.0.1 reader sees: the version-1 row, as `(id, dimension)`.
(String, int)? oldWriterRead(Database db) {
  final rows = db.select(
    'SELECT singleton, profile_id, dimension FROM flutter_edge_ai_rag_profile',
  );
  if (rows.isEmpty) return null;
  return (rows.single['profile_id'] as String, rows.single['dimension'] as int);
}

// Top-level, so each closure captures only its arguments: a closure made
// inside a test captures the test's scope, sqlite handles included, and an
// isolate cannot be sent those.
typedef _RaceResult = ({String outcome, bool late});

Future<_RaceResult> _inIsolateOldWriter(String file, int startAt) =>
    Isolate.run(() => _raceOldWriter(file, startAt));

Future<_RaceResult> _inIsolateNewWriter(
  String file,
  EmbeddingModality documents,
  int startAt,
) => Isolate.run(() => _raceNewWriter(file, documents, startAt));

/// Spins until [startAt] (µs since epoch); true when it was already past.
bool _waitForStart(int startAt) {
  if (DateTime.now().microsecondsSinceEpoch > startAt) return true;
  while (DateTime.now().microsecondsSinceEpoch < startAt) {}
  return false;
}

/// Both racers wait for the database lock instead of failing on it, so each
/// reaches its own compare-and-set: the case the encoding has to get right.
Database _racerConnection(String file) =>
    sqlite3.open(file)..execute('PRAGMA busy_timeout = 10000');

_RaceResult _raceOldWriter(String file, int startAt) {
  final db = _racerConnection(file);
  try {
    final late = _waitForStart(startAt);
    return (outcome: oldWriterBind(db, 'embedder-a-v1', 4), late: late);
  } finally {
    db.close();
  }
}

Future<_RaceResult> _raceNewWriter(
  String file,
  EmbeddingModality documents,
  int startAt,
) async {
  final db = _racerConnection(file);
  final late = _waitForStart(startAt);
  try {
    await bindSqliteBinding(
      db,
      VectorStoreBinding(
        profile: EmbeddingProfile(id: 'embedder-a-v1', dimension: 4),
        documents: documents,
      ),
    );
    return (outcome: 'bound', late: late);
  } on VectorStoreException {
    return (outcome: 'refused', late: late);
  } finally {
    db.close();
  }
}
