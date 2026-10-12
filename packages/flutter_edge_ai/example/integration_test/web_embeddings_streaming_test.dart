/// Web embeddings under `WebStorageMode.streaming` (R5 §10.1 "Web", the
/// R5_adjustments C checklist): every installed file is registered as an
/// `opfs://` path, which `fetch()` cannot open, so each web pass resolves it to
/// a `blob:` URL (`resolveWebModelUrl`), loads from it, and revokes it. Both
/// passes are covered — LiteRT.js (EmbeddingGemma 1) and ONNX Runtime Web
/// (all-MiniLM-L6-v2): LiteRT.js once never resolved `opfs://` at all, and
/// nothing noticed because only ONNX had a streaming path under test. Each
/// case embeds AFTER its pass revoked the URLs, which proves nothing reads them
/// lazily.
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
/// `EG1_MODEL_URL` + `EG1_TOKENIZER_URL` — is needed for both.
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

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'web_embeddings_support.dart';

const _tests = ['streaming EG1', 'streaming MiniLM'];

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
Future<(EmbeddingModel, List<String>, List<String>)> _loadWatchingUrls() async {
  final createdBefore = objectUrlsCreated.length;
  final revokedBefore = objectUrlsRevoked.length;
  final model = await FlutterEdgeAi.getActiveEmbedder();
  return (
    model,
    objectUrlsCreated.sublist(createdBefore),
    objectUrlsRevoked.sublist(revokedBefore),
  );
}

/// The load made a `blob:` URL for the model and one for the tokenizer, and
/// released both before it returned.
void _expectBothReleased(List<String> created, List<String> revoked) {
  expect(
    created.where((u) => u.startsWith('blob:')),
    hasLength(greaterThanOrEqualTo(2)),
    reason: 'no opfs:// path was resolved: the files are not in OPFS',
  );
  expect(
    revoked,
    containsAll(created),
    reason: 'a blob: URL made for an opfs:// path was never revoked',
  );
}

void _start(String name) {
  expect(_tests, contains(name));
  startedTests.add(name);
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

      final (model, created, revoked) = await _loadWatchingUrls();
      _expectBothReleased(created, revoked);
      report('streaming_eg1_urls', {'created': created, 'revoked': revoked});

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

      final (model, created, revoked) = await _loadWatchingUrls();
      _expectBothReleased(created, revoked);
      report('streaming_minilm_urls', {'created': created, 'revoked': revoked});

      final vector = await model.embed(
        EmbeddingInput.text('The cat sat on the mat.'),
        taskType: TaskType.none,
      );
      expectUnitVector(vector, 384, what: 'after the URLs were revoked');
      await model.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets('every test above started (an absent test reads as a pass '
      'under flutter drive)', (tester) async {
    expect(startedTests, unorderedEquals(_tests));
  });
}
