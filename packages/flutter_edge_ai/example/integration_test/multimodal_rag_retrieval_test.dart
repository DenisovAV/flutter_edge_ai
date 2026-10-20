// The Multimodal RAG screen's retrieval with the real EmbeddingGemma 2 (740M):
// the sample notes, photos and voice memos go into three SQLite indexes
// through the screen's own MultimodalRagIndex, and every text query the Search
// tab suggests must rank its item first ACROSS the three kinds
// (multimodal_rag_ranking.dart: lift over each kind's median). Prints `[knowledge]`
// lines: per-item embedding times, per-query search times, the ranked lifts.
//
// No setUp/setUpAll (Rule 6b). Runs where the 740M runs natively:
//   flutter test integration_test/knowledge_retrieval_test.dart -d <device>
// Optional: --dart-define=MULTIMODAL_RAG_EMBEDDER_FILE=<a local copy of the
// bundle> (checked against the catalog's SHA-256), else it is downloaded
// (485 MB, ungated).
//
// On a Snapdragon 8 Elite Gen 5 (SM8850) NPU:
//   --dart-define=MULTIMODAL_RAG_EMBEDDER_MODEL=embeddingGemma2TextVisionAudio740mSm8850
// and, to compare its vectors with the CPU bundle's, first on the CPU (e.g.
// macOS) --dart-define=MULTIMODAL_RAG_VECTORS_OUT=<file>, then on the phone
// --dart-define=MULTIMODAL_RAG_VECTORS_GOLDEN=<that file, pushed>: prints each
// item's cosine to its CPU vector and each modality's embedding time.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/image_search/photo_preparation.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_app_dependencies.dart'
    show multimodalRagProfileId;
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_dependencies.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_index.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_item.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_library.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_widgets.dart'
    show kMultimodalRagSuggestions;
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _file = String.fromEnvironment('MULTIMODAL_RAG_EMBEDDER_FILE');
const _vectorsOut = String.fromEnvironment('MULTIMODAL_RAG_VECTORS_OUT');
const _vectorsGolden = String.fromEnvironment('MULTIMODAL_RAG_VECTORS_GOLDEN');
final _model = catalog.EmbeddingModel.values.byName(
  const String.fromEnvironment(
    'MULTIMODAL_RAG_EMBEDDER_MODEL',
    defaultValue: 'embeddingGemma2TextVisionAudio740m',
  ),
);

/// The item each suggested query must rank first.
const _expectedFirst = {
  'my flight is delayed': 'memo-flight',
  'the airport taxi receipt': 'photo-0412',
  'flickering lights': 'memo-kitchen',
  'market share chart': 'photo-0291',
  'fresh basil': 'memo-groceries',
  'revenue by quarter': 'note-q3',
  'a cooking class': 'memo-offsite',
};

void _log(String line) {
  // ignore: avoid_print
  print('[knowledge] $line');
}

Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<void> _ensureModel() async {
  await bootstrapGemma();
  final builder = FlutterEdgeAi.installEmbedder();
  if (_file.isNotEmpty) {
    final digest = await sha256.bind(File(_file).openRead()).first;
    expect('$digest', _model.sha256, reason: '$_file is not the pinned bundle');
    builder.modelFromFile(_file, filename: _model.filename);
  } else {
    builder.modelFromNetwork(_model.url, filename: _model.filename);
  }
  await builder.install();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every suggested query ranks its item first across notes, '
      'photos and voice memos', (tester) async {
    expect(_expectedFirst.keys, kMultimodalRagSuggestions);
    await _ensureModel();
    final directory = await Directory(
      '${(await getTemporaryDirectory()).path}/knowledge_retrieval_'
      '${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final info = MultimodalRagEmbedderInfo(
      name: _model.displayName,
      textProfileId: _model.ragProfileId,
      kinds: MultimodalRagKind.values.toSet(),
    );
    final watch = Stopwatch()..start();
    final index = await MultimodalRagIndex.open(
      kinds: info.kinds,
      embedderFor: (kind) => FlutterEdgeAiActiveEmbedder(
        profileId: multimodalRagProfileId(kind, info),
        preferredBackend: _model.embedderBackend,
        supportImage: true,
        supportAudio: true,
      ),
      openIndex: (kind, embedder) => exampleRag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: '${directory.path}/${kind.name}.db',
          documents: kind.modality,
        ),
        embedder: embedder,
      ),
    );
    _log('opened (model loaded) in ${watch.elapsedMilliseconds} ms');
    try {
      final times = <MultimodalRagKind, List<int>>{};
      for (final item in MultimodalRagLibrary.seeded().items) {
        final took = switch (item) {
          NoteItem() => await index.addNote(item),
          PhotoItem(:final reference) => await index.addPhoto(
            item,
            (await preparePhotoForEmbedding(
              await _asset(reference.substring('asset:'.length)),
            )).bytes,
          ),
          MemoItem(:final reference) => await index.addMemo(
            item,
            await _asset(reference.substring('asset:'.length)),
          ),
        };
        (times[item.kind] ??= []).add(took.inMilliseconds);
      }
      for (final MapEntry(key: kind, value: ms) in times.entries) {
        final sorted = [...ms]..sort();
        _log(
          '${kind.plural}: ${ms.length}, embed median '
          '${sorted[sorted.length ~/ 2]} ms, first ${ms.first} ms',
        );
      }
      final misses = <String>[];
      for (final MapEntry(key: query, value: expected)
          in _expectedFirst.entries) {
        watch.reset();
        final hits = await index.search(query);
        final ms = watch.elapsedMilliseconds;
        _log(
          '"$query" ($ms ms): '
          '${[for (final h in hits) '${h.id} ${h.lift.toStringAsFixed(3)}'].join(', ')}',
        );
        if (hits.isEmpty || hits.first.id != expected) {
          misses.add('"$query" → ${hits.firstOrNull?.id}, not $expected');
        }
      }
      if (_vectorsOut.isNotEmpty || _vectorsGolden.isNotEmpty) {
        await _compareVectors();
      }
      expect(misses, isEmpty);
    } finally {
      await index.dispose();
    }
  });
}

/// Every sample item's vector from the active embedder: written to
/// [_vectorsOut], and/or compared with [_vectorsGolden] (cosine per item,
/// summarized per kind), with each modality's embedding time.
Future<void> _compareVectors() async {
  final embedder = await FlutterEdgeAi.getActiveEmbedder(
    preferredBackend: _model.embedderBackend,
    supportImage: true,
    supportAudio: true,
  );
  _log('vectors from ${_model.name} on ${embedder.activeBackend}');
  final vectors = <String, List<double>>{};
  final times = <MultimodalRagKind, List<int>>{};
  for (final item in MultimodalRagLibrary.seeded().items) {
    final input = switch (item) {
      NoteItem(:final title, :final body) => EmbeddingInput.text(
        '$title. $body',
      ),
      PhotoItem(:final reference) => EmbeddingInput.image(
        (await preparePhotoForEmbedding(
          await _asset(reference.substring('asset:'.length)),
        )).bytes,
      ),
      MemoItem(:final reference) => EmbeddingInput.audio(
        await _asset(reference.substring('asset:'.length)),
      ),
    };
    final watch = Stopwatch()..start();
    vectors[item.id] = await embedder.embed(input, taskType: TaskType.none);
    (times[item.kind] ??= []).add(watch.elapsedMilliseconds);
  }
  for (final MapEntry(key: kind, value: ms) in times.entries) {
    final sorted = [...ms]..sort();
    _log(
      'embed ${kind.plural}: median ${sorted[sorted.length ~/ 2]} ms, '
      'all ${ms.join(', ')}',
    );
  }
  if (_vectorsOut.isNotEmpty) {
    await File(_vectorsOut).writeAsString(jsonEncode(vectors));
    _log('vectors written to $_vectorsOut');
  }
  if (_vectorsGolden.isEmpty) return;
  final golden = (jsonDecode(await File(_vectorsGolden).readAsString()) as Map)
      .cast<String, List<dynamic>>();
  final byKind = <MultimodalRagKind, List<double>>{};
  for (final item in MultimodalRagLibrary.seeded().items) {
    final reference = golden[item.id]?.cast<num>();
    if (reference == null) continue;
    final a = vectors[item.id]!;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * reference[i];
      na += a[i] * a[i];
      nb += reference[i] * reference[i];
    }
    final cosine = dot / math.sqrt(na * nb);
    (byKind[item.kind] ??= []).add(cosine);
    _log('parity ${item.id}: cosine ${cosine.toStringAsFixed(4)}');
  }
  for (final MapEntry(key: kind, value: cosines) in byKind.entries) {
    final sorted = [...cosines]..sort();
    _log(
      'parity ${kind.plural}: min ${sorted.first.toStringAsFixed(4)}, '
      'median ${sorted[sorted.length ~/ 2].toStringAsFixed(4)}',
    );
  }
}
