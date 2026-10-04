// Minimal repro: 500 sequential EmbeddingGemma calls with LONG texts
// (lorem chunks, ~50-150 tokens each — same shape as our bench).
//
// Run:
//   cd example && flutter test integration_test/embedding_loop_repro_test.dart -d windows

import 'dart:math' as math;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath =
    'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerPath = 'assets/models/sentencepiece.model';

// Same word pool the real bench uses.
const _loremWords = [
  'lorem',
  'ipsum',
  'dolor',
  'sit',
  'amet',
  'consectetur',
  'adipiscing',
  'elit',
  'sed',
  'do',
  'eiusmod',
  'tempor',
  'incididunt',
  'ut',
  'labore',
  'magna',
  'aliqua',
  'enim',
  'ad',
  'minim',
  'veniam',
  'quis',
  'nostrud',
  'exercitation',
  'ullamco',
  'laboris',
  'nisi',
  'aliquip',
  'ex',
  'ea',
  'commodo',
  'consequat',
  'duis',
  'aute',
  'irure',
  'in',
  'reprehenderit',
  'voluptate',
  'velit',
  'esse',
  'cillum',
  'dolore',
  'eu',
  'fugiat',
  'nulla',
  'pariatur',
  'excepteur',
  'sint',
  'occaecat',
  'cupidatat',
  'non',
  'proident',
  'sunt',
  'culpa',
  'qui',
  'officia',
  'deserunt',
  'mollit',
  'anim',
  'id',
  'laborum',
  'curabitur',
  'pretium',
  'tincidunt',
  'lacus',
  'gravida',
  'orci',
  'a',
  'odio',
  'nullam',
  'varius',
  'turpis',
  'et',
];

String _chunk(math.Random rng, int wordCount) {
  final words = List.generate(
    wordCount,
    (_) => _loremWords[rng.nextInt(_loremWords.length)],
  );
  return words.join(' ');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultTestTimeout = const Timeout(Duration(minutes: 30));

  testWidgets('embed 500 long lorem chunks', (WidgetTester tester) async {
    await registerTestEngines();
    await FlutterEdgeAi.installEmbedder()
        .modelFromAsset(_modelPath)
        .tokenizerFromAsset(_tokenizerPath)
        .install();
    final embedder = await FlutterEdgeAi.getActiveEmbedder();

    final rng = math.Random(42);
    final texts = List.generate(500, (_) => _chunk(rng, 30 + rng.nextInt(50)));
    // ignore: avoid_print
    print(
      '[repro] generated 500 lorem chunks, avg ${(texts.fold<int>(0, (s, t) => s + t.length) / texts.length).round()} chars',
    );

    final sw = Stopwatch()..start();
    for (var i = 0; i < texts.length; i++) {
      final v = await embedder.generateEmbedding(texts[i]);
      if ((i + 1) % 25 == 0) {
        // ignore: avoid_print
        print(
          '[repro] embedded ${i + 1}/500 (${sw.elapsed.inMilliseconds}ms, dim=${v.length})',
        );
      }
    }
    sw.stop();
    // ignore: avoid_print
    print('[repro] total: ${sw.elapsed.inSeconds}s');
  });
}
