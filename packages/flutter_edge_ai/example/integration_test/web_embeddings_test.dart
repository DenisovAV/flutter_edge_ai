/// Web embeddings through the app API (R5 §10.1 "Web"): EmbeddingGemma 1 on
/// LiteRT.js (bundle API v2) and all-MiniLM-L6-v2 on ONNX Runtime Web, both
/// through `FlutterEdgeAi.getActiveEmbedder()` on core's inline host, with
/// `WebStorageMode.cacheApi` (the default). The `WebStorageMode.streaming`
/// cases are web_embeddings_streaming_test.dart: the storage mode is fixed for
/// the life of the page.
///
/// GCE VM only (never a local browser). Run from packages/flutter_edge_ai/example:
///   chromedriver --port=4444 &
///   flutter drive \
///     --driver=test_driver/web_embeddings_driver.dart \
///     --target=integration_test/web_embeddings_test.dart \
///     -d web-server --browser-name=chrome --headless \
///     --dart-define=HUGGINGFACE_TOKEN=hf_...
/// then the same with `-d chrome`. EG1 is gated on Hugging Face; instead of
/// the token, `--dart-define=EG1_MODEL_URL=…` serves the same file from
/// elsewhere (see web_embeddings_support.dart). MiniLM is ungated.
///
/// The driver writes this suite's data to `build/web_embeddings_response.json`
/// even when a test fails — the W1 comparison (`w1`), the ids bundle API v1
/// ran for its two prefixes (`w1_v1`, for the record) and the accelerator.
/// The streaming suite writes its own file, so running both keeps both.
///
/// Rule 6b: no setUp/setUpAll — every fallible step is a guarded helper
/// called inside the test body, and the last test checks that every test
/// before it started. After a green run, confirm the report lists all of them.
@TestOn('chrome')
library;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'web_embeddings_support.dart';

/// Every test in this file, in order; the last one checks they all started.
const _tests = [
  'EG1 eager load',
  'EG1 vectors',
  'EG1 empty text',
  'W1',
  'W1 record v1',
  'EG1 overflow',
  'EG1 close and recreate',
  'stale bundle',
  '.litertlm refused',
  'MiniLM vectors',
  'MiniLM close and recreate',
];

/// EG1 installed and active; a loaded model from `getActiveEmbedder()`.
Future<EmbeddingModel> _ensureEg1() async {
  await ensureInitialized(WebStorageMode.cacheApi);
  await installEg1(tokenizerFromAsset: true);
  return FlutterEdgeAi.getActiveEmbedder();
}

/// MiniLM installed and active; a loaded model from `getActiveEmbedder()`.
Future<EmbeddingModel> _ensureMiniLm() async {
  await ensureInitialized(WebStorageMode.cacheApi);
  await installMiniLm();
  return FlutterEdgeAi.getActiveEmbedder();
}

void _start(String name) {
  expect(_tests, contains(name));
  startedTests.add(name);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reportTo('web_embeddings_response');

  group('EmbeddingGemma 1 on LiteRT.js', () {
    testWidgets(
      'eager load: getActiveEmbedder returns a LOADED model — 768 dims, the '
      'model\'s 256-token limit — before any embed call',
      (tester) async {
        _start('EG1 eager load');
        expect(bundleApiVersion, 2, reason: 'web/litert_embeddings.js is v1');
        // Close whatever an earlier run left, so this load is the one seen.
        await (await _ensureEg1()).close();
        expect(bundleInitialized, isFalse, reason: 'close disposed the page');

        final model = await FlutterEdgeAi.getActiveEmbedder();

        expect(
          bundleInitialized,
          isTrue,
          reason: 'loaded in getActiveEmbedder, not on the first embed',
        );
        expect(model.dimension, 768);
        expect(model.maxInputTokens, 256);
        expect(model.modalities, {EmbeddingModality.text});
        expect(model.activeBackend, isNull, reason: 'unknown, never CPU');
      },
      timeout: const Timeout(Duration(minutes: 20)),
    );

    testWidgets('768-d unit vectors; query and document differ; all nine '
        'task types differ', (tester) async {
      _start('EG1 vectors');
      final model = await _ensureEg1();
      const text = 'Which planet is known as the Red Planet?';
      final query = await model.embed(
        EmbeddingInput.text(text),
        taskType: TaskType.retrievalQuery,
      );
      final document = await model.embed(
        EmbeddingInput.text(text),
        taskType: TaskType.retrievalDocument,
      );
      expectUnitVector(query, 768, what: 'query');
      expectUnitVector(document, 768, what: 'document');
      expect(cosine(query, document), lessThan(0.99999));
      await expectEveryTaskTypeDistinct(model, text);
      report('eg1_accelerator', bundleAccelerator());
    });

    testWidgets('empty and whitespace-only text embed, as on native '
        '(the prefix, BOS and EOS)', (tester) async {
      _start('EG1 empty text');
      final model = await _ensureEg1();
      for (final text in ['', '   ', '\n']) {
        expectUnitVector(
          await model.embed(
            EmbeddingInput.text(text),
            taskType: TaskType.retrievalQuery,
          ),
          768,
          what: '"$text"',
        );
      }
    });

    testWidgets('W1: tokenizeLiteRtText(prefix + text) equals the native ids '
        'for 40 strings x 9 task types', (tester) async {
      _start('W1');
      await _ensureEg1();
      final strings = w1Strings;
      expect(strings, hasLength(40), reason: 'the golden is empty or cut');
      final mismatches = <Map<String, Object?>>[];
      var compared = 0;
      for (final type in TaskType.values) {
        final native = w1NativeIds(type);
        for (final (i, (name, text)) in strings.indexed) {
          final web = bundleTokenize(type.prefix + text);
          compared++;
          if (!_sameIds(web, native[i])) {
            mismatches.add({
              'taskType': type.name,
              'string': name,
              'native': native[i],
              'web': web,
            });
          }
        }
      }
      report('w1', {
        'compared': compared,
        'equal': compared - mismatches.length,
        'mismatches': mismatches,
      });
      expect(compared, 360);
      expect(
        mismatches,
        isEmpty,
        reason:
            '${mismatches.length} of 360 web id sequences differ from native '
            '(first: ${mismatches.isEmpty ? '' : mismatches.first}); all are '
            'in build/web_embeddings_response.json under "w1"',
      );
    });

    testWidgets('W1 record: what bundle API v1 ran for its two prefixes, '
        'next to native (recorded, not asserted)', (tester) async {
      _start('W1 record v1');
      await _ensureEg1();
      // v1 tokenized the prefix and "▁" + text SEPARATELY:
      // [2, ...encode(prefix), ...encode("▁" + text), 1], cut to the sequence
      // length, and refused blank text. Its SentencePiece is the same build:
      // the v1 and v2 bundles share a byte-identical sentencepiece.js chunk
      // (sha256 49c25b90…), so v2's tokenizer reproduces v1's ids exactly.
      List<int> content(String s) {
        final ids = bundleTokenize(s);
        return ids.sublist(1, ids.length - 1);
      }

      final record = <String, Object?>{};
      for (final type in [
        TaskType.retrievalQuery,
        TaskType.retrievalDocument,
      ]) {
        final native = w1NativeIds(type);
        final equal = <String>[];
        final differ = <Map<String, Object?>>[];
        final refused = <String>[];
        for (final (i, (name, text)) in w1Strings.indexed) {
          if (text.trim().isEmpty) {
            refused.add(name);
            continue;
          }
          final v1 = [
            2,
            ...content(type.prefix),
            ...content('▁$text'),
            1,
          ].take(256).toList();
          if (_sameIds(v1, native[i])) {
            equal.add(name);
          } else {
            differ.add({'string': name, 'native': native[i], 'v1': v1});
          }
        }
        record[type.name] = {
          'equalToNative': equal,
          'refusedByV1': refused,
          'differFromNative': differ,
        };
        // ignore: avoid_print
        print(
          '[W1 v1] ${type.name}: ${equal.length} equal native, '
          '${differ.length} differ, ${refused.length} refused (blank)',
        );
      }
      report('w1_v1', record);
    });

    testWidgets('an over-long input is EmbeddingInputTooLongException with the '
        'native count, and the model keeps working', (tester) async {
      _start('EG1 overflow');
      final model = await _ensureEg1();
      final overflow = w1Overflow;
      await expectLater(
        model.embed(
          EmbeddingInput.text(overflow.text),
          taskType: overflow.taskType,
        ),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 256)
              .having(
                (e) => e.actualTokens,
                'actualTokens',
                overflow.nativeTokenCount,
              ),
        ),
      );
      expectUnitVector(
        await model.embed(
          EmbeddingInput.text('still working'),
          taskType: TaskType.retrievalQuery,
        ),
        768,
        what: 'after the overflow',
      );
    });

    testWidgets('close and recreate on the page lane: a close still running '
        'while the next embedder loads leaves the new one its page state', (
      tester,
    ) async {
      _start('EG1 close and recreate');
      final model = await _ensureEg1();
      final input = EmbeddingInput.text('The cat sat on the mat.');
      final before = await model.embed(input, taskType: TaskType.none);

      final closing = model.close(); // not awaited before the next load
      final next = await FlutterEdgeAi.getActiveEmbedder();
      await closing;

      expect(model.isClosed, isTrue);
      expect(identical(next, model), isFalse);
      expect(bundleInitialized, isTrue, reason: 'the old close disposed it');
      final after = await next.embed(input, taskType: TaskType.none);
      expect(cosine(before, after), closeTo(1.0, 1e-5));
    });

    testWidgets('a stale litert_embeddings.js (no API version) fails the load '
        'with the named EmbeddingLoadException', (tester) async {
      _start('stale bundle');
      await (await _ensureEg1()).close();
      bundleApiVersion = null; // what a v1 copy looks like to the pass
      try {
        await expectLater(
          FlutterEdgeAi.getActiveEmbedder(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.engine, 'engine', 'LiteRT.js')
                .having(
                  (e) => e.message,
                  'message',
                  contains(
                    'web/litert_embeddings.js is older than '
                    'flutter_edge_ai_litertlm 1.13.0; copy '
                    'packages/flutter_edge_ai_litertlm/web/'
                    'litert_embeddings.js into your web/',
                  ),
                ),
          ),
        );
        expect(bundleInitialized, isFalse, reason: 'nothing was loaded');
      } finally {
        bundleApiVersion = 2;
      }
      expect((await FlutterEdgeAi.getActiveEmbedder()).dimension, 768);
    });
  });

  testWidgets('a .litertlm embedder is refused at install, before any '
      'download', (tester) async {
    _start('.litertlm refused');
    await ensureInitialized(WebStorageMode.cacheApi);
    final activeBefore = FlutterEdgeAi.activeEmbedderSpec?.name;
    final watch = Stopwatch()..start();
    await expectLater(
      FlutterEdgeAi.installEmbedder()
          // Port 9 (discard): a download attempt would fail as a network
          // error, never as the UnsupportedError below.
          .modelFromNetwork('http://127.0.0.1:9/embeddinggemma-2.litertlm')
          .install(),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('No registered embedding backend can run'),
        ),
      ),
    );
    report('litertlm_refused_ms', watch.elapsedMilliseconds);
    expect(FlutterEdgeAi.activeEmbedderSpec?.name, activeBefore);
  });

  group('all-MiniLM-L6-v2 on ONNX Runtime Web', () {
    testWidgets(
      'eager load; 384-d unit vectors; no declared limit (dynamic graph); '
      'query and document differ; all nine task types differ',
      (tester) async {
        _start('MiniLM vectors');
        final model = await _ensureMiniLm();
        expect(model.dimension, 384, reason: 'reported by the load');
        expect(model.maxInputTokens, isNull, reason: 'dynamic-shape graph');
        const text = 'The cat sat on the mat.';
        final query = await model.embed(
          EmbeddingInput.text(text),
          taskType: TaskType.retrievalQuery,
        );
        final document = await model.embed(
          EmbeddingInput.text(text),
          taskType: TaskType.retrievalDocument,
        );
        expectUnitVector(query, 384, what: 'query');
        expect(cosine(query, document), lessThan(0.99999));
        await expectEveryTaskTypeDistinct(model, text);
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );

    testWidgets('close and recreate', (tester) async {
      _start('MiniLM close and recreate');
      final model = await _ensureMiniLm();
      final input = EmbeddingInput.text('A feline rested on the rug.');
      final before = await model.embed(input, taskType: TaskType.none);
      await model.close();
      await expectLater(
        model.embed(input, taskType: TaskType.none),
        throwsA(isA<EmbedderClosedException>()),
      );
      final next = await FlutterEdgeAi.getActiveEmbedder();
      expect(
        cosine(before, await next.embed(input, taskType: TaskType.none)),
        closeTo(1.0, 1e-5),
      );
      await next.close();
    });
  });

  testWidgets('every test above started (an absent test reads as a pass '
      'under flutter drive)', (tester) async {
    expect(startedTests, unorderedEquals(_tests));
  });
}

bool _sameIds(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
