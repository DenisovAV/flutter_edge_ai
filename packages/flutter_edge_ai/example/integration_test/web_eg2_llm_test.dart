/// A `.litertlm` LLM and EmbeddingGemma 2 on ONE page (P2w, the coordinator's
/// item 4): both run in the page's single `@litert-lm/core` WebAssembly module,
/// whose own locks are per engine, and both on WebGPU — on the module's one
/// GPU device, so the LLM's and the embedder's GPU memory are held together
/// (EmbeddingGemma 2 has no CPU path on the web). flutter_edge_ai_litertlm
/// serialises them with
/// one page lock (lib/src/web/litert_lm_page_lock.dart): a generation holds it
/// from its first call until its stream ends; an embedding engine's create +
/// load probe and each `computeEmbedding` take it too. This suite is the proof
/// on the real runtime that the two take turns without corrupting each other:
/// - an LLM reply streams while EG2 embeds texts: the reply completes with sane
///   text, every vector equals the same input embedded alone (cos >= 0.9999),
///   and the embeddings finish after the reply (they waited for the lock);
/// - the EG2 embedder LOADS (engine create + probe) while a reply streams;
/// - a 20-text `embedAll` and a reply started in the middle of it both finish,
///   with the same vectors;
/// - the 440m next to the loaded LLM: its vision encoder does not fit — the
///   module has 4 GB of WebAssembly memory, the 440m's vision engine takes
///   about 3.3 GB of it and Gemma 4 E2B the rest (measured, @litert-lm/core
///   0.18.0) — so loading it with images is refused with the reason; loaded
///   for text it embeds while a reply streams. The day this test fails on the
///   refusal, the runtime fits both: test images during a reply again.
/// Timings and the reply go to the response file; a hang fails at a 10-minute
/// bound instead of the driver's.
///
/// GCE VM only (never a local browser). Run from packages/flutter_edge_ai/example:
///   chromedriver --port=4444 &
///   flutter drive \
///     --driver=test_driver/web_embeddings_driver.dart \
///     --target=integration_test/web_eg2_llm_test.dart \
///     -d web-server --browser-name=chrome --headless \
///     --dart-define=LLM_MODEL_URL=http://<host>/gemma-4-E2B-it-web.litertlm
/// then the same with `-d chrome`.
/// - `LLM_MODEL_URL` (required): a `.litertlm` WEB export (e.g.
///   `gemma-4-E2B-it-web.litertlm`), served so the page can fetch it (CORS).
/// - `LLM_MODEL_TYPE` (optional, default `gemma4`): the `ModelType` name it is
///   installed as.
/// - `HUGGINGFACE_TOKEN` (optional): sent with the LLM download when set.
/// - `EG2_MODEL_URL`, `EG2_440M_MODEL_URL` (optional): mirrors of the pinned
///   EmbeddingGemma 2 bundles (ungated on Hugging Face otherwise).
/// The page needs WebGPU, for the LLM and for EmbeddingGemma 2 alike.
///
/// Storage is `WebStorageMode.streaming` (OPFS), as the docs ask for a 2 GB
/// model. Under `cacheApi` the LLM goes through the page's memory as a 2 GB
/// array and Blob: on the GCE VM the kernel killed the renderer (8 GB
/// resident) while it cached the LLM next to a loaded EmbeddingGemma 2, before
/// the two-phase install the LLM-only suites use could take over. Under
/// streaming the LLM is read from OPFS as a stream, and EmbeddingGemma 2
/// through a URL of its OPFS file.
///
/// The driver writes this suite's data to `build/web_eg2_llm_response.json`
/// even when a test fails. Rule 6b: no setUp/setUpAll; every fallible step is
/// a guarded helper inside a test body, and the last test checks that every
/// test before it started.
@TestOn('chrome')
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'web_embeddings_support.dart'
    show cosine, expectUnitVector, report, reportTo, startedTests;

const _tests = [
  'LLM + EG2 text',
  'EG2 load during LLM',
  'embedAll with a reply in the middle',
  'LLM + EG2 440m',
];

const _llmUrl = String.fromEnvironment('LLM_MODEL_URL');
const _llmType = String.fromEnvironment(
  'LLM_MODEL_TYPE',
  defaultValue: 'gemma4',
);
const _hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');
const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _eg2Vision = catalog.EmbeddingModel.embeddingGemma2TextVision440m;
const _eg2Url = String.fromEnvironment('EG2_MODEL_URL');
const _eg2VisionUrl = String.fromEnvironment('EG2_440M_MODEL_URL');

/// A hang (two engines deadlocked in the module) fails here, not at the
/// driver's 90 minutes.
const _bound = Duration(minutes: 10);

const _prompt =
    'Write five plain sentences about the ocean, one per line, with no lists '
    'and no markdown.';

const _texts = [
  'The northern lights over Tromsø.',
  'How tall is Mount Everest?',
  'A recipe for sourdough bread.',
  'The cat sat on the mat.',
  'Quarterly revenue grew by twelve percent.',
  'Which planet is known as the Red Planet?',
];

// ── Guarded set-up (Rule 6b) ────────────────────────────────────────────────

bool _initialized = false;
InferenceModel? _llm;

Future<void> _ensureInitialized() async {
  if (_initialized) return;
  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LiteRtLmEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()],
    webStorageMode: WebStorageMode.streaming,
  );
  expect(
    await FlutterEdgeAi.isStreamingSupported(),
    isTrue,
    reason:
        'OPFS is unavailable in this browser: the 2 GB LLM has nowhere '
        'to stream from',
  );
  _initialized = true;
}

/// Installs the LLM from `LLM_MODEL_URL` (a no-op once installed) and loads
/// it once.
Future<InferenceModel> _ensureLlm() async {
  await _ensureInitialized();
  if (_llmUrl.isEmpty) {
    fail(
      'Pass --dart-define=LLM_MODEL_URL=<a .litertlm web export, e.g. '
      'gemma-4-E2B-it-web.litertlm> (see the header of this file).',
    );
  }
  final existing = _llm;
  if (existing != null) return existing;
  await FlutterEdgeAi.installModel(
    modelType: ModelType.values.byName(_llmType),
    fileType: ModelFileType.litertlm,
  ).fromNetwork(_llmUrl, token: _hfToken.isEmpty ? null : _hfToken).install();
  return _llm = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
}

/// Installs an EmbeddingGemma 2 bundle (a no-op once installed) and makes it
/// the active embedder.
Future<void> _ensureEmbedder(
  catalog.EmbeddingModel model,
  String urlOverride,
) async {
  await _ensureInitialized();
  await FlutterEdgeAi.installEmbedder()
      .modelFromNetwork(
        urlOverride.isEmpty ? model.url : urlOverride,
        filename: model.filename,
      )
      .install();
}

void _start(String name) {
  expect(_tests, contains(name));
  startedTests.add(name);
}

void _log(String line) {
  // ignore: avoid_print
  print('[web-eg2-llm] $line');
}

// ── A reply in flight ───────────────────────────────────────────────────────

/// One reply being generated: [firstChunk] completes when generation is under
/// way (the page lock is held), [done] with the whole text.
final class _Reply {
  _Reply(this._session);

  final InferenceModelSession _session;
  final _text = StringBuffer();
  final firstChunk = Completer<void>();
  final _done = Completer<String>();
  int chunks = 0;
  int? endMs;

  Future<String> get done => _done.future.timeout(_bound);

  static Future<_Reply> start(InferenceModel llm, Stopwatch watch) async {
    final session = await llm.createSession(topK: 1, maxOutputTokens: 160);
    await session.addQueryChunk(const Message(text: _prompt, isUser: true));
    final reply = _Reply(session);
    session.getResponseAsync().listen(
      (chunk) {
        reply._text.write(chunk);
        reply.chunks++;
        if (!reply.firstChunk.isCompleted) reply.firstChunk.complete();
      },
      onError: (Object e, StackTrace st) {
        if (!reply.firstChunk.isCompleted) {
          reply.firstChunk.completeError(e, st);
        }
        if (!reply._done.isCompleted) reply._done.completeError(e, st);
      },
      onDone: () {
        reply.endMs = watch.elapsedMilliseconds;
        if (!reply.firstChunk.isCompleted) reply.firstChunk.complete();
        if (!reply._done.isCompleted) {
          reply._done.complete(reply._text.toString());
        }
      },
    );
    return reply;
  }

  Future<void> close() => _session.close();
}

/// A reply a person could read: words, no replacement characters.
void _expectSaneText(String text) {
  expect(text.trim(), isNotEmpty, reason: 'empty reply');
  expect(
    RegExp(r'[A-Za-z]{3,}').allMatches(text).length,
    greaterThanOrEqualTo(5),
    reason: 'not words: "$text"',
  );
  expect(text, isNot(contains('�')), reason: 'broken characters');
}

/// Embeds [inputs] one by one, timing when each finished.
Future<(List<List<double>>, List<int>)> _embedEach(
  EmbeddingModel model,
  List<EmbeddingInput> inputs,
  TaskType taskType,
  Stopwatch watch,
) async {
  final vectors = <List<double>>[];
  final finished = <int>[];
  for (final input in inputs) {
    vectors.add(await model.embed(input, taskType: taskType).timeout(_bound));
    finished.add(watch.elapsedMilliseconds);
  }
  return (vectors, finished);
}

void _expectSame(
  List<List<double>> got,
  List<List<double>> alone,
  String what,
) {
  for (var i = 0; i < got.length; i++) {
    expectUnitVector(got[i], alone[i].length, what: '$what $i');
    expect(
      cosine(got[i], alone[i]),
      greaterThanOrEqualTo(0.9999),
      reason: '$what $i differs from the same input embedded alone',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reportTo('web_eg2_llm_response');

  testWidgets('an LLM reply streams while EG2 embeds texts: both complete, '
      'the vectors equal the sequential ones, the embeddings wait for the '
      'reply', (tester) async {
    _start('LLM + EG2 text');
    await _ensureEmbedder(_eg2, _eg2Url);
    final embedder = await FlutterEdgeAi.getActiveEmbedder();
    expect(embedder.activeBackend, PreferredBackend.gpu);
    final inputs = [for (final t in _texts) EmbeddingInput.text(t)];
    final watch = Stopwatch()..start();
    final (alone, _) = await _embedEach(
      embedder,
      inputs,
      TaskType.retrievalDocument,
      watch,
    );

    final llm = await _ensureLlm();
    watch.reset();
    final reply = await _Reply.start(llm, watch);
    try {
      await reply.firstChunk.future.timeout(_bound);
      final embedStartMs = watch.elapsedMilliseconds;
      final (together, finished) = await _embedEach(
        embedder,
        inputs,
        TaskType.retrievalDocument,
        watch,
      );
      final text = await reply.done;
      report('text_during_reply', {
        'reply': text,
        'chunks': reply.chunks,
        'replyEndMs': reply.endMs,
        'embedStartMs': embedStartMs,
        'embedFinishedMs': finished,
      });
      _log(
        'reply ${reply.chunks} chunks, ends ${reply.endMs} ms; embeds '
        'from $embedStartMs ms, finished $finished',
      );
      _expectSaneText(text);
      _expectSame(together, alone, 'text');
      expect(
        finished.first,
        greaterThanOrEqualTo(reply.endMs!),
        reason:
            'an embedding finished while the reply was still generating: '
            'the page lock did not hold',
      );
    } finally {
      await reply.close();
    }
  }, timeout: const Timeout(Duration(minutes: 45)));

  testWidgets('the EG2 embedder loads (engine create + probe) while a reply '
      'streams, then embeds what it embedded alone', (tester) async {
    _start('EG2 load during LLM');
    await _ensureEmbedder(_eg2, _eg2Url);
    final first = await FlutterEdgeAi.getActiveEmbedder();
    final input = EmbeddingInput.text(_texts.first);
    final alone = await first.embed(input, taskType: TaskType.none);
    await first.close();

    final llm = await _ensureLlm();
    final watch = Stopwatch()..start();
    final reply = await _Reply.start(llm, watch);
    try {
      await reply.firstChunk.future.timeout(_bound);
      final loadStartMs = watch.elapsedMilliseconds;
      final embedder = await FlutterEdgeAi.getActiveEmbedder().timeout(_bound);
      final loadedMs = watch.elapsedMilliseconds;
      final vector = await embedder
          .embed(input, taskType: TaskType.none)
          .timeout(_bound);
      final text = await reply.done;
      report('load_during_reply', {
        'replyEndMs': reply.endMs,
        'loadStartMs': loadStartMs,
        'loadedMs': loadedMs,
      });
      _expectSaneText(text);
      _expectSame([vector], [alone], 'text after the load');
      expect(loadedMs, greaterThanOrEqualTo(reply.endMs!));
    } finally {
      await reply.close();
    }
  }, timeout: const Timeout(Duration(minutes: 45)));

  testWidgets('a 20-text embedAll with a reply started in the middle of it: '
      'both finish, the vectors equal the sequential ones', (tester) async {
    _start('embedAll with a reply in the middle');
    await _ensureEmbedder(_eg2, _eg2Url);
    final embedder = await FlutterEdgeAi.getActiveEmbedder();
    final inputs = [
      for (var i = 0; i < 20; i++)
        EmbeddingInput.text('${_texts[i % _texts.length]} ($i)'),
    ];
    final alone = await embedder
        .embedAll(inputs, taskType: TaskType.retrievalQuery)
        .timeout(_bound);

    final llm = await _ensureLlm();
    final watch = Stopwatch()..start();
    final batch = embedder
        .embedAll(inputs, taskType: TaskType.retrievalQuery)
        .timeout(_bound);
    // Let the batch get going, then ask for a reply in the middle of it.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final reply = await _Reply.start(llm, watch);
    try {
      final together = await batch;
      final batchEndMs = watch.elapsedMilliseconds;
      final text = await reply.done;
      report('reply_during_batch', {
        'batchEndMs': batchEndMs,
        'replyEndMs': reply.endMs,
      });
      _expectSaneText(text);
      _expectSame(together, alone, 'batch');
    } finally {
      await reply.close();
    }
  }, timeout: const Timeout(Duration(minutes: 45)));

  testWidgets('the 440m next to the LLM: with images it does not fit in the '
      'page\'s WebAssembly memory and the load says so; for text it embeds '
      'while a reply streams, the same vectors as alone', (tester) async {
    _start('LLM + EG2 440m');
    await _ensureEmbedder(_eg2Vision, _eg2VisionUrl);
    final llm = await _ensureLlm();

    EmbeddingLoadException? refusal;
    try {
      await FlutterEdgeAi.getActiveEmbedder(supportImage: true).timeout(_bound);
    } on EmbeddingLoadException catch (e) {
      refusal = e;
    }
    report('images_next_to_llm', refusal?.message);
    _log('440m with images next to the LLM: ${refusal?.message}');
    expect(
      refusal,
      isNotNull,
      reason:
          'the 440m loaded its vision encoder next to the LLM: the runtime '
          'now fits both on one page — embed an image during a reply here '
          'again, and update the docs that say it does not fit',
    );
    expect(
      refusal!.message,
      allOf(
        contains('with its vision encoder'),
        contains('If a .litertlm LLM is loaded on this page, close it first'),
      ),
    );

    final embedder = await FlutterEdgeAi.getActiveEmbedder();
    expect(embedder.activeBackend, PreferredBackend.gpu);
    expect(embedder.modalities, {EmbeddingModality.text});
    final inputs = [
      EmbeddingInput.text('a red stop sign'),
      EmbeddingInput.text('a bar chart of quarterly revenue'),
    ];
    final watch = Stopwatch()..start();
    final (alone, _) = await _embedEach(embedder, inputs, TaskType.none, watch);
    watch.reset();
    final reply = await _Reply.start(llm, watch);
    try {
      await reply.firstChunk.future.timeout(_bound);
      final (together, finished) = await _embedEach(
        embedder,
        inputs,
        TaskType.none,
        watch,
      );
      final text = await reply.done;
      report('text_440m_during_reply', {
        'replyEndMs': reply.endMs,
        'embedFinishedMs': finished,
      });
      _expectSaneText(text);
      _expectSame(together, alone, '440m text');
      expect(finished.reduce(math.min), greaterThanOrEqualTo(reply.endMs!));
    } finally {
      await reply.close();
      await embedder.close();
    }
  }, timeout: const Timeout(Duration(minutes: 45)));

  testWidgets('every test above started (an absent test reads as a pass '
      'under flutter drive)', (tester) async {
    expect(startedTests, unorderedEquals(_tests));
    await _llm?.close();
  });
}
