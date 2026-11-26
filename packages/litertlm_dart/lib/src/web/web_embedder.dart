// The EmbeddingGemma 2 `.litertlm` embedder on the web, over
// `@litert-lm/core`'s `EmbeddingEngine` ([liteRtLmWebRuntime]): what the web
// `EmbeddingEngine` loads, and what flutter_edge_ai_litertlm's web embedding
// pass maps onto core (as natively its pass maps `LiteRtLmEmbedder`).
//
// Pure Dart: the runtime arrives in the config as a [LiteRtLmWebRuntime] (the
// `dart:js_interop` one over the `EmbeddingEngine` of the page's
// `window.litertLm`,
// embedding_runtime_js.dart, or a fake in the VM tests), so nothing here
// imports `dart:js_interop`.
//
// What it decides, and why:
// - The page exposes the runtime through the same module script as the LLM
//   engine (`window.litertLmReady`, which hands over the whole module as
//   `window.litertLm`). Without it, or with a module that has no
//   `EmbeddingEngine`, there is no engine to create; the load fails with an
//   EmbedderLoadException that names what is missing instead of a JS
//   `undefined` deep in the runtime.
// - One `EmbeddingEngine` per embedder, created at load and deleted at
//   close. The runtime's WebAssembly module is page-global and shared with
//   the `.litertlm` LLM engine, whose calls the runtime does not order
//   against these: the create + probe and every
//   `computeEmbedding` take `liteRtLmPageLock`, as the LLM's create,
//   conversation and generation do (see that file for why). The two engines
//   also share the module's one WebGPU device. `delete()` never suspends and
//   does not wait for it.
// - `maxInputLength: 1024` (D21, the runtime's own default), WebGPU for the
//   text and the vision tower. The CPU (WebAssembly) path of `@litert-lm/core`
//   0.20.0 loads the EmbeddingGemma 2 bundles but is far too slow to use:
//   110-225 s to load and 9-12 s per short text (web_eg2_test.dart,
//   2026-11-25). On 0.18.0 and 0.19.0 it could not load them at all
//   (`EmbeddingEngine.create` failed with "Failed to get external weight for
//   buffer id …", Chrome 155, 2026-11-23). WebGPU loads them, and its vectors
//   match the native CPU goldens (text cos >= 0.9948, images >= 0.9976, no
//   NaN or zero vector), so WebGPU is the backend, refused for speed rather
//   than ability on the CPU — and there is no CPU fallback.
// - A page without WebGPU (no `navigator.gpu`, or no adapter) is refused
//   before `EmbeddingEngine.create`, with an EmbedderLoadException that says
//   why, instead of the runtime's "No GPU adapter found." deep in the create.
//   The runtime sets up its WebGPU device itself, in `create`.
// - The vision tower is created only when images are declared
//   (`visionBackend` unset = vision disabled on the web), at 140 or 70 tokens
//   per image (D25). The web runtime has no ModelInfo, so whether the bundle
//   HAS a vision encoder is read from its container header, as for audio
//   below, and the load error names the bundle that embeds images.
//   `EmbeddingEngine.create` of 0.19.0 creates the 270m with a vision tower
//   and only the first image fails (0.18.0 refused it at create; measured
//   2026-11-23), so the header is what refuses it.
// - The audio tower is created only when audio is declared (`audioBackend`
//   unset = audio disabled), on WebGPU like the rest (see
//   [liteRtLmWebAudioBackend] for the measurement behind it). Whether the
//   bundle HAS an audio encoder is read from its container header first, as
//   natively (D23, `litertlm_container.dart`): the page's `fetch()` reads the
//   first few KB of the installed file, and the 270m and the 440m are refused
//   by name before any engine exists. `EmbeddingEngine.create` cannot be
//   trusted with that question: with `audioBackend` set it SUCCEEDS on both,
//   and only the first clip fails ("Audio executor is not available for
//   audio input.", measured on Chrome 155).
// - One vector may combine parts (`combinedInputs`), in the native order: the
//   text with its task prefix, then the images in order, then the audio — sent
//   as one array of parts to `computeEmbedding`. A single part is sent alone,
//   as before.
// - At load the embedder embeds one over-long probe text under TRUNCATE: the
//   vector's length is the model's dimension, and a NaN or all-zero vector —
//   the fp16 failure — refuses the load instead of serving wrong vectors. The
//   input limit the engine really enforces (prefix, BOS and EOS included)
//   comes from what it did with the probe: on the CPU path it truncates and
//   reports `truncatedLength`; on WebGPU `@litert-lm/core` (0.18.0, and 0.19.0
//   on 2026-11-23) ignores the
//   overflow strategy (TRUNCATE and ERROR alike) and always splits an
//   over-long input into windows of its text signature and averages them
//   (`numChunks` > 1, no `truncatedLength`; measured on Chrome 155: 1024
//   tokens are one window, 1025 are two). There the limit is the window,
//   pinned by embedding exactly 1024 tokens (one window) and 1025 (two).
// - Every request runs under TRUNCATE. An input the engine had to cut
//   (`truncatedLength`) or split (`numChunks` > 1) is thrown as
//   EmbedderInputTooLongException with the engine's exact count
//   (`inputLength`, media tokens included) — the truncated or averaged vector
//   is never returned.
// - Under `WebStorageMode.streaming` the model path is `opfs://`, which the
//   runtime's fetch() cannot open: it is resolved to a `blob:` URL first, and
//   that URL — created by this embedder — is revoked once the engine has read
//   it.

import 'dart:typed_data';

import 'package:meta/meta.dart' show visibleForTesting;

import '../embedder/embedder_constants.dart';
import '../embedder/embedder_types.dart';
import '../embedder/litertlm_container.dart';
import '../runtime/runtime_log.dart';
import 'page_lock.dart';
import 'web_module_shim.dart';
import 'web_runtime_version.dart';

/// The `@litert-lm/core` backends the pass can ask for (`Backend.CPU`,
/// `Backend.GPU`).
enum LiteRtLmWebBackend {
  /// XNNPack on WebAssembly. `@litert-lm/core` 0.20.0 loads the
  /// EmbeddingGemma 2 bundles on it, but takes 110-225 s to load and 9-12 s
  /// per short text (0.18.0 and 0.19.0 could not load them); for
  /// measurement only.
  cpu,

  /// WebGPU: the default, and the backend the EmbeddingGemma 2 bundles load
  /// on.
  gpu,
}

/// `InputOverflowStrategy` of `@litert-lm/core`.
enum LiteRtLmWebOverflowStrategy { chunkAndAverage, truncate, error }

/// What the pass hands `EmbeddingEngine.create` (`EmbeddingEngineSettings`).
/// A null field is left out of the settings object, so the runtime applies
/// its own rule — for [visionBackend] and [audioBackend], that tower
/// disabled.
final class LiteRtLmWebEngineSettings {
  const LiteRtLmWebEngineSettings({
    required this.modelUrl,
    required this.backend,
    required this.maxInputLength,
    this.visionBackend,
    this.audioBackend,
    this.minInputLength,
    this.visionTokensPerImage,
  });

  /// A URL the runtime's `fetch()` can read: `blob:` or `https:`.
  final String modelUrl;

  final LiteRtLmWebBackend backend;
  final LiteRtLmWebBackend? visionBackend;
  final LiteRtLmWebBackend? audioBackend;
  final int maxInputLength;
  final int? minInputLength;
  final int? visionTokensPerImage;

  @override
  String toString() =>
      'LiteRtLmWebEngineSettings(backend: ${backend.name}, '
      'visionBackend: ${visionBackend?.name}, audioBackend: '
      '${audioBackend?.name}, maxInputLength: $maxInputLength, '
      'minInputLength: $minInputLength, visionTokensPerImage: '
      '$visionTokensPerImage)';
}

/// `EmbeddingOptions` for one `computeEmbedding` call.
final class LiteRtLmWebEmbeddingOptions {
  const LiteRtLmWebEmbeddingOptions({
    required this.normalize,
    required this.insertSpecialTokens,
    required this.inputOverflowStrategy,
  });

  final bool normalize;
  final bool insertSpecialTokens;
  final LiteRtLmWebOverflowStrategy inputOverflowStrategy;
}

/// What one `computeEmbedding` call embeds: one part — a string, an encoded
/// image or an encoded audio clip — or several of them in one vector
/// ([LiteRtLmWebParts]).
sealed class LiteRtLmWebInput {
  const LiteRtLmWebInput();
}

/// A text part, exactly as the engine tokenizes it (prefix included).
final class LiteRtLmWebText extends LiteRtLmWebInput {
  const LiteRtLmWebText(this.text);

  final String text;
}

/// An encoded image (JPEG, PNG, GIF or BMP), decoded by the engine.
final class LiteRtLmWebImage extends LiteRtLmWebInput {
  const LiteRtLmWebImage(this.bytes);

  final Uint8List bytes;
}

/// An encoded audio clip (WAV, MP3 or FLAC), decoded, mixed down to mono and
/// resampled to 16 kHz by the engine.
final class LiteRtLmWebAudio extends LiteRtLmWebInput {
  const LiteRtLmWebAudio(this.bytes);

  final Uint8List bytes;
}

/// Several parts embedded as one vector (a combined input), in the order the
/// engine reads them: the text, then the images, then the audio. Each part is
/// a [LiteRtLmWebText], [LiteRtLmWebImage] or [LiteRtLmWebAudio], never
/// another [LiteRtLmWebParts].
final class LiteRtLmWebParts extends LiteRtLmWebInput {
  LiteRtLmWebParts(Iterable<LiteRtLmWebInput> parts)
    : parts = List.unmodifiable(parts) {
    if (this.parts.length < 2 || this.parts.any((p) => p is LiteRtLmWebParts)) {
      throw ArgumentError.value(
        parts,
        'parts',
        'two or more text, image or audio parts',
      );
    }
  }

  final List<LiteRtLmWebInput> parts;
}

/// `EmbeddingResponse`: the vector and what the engine counted.
typedef LiteRtLmWebEmbedding = ({
  List<double> embedding,
  int inputLength,
  int? truncatedLength,
  int numChunks,
});

/// What the page offers when the pass asks.
enum LiteRtLmWebRuntimeState {
  /// The page module's `EmbeddingEngine` is a constructor.
  ready,

  /// The page has no `@litert-lm/core` loader at all: neither
  /// `window.litertLmReady` nor `window.litertLm`.
  loaderMissing,

  /// The loader ran, but the page's module has no `EmbeddingEngine` (the
  /// page's runtime reports it by throwing [LiteRtLmWebModuleError] instead,
  /// which names what the module holds there).
  embeddingEngineMissing,

  /// The module's `EmbeddingEngine` lacks a member this release calls
  /// ([LiteRtLmWebRuntime.missingMembers]): a `@litert-lm/core` this release
  /// cannot drive, whatever its version.
  runtimeIncomplete,
}

/// Whether the browser can give the runtime a WebGPU device.
enum LiteRtLmWebGpuSupport {
  /// `navigator.gpu` returned an adapter.
  available,

  /// The browser has no `navigator.gpu`: WebGPU is off or not implemented
  /// (or the page is not a secure context).
  noWebGpu,

  /// `navigator.gpu.requestAdapter()` returned null: WebGPU is there, but no
  /// GPU is available to it (blocklisted driver, no GPU, headless).
  noAdapter,
}

/// The page's `@litert-lm/core` embedding runtime, as the pass uses it.
abstract interface class LiteRtLmWebRuntime {
  /// Waits for the page's loader (`window.litertLmReady`) when there is one,
  /// then reports whether the module it handed over (`window.litertLm`) has an
  /// `EmbeddingEngine` this release can drive. Throws
  /// [LiteRtLmWebModuleError] when the page set no `window.litertLm`, or its
  /// module lacks `EmbeddingEngine` or `@litert-lm/core`'s `Backend` enum,
  /// and anything else when the loader itself failed (the module could not
  /// be imported).
  Future<LiteRtLmWebRuntimeState> ensureReady();

  /// What the module's `EmbeddingEngine` lacks of what this release calls, after
  /// [ensureReady] reported [LiteRtLmWebRuntimeState.runtimeIncomplete];
  /// empty otherwise.
  List<String> get missingMembers;

  /// Asks the browser for a WebGPU adapter as `@litert-lm/core` does
  /// before it creates a GPU engine (`navigator.gpu.requestAdapter({
  /// powerPreference: 'high-performance'})`). Throws when the request itself
  /// fails.
  Future<LiteRtLmWebGpuSupport> webGpuSupport();

  /// `EmbeddingEngine.create(settings)`.
  Future<LiteRtLmWebEngine> create(LiteRtLmWebEngineSettings settings);

  /// The first [length] bytes of what [url] serves — fewer when it is
  /// shorter — read from the start of the response, the rest cancelled: the
  /// container header of a bundle of hundreds of MB costs a few KB. Throws
  /// when the URL cannot be read.
  Future<Uint8List> readPrefix(String url, int length);
}

/// One `EmbeddingEngine`.
abstract interface class LiteRtLmWebEngine {
  /// `engine.computeEmbedding(input, options)`.
  Future<LiteRtLmWebEmbedding> computeEmbedding(
    LiteRtLmWebInput input,
    LiteRtLmWebEmbeddingOptions options,
  );

  /// `engine.delete()`: frees the engine; waits for a call in flight.
  Future<void> delete();
}

/// What the web `LiteRtEmbeddingBackend.describe` hands core for a `.litertlm`
/// embedder. Hosted inline on the page, never sent across an isolate.
final class LiteRtLmWebEmbedderConfig {
  const LiteRtLmWebEmbedderConfig({
    required this.modelPath,
    required this.fileName,
    required this.runtime,
    required this.resolveUrl,
    required this.revokeUrl,
    this.declaredMedia = const {},
    this.visionTokensPerImage = liteRtLmDefaultVisionTokensPerImage,
    this.backend = LiteRtLmWebBackend.gpu,
    this.audioBackend = liteRtLmWebAudioBackend,
    @visibleForTesting this.minInputLength,
  });

  /// The path core registered for the installed bundle: a `blob:` or
  /// `https:` URL, or `opfs://<file>` under `WebStorageMode.streaming`.
  final String modelPath;

  /// The installed file's name, for messages (the path is a URL).
  final String fileName;

  final LiteRtLmWebRuntime runtime;

  /// `resolveWebModelUrl`: `opfs://` → `blob:`, anything else unchanged.
  final Future<String> Function(String path) resolveUrl;

  /// `URL.revokeObjectURL`, for the `blob:` URL [resolveUrl] made from an
  /// `opfs://` path — the pass owns that one. A path it did not resolve from
  /// `opfs://` is never revoked.
  final void Function(String url) revokeUrl;

  /// The media the caller declared: images create the vision tower, audio
  /// the audio tower (after the container header showed the bundle has an
  /// audio encoder).
  final Set<EmbedderModality> declaredMedia;

  /// Vision tokens per image (D25): 140 or 70, checked by `describe()`.
  final int visionTokensPerImage;

  /// The backend of the text tower, and of the vision tower when images are
  /// declared: WebGPU. CPU is left selectable for the drive suite, which
  /// records that the pinned runtime still cannot load the bundles on it;
  /// the public web `EmbeddingEngine` refuses it.
  final LiteRtLmWebBackend backend;

  /// The backend of the audio tower when audio is declared:
  /// [liteRtLmWebAudioBackend] unless the public `EmbeddingEngineConfig` asks
  /// for another; flutter_edge_ai_litertlm never changes it.
  final LiteRtLmWebBackend audioBackend;

  /// `minInputLength`; null leaves the runtime's default (= the max input
  /// length: one signature). Set only by the drive suite's measurement of
  /// short-text latency against memory.
  final int? minInputLength;
}

/// The backend of the audio tower on the web: WebGPU, as the text and vision
/// towers. Both work; WebGPU is about 65 times faster. Measured on the 740m,
/// Chrome 155, Tesla T4 (2.6-3.6 s clips of speech):
///
/// | audio tower | per clip | first clip | cos to the native CPU vector |
/// |---|---|---|---|
/// | WebGPU | 0.27-0.34 s | 3.7-3.9 s (shader compile) | 0.974-0.991 |
/// | CPU (WebAssembly) | 17.8-18.0 s, every clip | the same | 0.988-0.995 |
///
/// On the CPU the clip also runs on the page's main thread: the page would
/// freeze for those 18 s. WebGPU's vectors are as far from the native ones as
/// another native CPU kernel's (int8 activations; the native suite measures up
/// to cos 0.05 between builds), deterministic run to run, and retrieval holds:
/// text → audio top-1 6/6 on the example's clips.
const liteRtLmWebAudioBackend = LiteRtLmWebBackend.gpu;

/// Throws [EmbedderLoadException] unless the `.litertlm` bundle at [url]
/// has an audio encoder, read from its container header through
/// [runtime]'s `readPrefix` (a few KB) — D23, the native rule
/// (`litertlm_container.dart`): ModelInfo claims audio on the 270m and the
/// 440m, and the web has no ModelInfo at all. A header that cannot be read or
/// parsed is a load failure naming [fileName], never "no audio".
Future<void> requireLiteRtLmWebAudioEncoder(
  LiteRtLmWebRuntime runtime,
  String url, {
  required String fileName,
}) async {
  final types = await _modelTypes(runtime, url, fileName: fileName);
  if (!litertlmHasAudioEncoder(types)) {
    throw EmbedderLoadException(liteRtLmNoAudioEncoderMessage(fileName));
  }
}

/// The `TFLiteModel` section types of the `.litertlm` bundle at [url], read
/// from its container header through [runtime]'s `readPrefix`. A header that
/// cannot be read or parsed is a load failure naming [fileName] and what was
/// [looking] for, never "the bundle has none".
Future<List<String>> _modelTypes(
  LiteRtLmWebRuntime runtime,
  String url, {
  required String fileName,
  String looking = 'its audio encoder',
}) async {
  try {
    return await readLitertlmModelTypesFrom(
      (length) => runtime.readPrefix(url, length),
    );
  } on FormatException catch (e) {
    throw EmbedderLoadException(
      liteRtLmUnreadableContainerMessage(fileName, e.message, looking: looking),
      cause: e,
    );
  } catch (e) {
    // A failed fetch() of the page's own copy (a JS TypeError).
    throw EmbedderLoadException(
      liteRtLmUnreadableContainerMessage(fileName, '$e', looking: looking),
      cause: e,
    );
  }
}

/// [requireLiteRtLmWebAudioEncoder] for the bundle [config] names, as
/// `describe()` runs it before core closes the embedder it holds: the
/// `opfs://` path resolved to a `blob:` URL for the read, and that URL
/// revoked after it, whatever the outcome.
Future<void> requireLiteRtLmWebAudioEncoderFor(
  LiteRtLmWebEmbedderConfig config,
) async {
  final url = await _resolveModelUrl(config);
  try {
    await requireLiteRtLmWebAudioEncoder(
      config.runtime,
      url,
      fileName: config.fileName,
    );
  } finally {
    if (config.modelPath.startsWith('opfs://')) config.revokeUrl(url);
  }
}

/// [config]'s model path as a URL `fetch()` can read; the failure named.
Future<String> _resolveModelUrl(LiteRtLmWebEmbedderConfig config) async {
  final rawPath = config.modelPath;
  try {
    return await config.resolveUrl(rawPath);
  } catch (e) {
    // Named here: unwrapped, a JS error reached the app as a bare
    // "TypeError: Failed to fetch" with no file and no step in it.
    throw EmbedderLoadException(
      'LiteRT-LM could not open ${config.fileName} from the page\'s model '
      'storage ($rawPath): $e',
      cause: e,
    );
  }
}

/// The words of the load probe: 9,000 of one word that the Gemma tokenizer
/// reads as one token each — longer than the largest text signature of any
/// EmbeddingGemma 2 bundle (8192), so the engine always cuts or splits it.
const _probeWords = 9000;

/// [count] repetitions of `the`, one token each.
String _the(int count) => List.filled(count, 'the').join(' ');

final _probeText = _the(_probeWords);

/// Every request: L2-normalised, BOS and EOS added (D26), and TRUNCATE for an
/// over-long input, so the response carries the engine's exact counts (on
/// WebGPU the engine ignores the strategy and splits the input instead; the
/// counts are there either way).
const _options = LiteRtLmWebEmbeddingOptions(
  normalize: true,
  insertSpecialTokens: true,
  inputOverflowStrategy: LiteRtLmWebOverflowStrategy.truncate,
);

/// What a loaded [LiteRtLmWebEmbedder] reports.
typedef LiteRtLmWebEmbedderInfo = ({
  int dimension,

  /// The input limit the engine enforces; null when it could not be pinned
  /// (see [LiteRtLmWebEmbedder.load]).
  int? maxInputTokens,
  Set<EmbedderModality> modalities,
  int? visionTokensPerImage,
});

/// The `.litertlm` embedder on the web: text, images when declared on a
/// bundle with a vision encoder, audio when declared on a bundle with an
/// audio encoder, and any combination of them in one vector.
final class LiteRtLmWebEmbedder {
  LiteRtLmWebEmbedder(this._config);

  final LiteRtLmWebEmbedderConfig _config;

  LiteRtLmWebEngine? _engine;
  int _dimension = 0;
  int? _maxInputTokens;
  bool _images = false;
  bool _audio = false;
  _EmbedderState _state = _EmbedderState.fresh;

  String get _file => _config.fileName;

  /// Creates the engine and embeds the probe: the dimension, the input
  /// limit and that the vectors are usable. Runs once, before [close]. A load
  /// that fails, or is closed while it runs, deletes the engine it created
  /// before it returns.
  Future<LiteRtLmWebEmbedderInfo> load() async {
    if (_state != _EmbedderState.fresh) {
      throw StateError('LiteRtLmWebEmbedder.load() runs once, before close');
    }
    _state = _EmbedderState.loading;
    try {
      final info = await _load();
      if (_state == _EmbedderState.closed) {
        throw StateError('The embedder was closed while it loaded.');
      }
      _state = _EmbedderState.loaded;
      return info;
    } catch (_) {
      if (_state != _EmbedderState.closed) _state = _EmbedderState.failed;
      final engine = _engine;
      _engine = null;
      if (engine != null) {
        try {
          await engine.delete();
        } catch (e) {
          runtimeLog('[LiteRtLmWebEmbedder] deleting a failed load: $e');
        }
      }
      rethrow;
    }
  }

  Future<LiteRtLmWebEmbedderInfo> _load() async {
    final media = _config.declaredMedia;
    await _requireRuntime();
    if (_config.backend == LiteRtLmWebBackend.gpu) await _requireWebGpu();
    final images = media.contains(EmbedderModality.image);
    final audio = media.contains(EmbedderModality.audio);
    final rawPath = _config.modelPath;
    final url = await _resolveModelUrl(_config);
    final LiteRtLmWebEngineSettings settings;
    final LiteRtLmWebEmbedding probe;
    final int? maxInputTokens;
    try {
      // From the container, before any engine exists (D23), one read for
      // both towers. Audio: describe() has asked already; this is the
      // backstop for an embedder built another way. Images: the header
      // decides, as ModelInfo does natively; `EmbeddingEngine.create` of
      // 0.19.0 creates a vision tower the bundle lacks (0.18.0 refused it;
      // measured on the 270m, Chrome 157, 2026-11-23).
      if (audio || images) {
        final types = await _modelTypes(
          _config.runtime,
          url,
          fileName: _file,
          looking: audio ? 'its audio encoder' : 'its vision encoder',
        );
        if (audio && !litertlmHasAudioEncoder(types)) {
          throw EmbedderLoadException(liteRtLmNoAudioEncoderMessage(_file));
        }
        if (images && !litertlmHasVisionTower(types)) {
          throw EmbedderLoadException(liteRtLmNoVisionEncoderMessage(_file));
        }
      }
      // Both suspend inside the page's WebAssembly module (the create reads
      // the model stream), so they take the page lock the LLM engine takes
      // too.
      (settings, probe, maxInputTokens) = await liteRtLmPageLock.run(() async {
        _checkNotClosed();
        final settings = await _createEngine(url, images: images, audio: audio);
        _checkNotClosed();
        final engine = _engine!;
        try {
          final probe = await engine.computeEmbedding(
            LiteRtLmWebText(_probeText),
            _options,
          );
          return (settings, probe, await _inputLimit(engine, probe));
        } catch (e) {
          throw EmbedderLoadException(
            'LiteRT-LM created the embedding engine for $_file but could not '
            'embed with it (${_config.backend.name}): $e',
            cause: e,
          );
        }
      });
    } finally {
      // The engine has read the model by now, or never will.
      if (rawPath.startsWith('opfs://')) _config.revokeUrl(url);
    }
    final dimension = probe.embedding.length;
    if (dimension == 0) {
      throw EmbedderLoadException(
        'LiteRT-LM returned an empty vector for $_file',
      );
    }
    if (_unusable(probe.embedding)) {
      throw EmbedderLoadException(
        'LiteRT-LM returned a vector with NaN, infinity or only zeros for '
        '$_file on ${_config.backend.name}; nothing was embedded. This is how '
        'reduced-precision (fp16) inference fails for EmbeddingGemma 2.',
      );
    }
    if (maxInputTokens == null) {
      runtimeLog(
        '[LiteRtLmWebEmbedder] $_file embedded '
        '${probe.inputLength} tokens in ${probe.numChunks} window(s) without '
        'truncating, and its window could not be pinned: its input limit is '
        'unknown, so maxInputTokens is null.',
      );
    }

    _dimension = dimension;
    _maxInputTokens = maxInputTokens;
    _images = images;
    _audio = audio;
    runtimeLog(
      '[LiteRtLmWebEmbedder] loaded $_file: dim=$dimension, '
      'maxInputTokens=$maxInputTokens, $settings',
    );
    return (
      dimension: dimension,
      maxInputTokens: maxInputTokens,
      modalities: {
        EmbedderModality.text,
        if (images) EmbedderModality.image,
        if (audio) EmbedderModality.audio,
      },
      visionTokensPerImage: images ? _config.visionTokensPerImage : null,
    );
  }

  /// The input limit the engine enforces — the text signature it prepared,
  /// the smallest of the bundle's at or above `maxInputLength` (D21) — read
  /// from what it did with the [probe], which is longer than any signature:
  /// - cut it (the CPU path): `truncatedLength` is the limit;
  /// - split it into windows and averaged them (WebGPU, which ignores the
  ///   overflow strategy): the window is the limit. It is pinned, not
  ///   guessed: [liteRtLmMaxInputLength] tokens must be one window and one
  ///   token more two, by the engine's own counts;
  /// - neither: null (a model whose limit is beyond the probe).
  Future<int?> _inputLimit(
    LiteRtLmWebEngine engine,
    LiteRtLmWebEmbedding probe,
  ) async {
    if (probe.truncatedLength case final limit?) return limit;
    if (probe.numChunks <= 1) return null;
    // BOS and EOS, as the engine counted them around the probe's words.
    final special = probe.inputLength - _probeWords;
    final words = liteRtLmMaxInputLength - special;
    if (special < 0 || words < 1) return null;
    final atLimit = await engine.computeEmbedding(
      LiteRtLmWebText(_the(words)),
      _options,
    );
    final overLimit = await engine.computeEmbedding(
      LiteRtLmWebText(_the(words + 1)),
      _options,
    );
    final pinned =
        atLimit.inputLength == liteRtLmMaxInputLength &&
        atLimit.numChunks == 1 &&
        atLimit.truncatedLength == null &&
        overLimit.inputLength == liteRtLmMaxInputLength + 1 &&
        overLimit.numChunks == 2;
    runtimeLog(
      '[LiteRtLmWebEmbedder] $_file: the engine split the '
      '${probe.inputLength}-token probe into ${probe.numChunks} windows '
      'instead of truncating it (${_config.backend.name}); '
      '${atLimit.inputLength} tokens took ${atLimit.numChunks}, '
      '${overLimit.inputLength} took ${overLimit.numChunks}'
      '${pinned ? ': the window is $liteRtLmMaxInputLength' : ''}.',
    );
    return pinned ? liteRtLmMaxInputLength : null;
  }

  Future<void> _requireRuntime() async {
    final LiteRtLmWebRuntimeState state;
    try {
      state = await _config.runtime.ensureReady();
    } on LiteRtLmWebModuleError catch (e) {
      throw EmbedderLoadException(e.message, cause: e);
    } catch (e) {
      throw EmbedderLoadException(
        '@litert-lm/core did not load on this page (window.litertLmReady '
        'failed): $e',
        cause: e,
      );
    }
    switch (state) {
      case LiteRtLmWebRuntimeState.ready:
        return;
      case LiteRtLmWebRuntimeState.loaderMissing:
        throw const EmbedderLoadException(
          'web/index.html does not load @litert-lm/core, so there is no '
          'EmbeddingEngine for EmbeddingGemma 2. Add the module script from '
          "litertlm_dart's README (On the web): it imports "
          '$liteRtLmWebModuleUrl and sets $liteRtLmWebModuleShimLine',
        );
      case LiteRtLmWebRuntimeState.embeddingEngineMissing:
        throw EmbedderLoadException(
          liteRtLmWebModuleMemberMessage(
            'EmbeddingEngine',
            'a value of type undefined',
          ),
        );
      case LiteRtLmWebRuntimeState.runtimeIncomplete:
        throw EmbedderLoadException(
          'The page\'s @litert-lm/core EmbeddingEngine lacks '
          '${_config.runtime.missingMembers.join(', ')}, which this release '
          'calls: import $liteRtLmWebModuleUrl in its module script.',
        );
    }
  }

  /// Refuses a page that cannot run the GPU backend, before anything is
  /// created: there is no CPU path to fall back to.
  Future<void> _requireWebGpu() async {
    final LiteRtLmWebGpuSupport support;
    try {
      support = await _config.runtime.webGpuSupport();
    } catch (e) {
      throw EmbedderLoadException(
        _webGpuRefusal('asking the browser for a WebGPU adapter failed: $e'),
        cause: e,
      );
    }
    switch (support) {
      case LiteRtLmWebGpuSupport.available:
        return;
      case LiteRtLmWebGpuSupport.noWebGpu:
        throw EmbedderLoadException(
          _webGpuRefusal('this browser has no WebGPU (navigator.gpu)'),
        );
      case LiteRtLmWebGpuSupport.noAdapter:
        throw EmbedderLoadException(
          _webGpuRefusal(
            'WebGPU found no GPU adapter (navigator.gpu.requestAdapter() '
            'returned null)',
          ),
        );
    }
  }

  String _webGpuRefusal(String why) =>
      'EmbeddingGemma 2 on the web needs WebGPU, and $why, so $_file was not '
      'loaded. There is no CPU fallback: the CPU (WebAssembly) path of '
      '$liteRtLmWebRuntime loads the EmbeddingGemma 2 .litertlm bundles but '
      'is too slow to use (measured on 0.20.0: load 110-225 s, then 9-12 s '
      'per short text on the page\'s main thread). Use a browser with WebGPU '
      'enabled and a GPU it can use.';

  /// Creates the engine for [url] into [_engine] and returns the settings it
  /// got.
  Future<LiteRtLmWebEngineSettings> _createEngine(
    String url, {
    required bool images,
    required bool audio,
  }) async {
    final settings = LiteRtLmWebEngineSettings(
      modelUrl: url,
      backend: _config.backend,
      // Unset = no tower: a text-only embedder never pays for one.
      visionBackend: images ? _config.backend : null,
      audioBackend: audio ? _config.audioBackend : null,
      maxInputLength: liteRtLmMaxInputLength,
      minInputLength: _config.minInputLength,
      visionTokensPerImage: images ? _config.visionTokensPerImage : null,
    );
    try {
      _engine = await _config.runtime.create(settings);
    } catch (e) {
      // A vision encoder that does not fit next to a loaded LLM fails here:
      // the page's one WebAssembly module has 4 GB of memory (wasm32), which
      // the 440m's vision engine (3.3 GB of it) and Gemma 4 E2B do not share
      // — measured on Chrome 155: "Failed to modify graph with delegate" with
      // the LLM loaded, fine once it is closed. It cannot be told apart from
      // other failures without matching the message, so the hint is
      // conditional. (A bundle with no vision encoder never gets here: the
      // container header refused it.)
      const visionHint =
          '. If a .litertlm LLM is loaded on this page, close it first: '
          'the page\'s @litert-lm/core WebAssembly module has 4 GB of memory, '
          'and the vision encoder does not fit in it next to an LLM such as '
          'Gemma 4 E2B.';
      // The CPU path is selected only by the drive suite's record. On 0.19.0
      // every EmbeddingGemma 2 bundle failed here ("Failed to get external
      // weight for buffer id …"); 0.20.0 loads them (measured), so a failure
      // on the CPU is something else, and the hint only says where they run.
      const cpuHint =
          '. The CPU (WebAssembly) path of $liteRtLmWebRuntime is for '
          'measurement only (it loads the EmbeddingGemma 2 .litertlm bundles '
          'but is too slow to use); they run on WebGPU, the default '
          'backend.';
      final cpu = _config.backend == LiteRtLmWebBackend.cpu;
      final towers = [
        if (images) 'its vision encoder',
        if (audio) 'its audio encoder',
      ];
      throw EmbedderLoadException(
        'LiteRT-LM could not create the embedding engine for $_file '
        '(${_config.backend.name}'
        '${towers.isEmpty ? '' : ', with ${towers.join(' and ')}'})'
        // On the CPU path the CPU is the reason, with or without media.
        ': $e${cpu ? cpuHint : (images ? visionHint : '')}',
        cause: e,
      );
    }
    return settings;
  }

  /// The vector of [input]: its text (task prefix already in front), its
  /// images and its audio, as one request. Throws
  /// [EmbedderInputTooLongException] for an input the engine had to cut or
  /// split (never the cut or averaged vector), [EmbedderEngineException] for
  /// any other failure.
  Future<List<double>> embed(EmbedderInput input) async {
    final engine = _engine;
    if (_state != _EmbedderState.loaded || engine == null) {
      throw const EmbedderEngineException(
        'LiteRtLmWebEmbedder.embed() needs a loaded, open embedder',
      );
    }
    // The native order (`embedding_parts.dart`): the text with its task
    // prefix — the engine adds BOS and EOS — then the images in order, then
    // the audio. A media part is the encoded file as it is, never prefixed.
    final parts = <LiteRtLmWebInput>[
      if (input.text case final text?) LiteRtLmWebText(text),
      for (final image in input.images) LiteRtLmWebImage(image),
      if (input.audio case final audio?) LiteRtLmWebAudio(audio),
    ];
    final images = input.images.isNotEmpty;
    final audio = input.audio != null;
    if (parts.isEmpty || (images && !_images) || (audio && !_audio)) {
      throw EmbedderEngineException(
        'LiteRT-LM embeds text and the media $_file was loaded with: '
        '${[if (input.text != null) 'text', if (images) '${input.images.length} image(s)', if (audio) 'audio'].join(', ')} '
        'is not that.',
      );
    }
    final request = parts.length == 1 ? parts.single : LiteRtLmWebParts(parts);
    // A lone image is a fixed number of vision tokens, far below the limit:
    // if the engine cuts or splits one, that is not an input the caller could
    // shorten.
    final loneImage = request is LiteRtLmWebImage;
    final what = switch (request) {
      LiteRtLmWebText() => 'text',
      LiteRtLmWebImage() => 'image',
      LiteRtLmWebAudio() => 'audio clip',
      LiteRtLmWebParts() => 'combined input',
    };

    final LiteRtLmWebEmbedding response;
    try {
      response = await liteRtLmPageLock.run(() {
        // Closed while it waited for the page: the engine is deleted.
        _checkNotClosed();
        return engine.computeEmbedding(request, _options);
      });
    } on LiteRtLmPagePoisonedError {
      // The page's state, not this embedding's: the caller tells them apart.
      rethrow;
    } catch (e) {
      throw EmbedderEngineException(
        'LiteRT-LM could not embed the $what for $_file: $e',
        cause: e,
      );
    }
    final media = images || audio;
    if (response.truncatedLength case final limit?) {
      if (loneImage) {
        throw EmbedderEngineException(
          'LiteRT-LM truncated an image of $_file at $limit of '
          '${response.inputLength} tokens',
        );
      }
      throw _tooLong(response.inputLength, limit, media: media);
    }
    if (response.numChunks > 1) {
      // WebGPU: the engine averaged windows of the input instead of cutting
      // it — a vector of a different kind than every other in the index.
      final limit = _maxInputTokens;
      if (loneImage || limit == null) {
        throw EmbedderEngineException(
          'LiteRT-LM split the ${response.inputLength}-token $what for $_file '
          'into ${response.numChunks} windows and averaged them'
          '${limit == null ? ' (its window is unknown)' : ''}; nothing was '
          'returned for it.${loneImage ? '' : ' Split the input and embed the pieces.'}',
        );
      }
      throw _tooLong(response.inputLength, limit, media: media);
    }
    final vector = response.embedding;
    if (vector.length != _dimension) {
      throw EmbedderEngineException(
        '$_file returned a vector of ${vector.length} values for dimension '
        '$_dimension',
      );
    }
    if (_unusable(vector)) {
      throw EmbedderEngineException(
        'LiteRT-LM returned a vector with NaN, infinity or only zeros for '
        'the $what of $_file on ${_config.backend.name}',
      );
    }
    return vector;
  }

  EmbedderInputTooLongException _tooLong(
    int actual,
    int limit, {
    required bool media,
  }) => EmbedderInputTooLongException(
    media
        // The native words: the media tokens count against the same limit.
        ? 'The input is $actual tokens long; $_file accepts at most $limit '
              '(task prefix, BOS and EOS included, and media too: about 140 '
              'tokens per image and 25 per second of audio). Nothing was '
              'embedded; split the input and embed the pieces.'
        : 'The input is $actual tokens (task prefix, BOS and EOS included); '
              '$_file takes at most $limit. Nothing was returned for it; split '
              'the text and embed the pieces.',
    maxInputTokens: limit,
    actualTokens: actual,
  );

  void _checkNotClosed() {
    if (_state == _EmbedderState.closed) {
      throw StateError('The embedder for $_file is closed.');
    }
  }

  /// Deletes the engine; waits for a call in flight inside the runtime. A
  /// call still queued on the page lock is refused when its turn comes.
  Future<void> close() async {
    if (_state == _EmbedderState.closed) return;
    _state = _EmbedderState.closed;
    final engine = _engine;
    _engine = null;
    // Waits for a call in flight inside the runtime (its own mutex): the
    // load's probe may be one.
    if (engine != null) await engine.delete();
  }
}

enum _EmbedderState { fresh, loading, loaded, failed, closed }

/// A vector no normalised embedding can be: a NaN or infinity, or all zeros.
bool _unusable(List<double> vector) =>
    vector.any((v) => !v.isFinite) || vector.every((v) => v == 0);
