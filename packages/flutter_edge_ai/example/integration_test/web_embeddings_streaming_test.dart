/// Web embeddings under `WebStorageMode.streaming` (R5 §10.1 "Web", the
/// R5_adjustments C checklist): every installed file is registered as an
/// `opfs://` path, which `fetch()` cannot open, so each web pass resolves it to
/// a `blob:` URL (`resolveWebModelUrl`), loads from it, and revokes it. Every
/// web pass is covered — LiteRT.js (EmbeddingGemma 1), ONNX Runtime Web
/// (all-MiniLM-L6-v2) and `@litert-lm/core`'s EmbeddingEngine (EmbeddingGemma
/// 2, flutter_edge_ai_litertlm 1.13.1): LiteRT.js once never resolved
/// `opfs://` at all, and nothing noticed because only ONNX had a streaming
/// path under test. Each case embeds AFTER its pass revoked the URLs, which
/// proves nothing reads them lazily, and checks each URL was made from the
/// OPFS file itself, never from a copy of it.
///
/// Why the last check: `resolveWebModelUrl` used to copy the whole file into a
/// new Blob on every load (`Response(stream).blob()`). The copies stayed in
/// the browser's blob storage until garbage-collected, so by the EmbeddingGemma
/// 2 case — after two EG1 and two MiniLM loads — `blob()` could fail with a
/// bare "TypeError: Failed to fetch" (2 of 2 runs on the GCE VM). The
/// "streaming EG2 no copies" case holds the end-to-end limit: six URLs of the
/// 165 MB bundle at once, more than that Chrome holds as copies (four).
///
/// A separate file from web_embeddings_test.dart because core keeps the first
/// `webStorageMode` until the page reloads.
///
/// GCE VM only (never a local browser). Run from packages/flutter_edge_ai/example:
///   chromedriver --port=4444 &
///   flutter drive \
///     --driver=test_driver/web_embeddings_driver.dart \
///     --target=integration_test/web_embeddings_streaming_test.dart \
///     -d web-server --browser-name=chrome --headless \
///     --dart-define=HUGGINGFACE_TOKEN=hf_...
/// then the same with `-d chrome`. Both EG1 files are downloaded here (an
/// asset never becomes an `opfs://` path), so the token — or
/// `EG1_MODEL_URL` + `EG1_TOKENIZER_URL` — is needed for both. EmbeddingGemma 2
/// (165 MB, ungated) comes from Hugging Face unless `EG2_MODEL_URL` serves the
/// same bytes.
///
/// The driver writes this suite's data (the object URLs each pass created and
/// revoked) to `build/web_embeddings_streaming_response.json`, even when a
/// test fails; web_embeddings_test.dart's goes to its own file, so running
/// both keeps both.
///
/// Rule 6b: no setUp/setUpAll; the last test checks that every test before
/// it started.
@TestOn('chrome')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine_web.dart' show resolveWebModelUrl;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'web_embeddings_support.dart';

const _tests = [
  'streaming EG1',
  'streaming MiniLM',
  'streaming EG2',
  'streaming EG2 no copies',
];

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _eg2UrlOverride = String.fromEnvironment('EG2_MODEL_URL');

Future<void> _ensureStreaming() async {
  await ensureInitialized(WebStorageMode.streaming);
  expect(
    await FlutterEdgeAi.isStreamingSupported(),
    isTrue,
    reason: 'OPFS is unavailable in this browser: nothing below would use it',
  );
  installObjectUrlSpy();
}

/// Loads the active embedder and returns it with the object URLs the load
/// created and revoked.
/// The object URLs a load made: each URL, what it was made from, and the
/// URLs the load revoked.
typedef _Urls = ({
  List<String> created,
  List<String> madeFrom,
  List<String> revoked,
});

Future<(EmbeddingModel, _Urls)> _loadWatchingUrls() async {
  final createdBefore = objectUrlsCreated.length;
  final revokedBefore = objectUrlsRevoked.length;
  final model = await FlutterEdgeAi.getActiveEmbedder();
  return (
    model,
    (
      created: objectUrlsCreated.sublist(createdBefore),
      madeFrom: objectUrlsMadeFrom.sublist(createdBefore),
      revoked: objectUrlsRevoked.sublist(revokedBefore),
    ),
  );
}

/// The load made a `blob:` URL for each of its [files] (model, and the
/// tokenizer when there is one), each from the OPFS file itself — not a copy
/// — and released them all before it returned.
void _expectBothReleased(_Urls urls, {int files = 2}) {
  expect(
    urls.created.where((u) => u.startsWith('blob:')),
    hasLength(greaterThanOrEqualTo(files)),
    reason: 'no opfs:// path was resolved: the files are not in OPFS',
  );
  expect(
    urls.madeFrom,
    everyElement(startsWith('File ')),
    reason:
        'a URL was made from a copy of the file: every load would hold a '
        'model-sized Blob in the browser\'s blob storage until it is '
        'garbage-collected',
  );
  expect(
    urls.revoked,
    containsAll(urls.created),
    reason: 'a blob: URL made for an opfs:// path was never revoked',
  );
}

/// Installs the EmbeddingGemma 2 270m into OPFS (a no-op once there) and makes
/// it the active embedder.
Future<void> _installEg2() => FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      _eg2UrlOverride.isEmpty ? _eg2.url : _eg2UrlOverride,
      filename: _eg2.filename,
    )
    .install();

void _start(String name) {
  expect(_tests, contains(name));
  startedTests.add(name);
}

/// How many bytes [url] serves, read through a stream reader (reading it into
/// a Blob would make the very copy the caller checks for).
Future<int> _readLength(String url) async {
  final length = globalContext.callMethod<JSPromise<JSNumber>>(
    'eval'.toJS,
    '''
    (async () => {
      const reader = (await fetch('$url')).body.getReader();
      let n = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) return n;
        n += value.length;
      }
    })()
    '''
        .toJS,
  );
  return (await length.toDart).toDartInt;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reportTo('web_embeddings_streaming_response');

  testWidgets(
    'LiteRT.js (EmbeddingGemma 1): loads from opfs:// paths, revokes both '
    'blob: URLs, then embeds',
    (tester) async {
      _start('streaming EG1');
      await _ensureStreaming();
      await installEg1(tokenizerFromAsset: false);
      // A fresh load, so the URLs it makes are the ones seen.
      await (await FlutterEdgeAi.getActiveEmbedder()).close();

      final (model, urls) = await _loadWatchingUrls();
      _expectBothReleased(urls);
      report('streaming_eg1_urls', {
        'created': urls.created,
        'madeFrom': urls.madeFrom,
        'revoked': urls.revoked,
      });

      expect(model.maxInputTokens, 256);
      final vector = await model.embed(
        EmbeddingInput.text('Which planet is known as the Red Planet?'),
        taskType: TaskType.retrievalQuery,
      );
      expectUnitVector(vector, 768, what: 'after the URLs were revoked');
      await model.close();
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );

  testWidgets(
    'ONNX Runtime Web (all-MiniLM-L6-v2): loads from opfs:// paths, revokes '
    'both blob: URLs, then embeds',
    (tester) async {
      _start('streaming MiniLM');
      await _ensureStreaming();
      await installMiniLm();
      await (await FlutterEdgeAi.getActiveEmbedder()).close();

      final (model, urls) = await _loadWatchingUrls();
      _expectBothReleased(urls);
      report('streaming_minilm_urls', {
        'created': urls.created,
        'madeFrom': urls.madeFrom,
        'revoked': urls.revoked,
      });

      final vector = await model.embed(
        EmbeddingInput.text('The cat sat on the mat.'),
        taskType: TaskType.none,
      );
      expectUnitVector(vector, 384, what: 'after the URLs were revoked');
      await model.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    '@litert-lm/core EmbeddingEngine (EmbeddingGemma 2): loads from an '
    'opfs:// path, revokes its blob: URL, then embeds',
    (tester) async {
      _start('streaming EG2');
      await _ensureStreaming();
      await _installEg2();
      await (await FlutterEdgeAi.getActiveEmbedder()).close();

      final (model, urls) = await _loadWatchingUrls();
      _expectBothReleased(urls, files: 1);
      report('streaming_eg2_urls', {
        'created': urls.created,
        'madeFrom': urls.madeFrom,
        'revoked': urls.revoked,
      });

      expect(model.maxInputTokens, 1024);
      expect(model.activeBackend, PreferredBackend.gpu);
      final vector = await model.embed(
        EmbeddingInput.text('The cat sat on the mat.'),
        taskType: TaskType.retrievalDocument,
      );
      expectUnitVector(vector, 768, what: 'after the URL was revoked');
      await model.close();
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );

  testWidgets(
    'six URLs of the 165 MB EmbeddingGemma 2 bundle at once: each made from '
    'the OPFS file, none a copy — six copies are more than this Chrome holds',
    (tester) async {
      _start('streaming EG2 no copies');
      await _ensureStreaming();
      await _installEg2();
      final path =
          (await FlutterEdgeAiPlugin.instance.modelManager.getModelFilePaths(
            FlutterEdgeAi.activeEmbedderSpec!,
          ))!.values.single;
      expect(path, startsWith('opfs://'));
      final createdBefore = objectUrlsCreated.length;
      final urls = <String>[];
      try {
        // None revoked until all six exist: as copies, each would hold 165 MB
        // of blob storage the whole time.
        for (var i = 0; i < 6; i++) {
          urls.add(await resolveWebModelUrl(path));
        }
        expect(
          objectUrlsMadeFrom.sublist(createdBefore),
          everyElement('File ${path.substring('opfs://'.length)}'),
        );
        final bytes = await _readLength(urls.last);
        expect(bytes, 164626432, reason: 'the bundle, whole');
        report('streaming_eg2_no_copies', {
          'urls': urls.length,
          'bytes': bytes,
        });
      } finally {
        for (final url in urls) {
          (globalContext['URL']! as JSObject).callMethod<JSAny?>(
            'revokeObjectURL'.toJS,
            url.toJS,
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );

  testWidgets('every test above started (an absent test reads as a pass '
      'under flutter drive)', (tester) async {
    expect(startedTests, unorderedEquals(_tests));
  });
}
