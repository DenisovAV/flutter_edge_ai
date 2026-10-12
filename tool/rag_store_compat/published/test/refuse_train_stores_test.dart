// The downgrade half of R5 §6.5: flutter_edge_ai_rag 1.0.0 with
// flutter_edge_ai_sqlite / flutter_edge_ai_qdrant 2.0.1 — the published
// releases — must refuse every image or audio store the train wrote, empty or
// not, with or without allowLegacyProfileAdoption, and must not be able to
// rebind one. They must still open the train's TEXT stores (the positive
// control: a harness that refuses everything proves nothing).
//
// Every store is bound to the same profile (compat-v1, 4D) that the checks
// below ask for, so the document modality is the only thing that can make an
// open fail. Run by ../run_downgrade_harness.sh after the train side wrote
// $RAG_COMPAT_STORES/manifest.json.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support.dart';

typedef _Entry = ({
  String backend,
  String name,
  String location,
  EmbeddingProfile profile,
  String documents,
  int documentCount,
});

/// The manifest is read while tests are REGISTERED, so a missing one fails the
/// load — loudly — instead of registering nothing.
List<_Entry> _manifest() {
  final root = requireEnv('RAG_COMPAT_STORES');
  final raw = jsonDecode(
    File(p.join(root, 'manifest.json')).readAsStringSync(),
  );
  return [
    for (final entry in (raw as List).cast<Map<String, Object?>>())
      (
        backend: entry['backend']! as String,
        name: entry['name']! as String,
        location: entry['location']! as String,
        profile: EmbeddingProfile(
          id: entry['profileId']! as String,
          dimension: entry['dimension']! as int,
        ),
        documents: entry['documents']! as String,
        documentCount: entry['documentCount']! as int,
      ),
  ];
}

FlutterEdgeAiRag _rag() => FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider(), QdrantVectorStoreProvider()],
);

VectorStoreRepository _store(String backend) =>
    backend == 'sqlite' ? SqliteVectorStore() : QdrantVectorStore();

/// rag 1.0's custom-embedder path: the same profile, text in, a 4D vector out.
class _CompatEmbedder implements RagEmbedder {
  _CompatEmbedder(this._profile);

  final EmbeddingProfile _profile;

  @override
  Future<EmbeddingProfile> get profile async => _profile;

  @override
  Future<List<double>> embedDocument(String text) async => const [0, 0, 1, 0];

  @override
  Future<List<double>> embedQuery(String text) async => const [0, 1, 0, 0];
}

/// A refusal is the exception the 1.0 contract defines for this situation,
/// raised BECAUSE of the qualified binding id: a refusal for any other reason
/// (a shard still locked by an earlier check, say) proves nothing. Every
/// refusal is printed, so the run log records how each path refused.
Future<void> _expectRefused(
  String label,
  String qualifiedId,
  Future<void> Function() run,
) async {
  try {
    await run();
  } on Object catch (error) {
    expect(error, anyOf(isA<StateError>(), isA<VectorStoreException>()));
    expect(
      error.toString(),
      contains(qualifiedId),
      reason: '$label must refuse over the qualified binding id',
    );
    // ignore: avoid_print
    print(
      'REFUSED $label: ${error.runtimeType}: '
      '${error.toString().split('\n').first}',
    );
    return;
  }
  fail('$label: rag 1.0 / store 2.0.1 accepted it');
}

void main() {
  // Both run while tests are registered: a missing manifest or vec0 library
  // fails the load instead of registering nothing.
  final entries = _manifest();
  useHostVec0();
  test('the manifest names a media and a text store per backend', () {
    for (final backend in ['sqlite', 'qdrant']) {
      final mine = entries.where((e) => e.backend == backend);
      expect(mine.map((e) => e.documents).toSet(), {'text', 'image', 'audio'});
      expect(
        mine.where((e) => e.documents != 'text').map((e) => e.documentCount),
        containsAll([0, 2]),
        reason: 'an empty media store must be refused too (R5 §6.5)',
      );
    }
  });

  for (final entry in entries) {
    final label = '${entry.backend} ${entry.name} (${entry.documents})';
    final spec = VectorStoreSpec(
      providerId: entry.backend,
      location: entry.location,
    );
    final adopting = VectorStoreSpec(
      providerId: entry.backend,
      location: entry.location,
      allowLegacyProfileAdoption: true,
    );

    if (entry.documents == 'text') {
      group('$label opens in rag 1.0', () {
        test('with the profile', () async {
          final index = await _rag().open(
            spec: spec,
            embeddingProfile: entry.profile,
          );
          expect((await index.stats()).documentCount, entry.documentCount);
          final hits = await index.searchVector(embedding: const [0, 1, 0, 0]);
          expect(hits.first.id, 'doc-b');
          await index.dispose();
        });

        test('with an embedder', () async {
          final index = await _rag().open(
            spec: spec,
            embedder: _CompatEmbedder(entry.profile),
          );
          final hits = await index.searchText(query: 'beta');
          expect(hits.first.id, 'doc-b');
          await index.dispose();
        });
      });
      continue;
    }

    final qualifiedId = '${entry.profile.id}\u001F${entry.documents}';
    group('$label is refused by rag 1.0', () {
      // Whatever an attempt opened is disposed: an accepted open must not
      // leave a qdrant WAL locked for the next check.
      Future<void> refusedOpen(String what, VectorStoreSpec at) async {
        RagIndex? index;
        try {
          await _expectRefused('$label $what', qualifiedId, () async {
            index = await _rag().open(
              spec: at,
              embeddingProfile: entry.profile,
            );
          });
        } finally {
          await index?.dispose();
        }
      }

      test('open with the profile', () => refusedOpen('open(profile)', spec));

      test(
        'open with the profile and allowLegacyProfileAdoption',
        () => refusedOpen('open(profile, adopt)', adopting),
      );

      test('open with an embedder: no text operation succeeds', () async {
        RagIndex? index;
        try {
          await _expectRefused(
            '$label open(embedder) + addText',
            qualifiedId,
            () async {
              index = await _rag().open(
                spec: adopting,
                embedder: _CompatEmbedder(entry.profile),
              );
              await index!.addText(id: 'old-writer', content: 'must not land');
            },
          );
          if (index case final opened?) {
            await _expectRefused(
              '$label searchText',
              qualifiedId,
              () => opened.searchText(query: 'beta'),
            );
          }
        } finally {
          await index?.dispose();
        }
      });

      test('the store reads the qualified id and refuses a rebind', () async {
        final store = _store(entry.backend);
        try {
          await store.initialize(entry.location);
          expect(
            (await store.readEmbeddingProfile())?.id,
            qualifiedId,
            reason: 'a 2.0 reader sees the qualified id, never the profile',
          );
          await _expectRefused(
            '$label store bind',
            qualifiedId,
            () => store.bindEmbeddingProfile(entry.profile),
          );
        } finally {
          await store.close();
        }
      });
    });
  }
}
