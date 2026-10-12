// What the two web embedding drive suites share (web_embeddings_test.dart,
// web_embeddings_streaming_test.dart): the guarded set-up helpers Rule 6b
// requires instead of setUp (a throwing setUp under `flutter drive` is
// reported as "All tests passed"), the two models, the bundle's window
// functions, vector checks, and the W1 golden.
//
// Not a test file (no `_test.dart` suffix). Web only.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_onnx/flutter_edge_ai_onnx.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'goldens/w1_eg1_native_token_ids.dart';

// ── Models ──────────────────────────────────────────────────────────────────

/// EmbeddingGemma 1 seq256 — the example catalog's entry (revision-pinned,
/// gated on Hugging Face).
const eg1 = catalog.EmbeddingModel.embeddingGemma256;

/// `--dart-define=HUGGINGFACE_TOKEN=hf_…` for the gated EG1 files, unless
/// both are served elsewhere (below).
const hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

/// Optional ungated copies of the SAME bytes (e.g. served on the test VM):
/// `--dart-define=EG1_MODEL_URL=…` and `--dart-define=EG1_TOKENIZER_URL=…`.
/// The model file must be `embeddinggemma-300M_seq256_mixed-precision.tflite`
/// of litert-community/embeddinggemma-300m@29888fce, and the tokenizer that
/// revision's `sentencepiece.model` (SHA-256 in the W1 golden), or W1 and
/// the overflow count compare against the wrong file.
const _eg1ModelUrlOverride = String.fromEnvironment('EG1_MODEL_URL');
const _eg1TokenizerUrlOverride = String.fromEnvironment('EG1_TOKENIZER_URL');

String get eg1ModelUrl =>
    _eg1ModelUrlOverride.isEmpty ? eg1.url : _eg1ModelUrlOverride;
String get eg1TokenizerUrl => _eg1TokenizerUrlOverride.isEmpty
    ? eg1.tokenizerUrl!
    : _eg1TokenizerUrlOverride;

/// The token for a URL that needs one; fails the test, by name, when a gated
/// Hugging Face file has none — instead of a bare 401 deep in the download.
String? tokenFor(String url) {
  if (!url.startsWith(
    'https://huggingface.co/litert-community/embeddinggemma',
  )) {
    return null;
  }
  if (hfToken.isEmpty) {
    fail(
      'EmbeddingGemma 1 is gated on Hugging Face: pass '
      '--dart-define=HUGGINGFACE_TOKEN=hf_… (an account that accepted the '
      'Gemma terms), or serve the same files elsewhere and pass '
      '--dart-define=EG1_MODEL_URL=… --dart-define=EG1_TOKENIZER_URL=….',
    );
  }
  return hfToken;
}

/// all-MiniLM-L6-v2, the ONNX model the native gate uses (ungated).
const miniLmModelUrl =
    'https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx';
const miniLmTokenizerUrl =
    'https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/tokenizer.json';

// ── Guarded set-up (Rule 6b: called first thing inside each test body) ─────

WebStorageMode? _initializedFor;

/// Registers both embedding backends and the tokenizers once per page.
/// [storage] cannot change after the first call — core keeps the first mode
/// until the page reloads — so each suite uses one mode throughout.
Future<void> ensureInitialized(WebStorageMode storage) async {
  final current = _initializedFor;
  if (current != null) {
    expect(current, storage, reason: 'one storage mode per page');
    return;
  }
  await FlutterEdgeAi.initialize(
    webStorageMode: storage,
    embeddingBackends: const [LiteRtEmbeddingBackend(), OnnxEmbeddingBackend()],
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
  );
  _initializedFor = storage;
}

/// Installs EmbeddingGemma 1 seq256 (a no-op once installed) and makes it the
/// active embedder. [tokenizerFromAsset]: the example's committed
/// `assets/models/sentencepiece.model` — the exact file the W1 golden was
/// computed from — instead of the network copy (an asset never becomes an
/// `opfs://` path, so the streaming suite downloads both).
Future<void> installEg1({required bool tokenizerFromAsset}) async {
  final builder = FlutterEdgeAi.installEmbedder().modelFromNetwork(
    eg1ModelUrl,
    token: tokenFor(eg1ModelUrl),
    filename: eg1.filename,
  );
  if (tokenizerFromAsset) {
    builder.tokenizerFromAsset(
      'assets/models/sentencepiece.model',
      filename: catalog.EmbeddingModel.localEmbeddingGemma256.tokenizerFilename,
    );
  } else {
    builder.tokenizerFromNetwork(
      eg1TokenizerUrl,
      token: tokenFor(eg1TokenizerUrl),
      filename: eg1.tokenizerFilename,
    );
  }
  await builder.install();
}

/// Installs all-MiniLM-L6-v2 (ONNX) and makes it the active embedder.
Future<void> installMiniLm() => FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(miniLmModelUrl, filename: 'all-MiniLM-L6-v2.onnx')
    .tokenizerFromNetwork(
      miniLmTokenizerUrl,
      filename: 'all-MiniLM-L6-v2.tokenizer.json',
    )
    .install();

// ── The LiteRT.js bundle's window functions ─────────────────────────────────

/// `window.liteRtEmbeddingsApiVersion` (null when unset).
int? get bundleApiVersion =>
    (globalContext['liteRtEmbeddingsApiVersion'] as JSNumber?)?.toDartInt;

set bundleApiVersion(int? version) {
  if (version == null) {
    globalContext.delete('liteRtEmbeddingsApiVersion'.toJS);
  } else {
    globalContext['liteRtEmbeddingsApiVersion'] = version.toJS;
  }
}

/// `window.isLiteRtEmbeddingsInitialized()`: whether the page holds a loaded
/// model and tokenizer.
bool get bundleInitialized => (globalContext.callMethod<JSBoolean>(
  'isLiteRtEmbeddingsInitialized'.toJS,
)).toDart;

/// `window.tokenizeLiteRtText(prefixedText)`: the ids the bundle would run.
List<int> bundleTokenize(String prefixedText) => globalContext
    .callMethod<JSInt32Array>('tokenizeLiteRtText'.toJS, prefixedText.toJS)
    .toDart
    .toList();

/// What the bundle says it ran on, for the record.
Map<String, Object?> bundleAccelerator() => {
  'accelerator': (globalContext.callMethod<JSString?>(
    'getLiteRtEmbeddingAccelerator'.toJS,
  ))?.toDart,
  'fullyAccelerated': (globalContext.callMethod<JSBoolean?>(
    'getLiteRtEmbeddingFullyAccelerated'.toJS,
  ))?.toDart,
};

/// Records every object URL the page creates and revokes from now on, so a
/// test can see a pass release the `blob:` URLs it made for `opfs://` paths.
void installObjectUrlSpy() {
  globalContext.callMethod<JSAny?>(
    'eval'.toJS,
    '''
    (function () {
      if (window.__objectUrlSpy) return;
      const spy = window.__objectUrlSpy = { created: [], revoked: [] };
      const create = URL.createObjectURL.bind(URL);
      const revoke = URL.revokeObjectURL.bind(URL);
      URL.createObjectURL = function (o) {
        const url = create(o);
        spy.created.push(url);
        return url;
      };
      URL.revokeObjectURL = function (url) {
        spy.revoked.push(url);
        return revoke(url);
      };
    })();
    '''
        .toJS,
  );
}

List<String> _spyList(String name) {
  final spy = globalContext['__objectUrlSpy']! as JSObject;
  return (spy[name]! as JSArray<JSString>).toDart.map((s) => s.toDart).toList();
}

List<String> get objectUrlsCreated => _spyList('created');
List<String> get objectUrlsRevoked => _spyList('revoked');

// ── Vectors ─────────────────────────────────────────────────────────────────

double norm(List<double> v) =>
    math.sqrt(v.fold<double>(0, (sum, x) => sum + x * x));

double cosine(List<double> a, List<double> b) {
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot / (norm(a) * norm(b));
}

/// A finite, non-zero, L2-normalised vector of [dimension].
void expectUnitVector(List<double> v, int dimension, {String? what}) {
  expect(v, hasLength(dimension), reason: what);
  expect(v.every((x) => x.isFinite), isTrue, reason: '$what: NaN or inf');
  expect(v.any((x) => x != 0), isTrue, reason: '$what: all zeros');
  expect(norm(v), closeTo(1.0, 1e-3), reason: '$what: not L2-normalised');
}

/// One vector per TaskType for the same [text]: all nine must differ, since
/// each prefix is different (`none` has none).
Future<void> expectEveryTaskTypeDistinct(
  EmbeddingModel model,
  String text,
) async {
  final vectors = {
    for (final type in TaskType.values)
      type: await model.embed(EmbeddingInput.text(text), taskType: type),
  };
  for (final a in TaskType.values) {
    expectUnitVector(vectors[a]!, model.dimension, what: a.name);
    for (final b in TaskType.values) {
      if (a.index >= b.index) continue;
      expect(
        cosine(vectors[a]!, vectors[b]!),
        lessThan(0.99999),
        reason:
            '${a.name} and ${b.name} embedded "$text" identically — a '
            'prefix did not reach the model',
      );
    }
  }
}

// ── The W1 golden ───────────────────────────────────────────────────────────

/// The committed native ids (integration_test/goldens/, written by
/// test/w1_native_token_ids_golden_test.dart).
final w1Golden = jsonDecode(w1NativeTokenIdsJson) as Map<String, Object?>;

/// `[name, text]` for each of the 40 strings.
List<(String, String)> get w1Strings => [
  for (final pair in w1Golden['strings']! as List<Object?>)
    (
      (pair! as List<Object?>)[0]! as String,
      (pair as List<Object?>)[1]! as String,
    ),
];

/// The native ids of every string under [type], in [w1Strings] order.
List<List<int>> w1NativeIds(TaskType type) => [
  for (final row
      in (w1Golden['nativeIds']! as Map<String, Object?>)[type.name]!
          as List<Object?>)
    [for (final id in row! as List<Object?>) id! as int],
];

/// The over-long text and the native token count for it.
({TaskType taskType, String text, int nativeTokenCount}) get w1Overflow {
  final o = w1Golden['overflow']! as Map<String, Object?>;
  return (
    taskType: TaskType.values.byName(o['taskType']! as String),
    text: o['text']! as String,
    nativeTokenCount: o['nativeTokenCount']! as int,
  );
}

// ── Report ──────────────────────────────────────────────────────────────────

/// Adds [value] under [key] to the run's response data. The suites' driver
/// (test_driver/web_embeddings_driver.dart) writes it to the file the suite
/// named with [reportTo], even when a test failed.
void report(String key, Object? value) {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  (binding.reportData ??= <String, dynamic>{})[key] = value;
}

/// The response-data key a suite names its response file under. The driver
/// keeps its own copy of it (it runs outside the app and cannot import this
/// file); the two must stay equal.
const responseFileKey = 'responseFile';

/// Names the file the driver writes this suite's response data to:
/// `build/<responseFile>.json`. Each suite has its own, so running both keeps
/// both records. Call it first thing in `main()`.
void reportTo(String responseFile) => report(responseFileKey, responseFile);

/// Names of the tests that started, for each suite's last test to check that
/// none is missing from the run (Rule 6b: an absent test reads as a pass).
final startedTests = <String>{};
