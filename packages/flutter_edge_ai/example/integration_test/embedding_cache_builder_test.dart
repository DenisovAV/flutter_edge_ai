// Embed a slice of the deterministic 5000-lorem-chunk corpus and append
// the resulting 768D vectors into a JSON cache on disk. Designed to be
// run multiple times with different slice bounds (RANGE_FROM/RANGE_TO)
// because the Windows desktop integration_test runner has a hard ~3:20
// kill that prevents a single 5000-call loop from finishing.
//
// Usage:
//   cd example
//   flutter test --ignore-timeouts \
//     --dart-define=RANGE_FROM=0 --dart-define=RANGE_TO=2500 \
//     integration_test/embedding_cache_builder_test.dart -d windows
//   flutter test --ignore-timeouts \
//     --dart-define=RANGE_FROM=2500 --dart-define=RANGE_TO=5000 \
//     integration_test/embedding_cache_builder_test.dart -d windows
//
// Output: <ApplicationSupportDirectory>/embeddings_cache_5000_768d.json
//   On the first run the file is created with `count = 5000` placeholder
//   slots and the requested slice is filled. Subsequent runs read the
//   existing file, fill their slice, and write back. When `RANGE_TO` ==
//   `TOTAL_DOCS` the file is considered complete.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath =
    'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerPath = 'assets/models/sentencepiece.model';

const _totalDocs = 5000;
const _expectedDim = 768;

// Slice bounds — overridden via --dart-define for batched runs.
const _rangeFrom = int.fromEnvironment('RANGE_FROM', defaultValue: 0);
const _rangeTo = int.fromEnvironment('RANGE_TO', defaultValue: _totalDocs);

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
  binding.defaultTestTimeout = const Timeout(Duration(hours: 2));

  testWidgets('build embedding cache slice [$_rangeFrom..$_rangeTo)', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      expect(
        _rangeFrom < _rangeTo,
        isTrue,
        reason: 'RANGE_FROM must be < RANGE_TO',
      );
      expect(
        _rangeTo <= _totalDocs,
        isTrue,
        reason: 'RANGE_TO must be <= $_totalDocs',
      );

      await registerTestEngines();
      await FlutterEdgeAi.installEmbedder()
          .modelFromAsset(_modelPath)
          .tokenizerFromAsset(_tokenizerPath)
          .install();
      final embedder = await FlutterEdgeAi.getActiveEmbedder();

      // Always regenerate the full deterministic text list — same seed
      // produces the same texts regardless of slice.
      final rng = math.Random(42);
      final texts = List.generate(
        _totalDocs,
        (_) => _chunk(rng, 30 + rng.nextInt(50)),
      );
      // ignore: avoid_print
      print(
        '[cache] full corpus regenerated (seed=42), '
        'slice [$_rangeFrom..$_rangeTo)',
      );

      // Load existing cache or initialize a fresh placeholder list.
      final base = await getApplicationSupportDirectory();
      final cacheFile = File(
        '${base.path}/embeddings_cache_${_totalDocs}_${_expectedDim}d.json',
      );
      List<List<double>?> slots;
      Map<String, dynamic> meta;
      if (cacheFile.existsSync()) {
        final raw =
            jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
        meta = raw;
        slots = (raw['vectors'] as List).map((v) {
          if (v is List && v.isNotEmpty) {
            return v.cast<num>().map((e) => e.toDouble()).toList();
          }
          return null;
        }).toList();
        // ignore: avoid_print
        print(
          '[cache] loaded existing file with '
          '${slots.where((s) => s != null).length}/${slots.length} slots filled',
        );
      } else {
        slots = List<List<double>?>.filled(_totalDocs, null);
        meta = <String, dynamic>{
          'count': _totalDocs,
          'dim': _expectedDim,
          'seed': 42,
          'corpus_chars_per_doc_avg':
              (texts.fold<int>(0, (s, t) => s + t.length) / texts.length)
                  .round(),
        };
        // ignore: avoid_print
        print('[cache] no existing file — initialized $_totalDocs empty slots');
      }

      final sw = Stopwatch()..start();
      for (var i = _rangeFrom; i < _rangeTo; i++) {
        slots[i] = await embedder.generateEmbedding(texts[i]);
        if ((i - _rangeFrom + 1) % 100 == 0) {
          // ignore: avoid_print
          print(
            '[cache] embedded ${i + 1} '
            '(${sw.elapsed.inSeconds}s elapsed for slice)',
          );
        }
      }
      sw.stop();
      // ignore: avoid_print
      print('[cache] slice complete in ${sw.elapsed.inSeconds}s');

      // Persist: replace empty placeholder slots with [] for missing
      // entries (so JSON encoder doesn't choke on nulls) and write.
      meta['vectors'] = slots.map((v) => v ?? const <double>[]).toList();
      cacheFile.writeAsStringSync(jsonEncode(meta));
      final filled = slots.where((s) => s != null && s.isNotEmpty).length;
      // ignore: avoid_print
      print(
        '[cache] written: ${cacheFile.path} — $filled/$_totalDocs slots filled',
      );
    });
  });
}
