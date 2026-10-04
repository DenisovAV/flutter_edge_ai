// 0.15.2 RAG smoke test — both embedding model families.
//
// Loads models from local files (~/Downloads/) to skip the download +
// HuggingFace auth flow and exercise just the embedding inference path.
//
// On Android the test pushes the files into the app sandbox via
// adb-style `getApplicationDocumentsDirectory()` staging, then loads
// them by absolute path through FlutterEdgeAi.installEmbedder().fromFile.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

// Pre-stage these files in the platform sandbox before running:
//   macOS: ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/
//   Android: adb push <file> /data/data/dev.flutterberlin.flutter_gemma_example/app_flutter/
// On both platforms `getApplicationDocumentsDirectory()` resolves to that
// location, so the test reads from there directly via fromFile().
const _geckoModelName = 'Gecko_64_quant.tflite';
const _geckoTokenizerName = 'gecko_sentencepiece.model';
const _gemmaModelName = 'embeddinggemma-300M_seq256_mixed-precision.tflite';
const _gemmaTokenizerName = 'sentencepiece.model';

// Fixtures from issue #264.
const _queries = ['climate change', 'global warming', 'pizza recipe'];
const _docs = [
  'Renewable energy is reshaping the global power grid.',
  'A classic margherita pizza needs only flour, tomato, and basil.',
  'Stock markets reacted sharply to the central bank announcement.',
];

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// Resolve a file path in the app documents directory. If absent, copy
/// from the bundled `assets/test/<name>` (works on every platform).
Future<String> _docsPath(String name) async {
  final docs = await getApplicationDocumentsDirectory();
  final f = File('${docs.path}/$name');
  if (f.existsSync()) return f.path;
  final bytes = await rootBundle.load('assets/test/$name');
  await f.writeAsBytes(bytes.buffer.asUint8List());
  return f.path;
}

Future<void> _exercise(String label, EmbeddingModel model) async {
  final dim = await model.getDimension();
  expect(dim, 768);
  print('[$label] dim=$dim');

  final q = await model.generateEmbedding(_queries[0]);
  expect(q.length, 768);
  expect(q.where((v) => v != 0).length, greaterThan(700));

  // Self-consistency.
  final q2 = await model.generateEmbedding(_queries[0]);
  expect(_cosine(q, q2), greaterThan(0.99999));

  // TaskType.prefix wires.
  final qSame = await model.generateEmbedding(_queries[0]);
  final dSame = await model.generateEmbedding(
    _queries[0],
    taskType: TaskType.retrievalDocument,
  );
  final cosTypes = _cosine(qSame, dSame);
  print(
    '[$label] cosine(query vs doc, same text) = '
    '${cosTypes.toStringAsFixed(4)}',
  );
  expect(cosTypes, lessThan(0.999));

  // Semantic gradient (log only).
  final qWarm = await model.generateEmbedding(_queries[1]);
  final qPizza = await model.generateEmbedding(_queries[2]);
  print(
    '[$label] cosine(climate, global_warming) = '
    '${_cosine(q, qWarm).toStringAsFixed(4)}',
  );
  print(
    '[$label] cosine(climate, pizza)          = '
    '${_cosine(q, qPizza).toStringAsFixed(4)}',
  );

  // Batch == single.
  final batch = await model.generateEmbeddings(
    _docs,
    taskType: TaskType.retrievalDocument,
  );
  for (var i = 0; i < _docs.length; i++) {
    final single = await model.generateEmbedding(
      _docs[i],
      taskType: TaskType.retrievalDocument,
    );
    expect(_cosine(batch[i], single), greaterThan(0.99999));
  }

  // Tiny RAG ranking.
  final qVecs = await model.generateEmbeddings(_queries);
  for (var i = 0; i < _queries.length; i++) {
    var bestIdx = 0, bestCos = -1.0;
    for (var j = 0; j < _docs.length; j++) {
      final c = _cosine(qVecs[i], batch[j]);
      if (c > bestCos) {
        bestCos = c;
        bestIdx = j;
      }
    }
    print(
      '[$label] best match for "${_queries[i]}" → '
      '"${_docs[bestIdx]}" (cos=${bestCos.toStringAsFixed(3)})',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Gecko 110M — full RAG flow', (_) async {
    await registerTestEngines();
    await FlutterEdgeAi.installEmbedder()
        .modelFromFile(await _docsPath(_geckoModelName))
        .tokenizerFromFile(await _docsPath(_geckoTokenizerName))
        .install();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    try {
      await _exercise('Gecko64', model);
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
    'EmbeddingGemma 256 — full RAG flow',
    (_) async {
      await registerTestEngines();
      await FlutterEdgeAi.installEmbedder()
          .modelFromFile(await _docsPath(_gemmaModelName))
          .tokenizerFromFile(await _docsPath(_gemmaTokenizerName))
          .install();
      final model = await FlutterEdgeAi.getActiveEmbedder();
      try {
        await _exercise('EmbeddingGemma256', model);
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
