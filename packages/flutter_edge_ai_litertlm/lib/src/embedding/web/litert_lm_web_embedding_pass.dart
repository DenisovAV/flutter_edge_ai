// The EmbeddingGemma 2 `.litertlm` embedding pass on the web, over
// `@litert-lm/core` 0.18.0's `EmbeddingEngine` — what the web
// `LiteRtEmbeddingBackend.describe` hands core for a self-contained
// `.litertlm` embedder spec. Core hosts it inline on the page, checks every
// request against what `load()` reported, and closes it (R5 §4.5, §7 P2w).
//
// Pure Dart: the runtime arrives in the config as a [LiteRtLmWebRuntime] (the
// `dart:js_interop` one over the page's `window.EmbeddingEngine`, a fake in the
// VM tests), so nothing here imports `dart:js_interop`.
//
// What it decides, and why:
// - The page exposes the runtime through the same module script as the LLM
//   engine (`window.litertLmReady`), plus one line,
//   `window.EmbeddingEngine = m.EmbeddingEngine;`. Without that line there is
//   no engine to create; the load fails with an EmbeddingLoadException that
//   names the missing line instead of a JS `undefined` deep in the runtime.
// - One `EmbeddingEngine` per pass, created at load and deleted at close; core
//   never has two embedders resident at once. The runtime's WebAssembly module
//   is page-global and shared with the `.litertlm` LLM engine, whose calls the
//   runtime does not order against these: the create + probe and every
//   `computeEmbedding` take `liteRtLmPageLock`, as the LLM's create,
//   conversation and generation do (see that file for why). The two engines
//   also share the module's one WebGPU device. `delete()` never suspends and
//   does not wait for it.
// - `maxInputLength: 1024` (D21, the runtime's own default), WebGPU for the
//   text and the vision tower. The CPU (WebAssembly) path of `@litert-lm/core`
//   0.18.0 cannot load the EmbeddingGemma 2 bundles: `EmbeddingEngine.create`
//   fails with "Failed to get external weight for buffer id …" for the 270m
//   and the 440m alike (measured on Chrome 155, and on the 0.19.0 nightly of
//   2026-10-11). WebGPU loads them, and its vectors match the native CPU
//   goldens (text cos >= 0.9948, images >= 0.9976, no NaN or zero vector), so
//   WebGPU is the backend — and there is no CPU fallback.
// - A page without WebGPU (no `navigator.gpu`, or no adapter) is refused
//   before `EmbeddingEngine.create`, with an EmbeddingLoadException that says
//   why, instead of the runtime's "No GPU adapter found." deep in the create.
//   The runtime sets up its WebGPU device itself, in `create`.
// - The vision tower is created only when images are declared
//   (`visionBackend` unset = vision disabled on the web), at 140 or 70 tokens
//   per image (D25). The web runtime has no ModelInfo, so a bundle without a
//   vision encoder (the 270m) is refused by `EmbeddingEngine.create` itself;
//   the load error then says which bundle embeds images.
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
// - At load the pass embeds one over-long probe text under TRUNCATE: the
//   vector's length is the model's dimension, and a NaN or all-zero vector —
//   the fp16 failure — refuses the load instead of serving wrong vectors. The
//   input limit the engine really enforces (prefix, BOS and EOS included)
//   comes from what it did with the probe: on the CPU path it truncates and
//   reports `truncatedLength`; on WebGPU `@litert-lm/core` 0.18.0 ignores the
//   overflow strategy (TRUNCATE and ERROR alike) and always splits an
//   over-long input into windows of its text signature and averages them
//   (`numChunks` > 1, no `truncatedLength`; measured on Chrome 155: 1024
//   tokens are one window, 1025 are two). There the limit is the window,
//   pinned by embedding exactly 1024 tokens (one window) and 1025 (two).
// - Every request runs under TRUNCATE. An input the engine had to cut
//   (`truncatedLength`) or split (`numChunks` > 1) is thrown as
//   EmbeddingInputTooLongException with the engine's exact count
//   (`inputLength`, media tokens included) — the truncated or averaged vector
//   is never returned.
// - Under `WebStorageMode.streaming` the model path is `opfs://`, which the
//   runtime's fetch() cannot open: it is resolved to a `blob:` URL first, and
//   that URL — created by this pass — is revoked once the engine has read it.

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

import '../../web/litert_lm_page_lock.dart';
import '../litert_lm_embedding_common.dart';
import '../litertlm_container.dart';
import '../vision_budget.dart' show liteRtLmDefaultVisionTokensPerImage;

/// The `@litert-lm/core` backends the pass can ask for (`Backend.CPU`,
/// `Backend.GPU`).
enum LiteRtLmWebBackend {
  /// XNNPack on WebAssembly. `@litert-lm/core` 0.18.0 cannot load the
  /// EmbeddingGemma 2 bundles on it (their external weights); the pass says
  /// so when `EmbeddingEngine.create` fails here.
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
  /// `window.EmbeddingEngine` is a constructor.
  ready,

  /// The page has no `@litert-lm/core` loader at all: neither
  /// `window.litertLmReady` nor `window.EmbeddingEngine`.
  loaderMissing,

  /// The loader ran, but `window.EmbeddingEngine` is not set: an index.html
  /// written for the LLM engine only.
  embeddingEngineMissing,
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
  /// then reports whether `window.EmbeddingEngine` exists. Throws when the
  /// loader itself failed (the module could not be imported).
  Future<LiteRtLmWebRuntimeState> ensureReady();

  /// Asks the browser for a WebGPU adapter as `@litert-lm/core` 0.18.0 does
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
final class LiteRtLmWebEmbeddingConfig {
  const LiteRtLmWebEmbeddingConfig({
    required this.modelPath,
    required this.fileName,
    required this.runtime,
    required this.resolveUrl,
    required this.revokeUrl,
    this.declaredMedia = const {},
    this.visionTokensPerImage = liteRtLmDefaultVisionTokensPerImage,
    this.backend = LiteRtLmWebBackend.gpu,
    @visibleForTesting this.audioBackend = liteRtLmWebAudioBackend,
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
  final Set<EmbeddingModality> declaredMedia;

  /// Vision tokens per image (D25): 140 or 70, checked by `describe()`.
  final int visionTokensPerImage;

  /// The backend of the text tower, and of the vision tower when images are
  /// declared: WebGPU. CPU is left selectable for the drive suite, which
  /// records that `@litert-lm/core` 0.18.0 still cannot load the bundles on
  /// it; nothing in the package selects it.
  final LiteRtLmWebBackend backend;

  /// The backend of the audio tower when audio is declared:
  /// [liteRtLmWebAudioBackend]. Left selectable so the CPU (WebAssembly)
  /// tower can be measured again; nothing in the package changes it.
  final LiteRtLmWebBackend audioBackend;

  /// `minInputLength`; null leaves the runtime's default (= the max input
  /// length: one signature). Set only by the drive suite's measurement of
  /// short-text latency against memory.
  final int? minInputLength;
}

/// The descriptor factory.
EmbeddingPass buildLiteRtLmWebEmbeddingPass(
  LiteRtLmWebEmbeddingConfig config,
) => LiteRtLmWebEmbeddingPass(config);

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

/// Throws [EmbeddingLoadException] unless the `.litertlm` bundle at [url]
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
  final List<String> types;
  try {
    types = await readLitertlmModelTypesFrom(
      (length) => runtime.readPrefix(url, length),
    );
  } on FormatException catch (e) {
    throw liteRtLmUnreadableContainer(fileName, e.message, e);
  } catch (e) {
    // A failed fetch() of the page's own copy (a JS TypeError).
    throw liteRtLmUnreadableContainer(fileName, '$e', e);
  }
  if (!litertlmHasAudioEncoder(types)) throw liteRtLmNoAudioEncoder(fileName);
}

/// [requireLiteRtLmWebAudioEncoder] for the bundle [config] names, as
/// `describe()` runs it before core closes the embedder it holds: the
/// `opfs://` path resolved to a `blob:` URL for the read, and that URL
/// revoked after it, whatever the outcome.
Future<void> requireLiteRtLmWebAudioEncoderFor(
  LiteRtLmWebEmbeddingConfig config,
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
Future<String> _resolveModelUrl(LiteRtLmWebEmbeddingConfig config) async {
  final rawPath = config.modelPath;
  try {
    return await config.resolveUrl(rawPath);
  } catch (e) {
    // Named here: unwrapped, a JS error reached the app as a bare
    // "TypeError: Failed to fetch" with no file and no step in it.
    throw EmbeddingLoadException(
      'LiteRT-LM could not open ${config.fileName} from the page\'s model '
      'storage ($rawPath): $e',
      engine: liteRtLmEngineTag,
      cause: e,
    );
  }
}

/// The `index.html` line the page needs for EmbeddingGemma 2, word for word.
const liteRtLmWebShimLine = 'window.EmbeddingEngine = m.EmbeddingEngine;';

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

/// The `.litertlm` embedding pass on the web: text, images when declared on a
/// bundle with a vision encoder, audio when declared on a bundle with an
/// audio encoder, and any combination of them in one vector.
final class LiteRtLmWebEmbeddingPass extends EmbeddingPass {
  LiteRtLmWebEmbeddingPass(this._config);

  final LiteRtLmWebEmbeddingConfig _config;

  LiteRtLmWebEngine? _engine;
  int _dimension = 0;
  int? _maxInputTokens;
  bool _images = false;
  bool _audio = false;
  bool _loading = false;
  bool _loaded = false;
  bool _closed = false;

  String get _file => _config.fileName;

  @override
  Future<EmbeddingPassInfo> load() async {
    if (_loading || _loaded || _closed) {
      throw StateError(
        'LiteRtLmWebEmbeddingPass.load() runs once, before close',
      );
    }
    _loading = true;
    final media = _config.declaredMedia;
    await _requireRuntime();
    if (_config.backend == LiteRtLmWebBackend.gpu) await _requireWebGpu();
    final images = media.contains(EmbeddingModality.image);
    final audio = media.contains(EmbeddingModality.audio);
    final rawPath = _config.modelPath;
    final url = await _resolveModelUrl(_config);
    final LiteRtLmWebEngineSettings settings;
    final LiteRtLmWebEmbedding probe;
    final int? maxInputTokens;
    try {
      // From the container, before any engine exists (D23): describe() has
      // asked already; this is the backstop for a pass built another way.
      if (audio) {
        await requireLiteRtLmWebAudioEncoder(
          _config.runtime,
          url,
          fileName: _file,
        );
      }
      // Both suspend inside the page's WebAssembly module (the create reads
      // the model stream), so they take the page lock the LLM engine takes
      // too.
      (settings, probe, maxInputTokens) = await liteRtLmPageLock.run(() async {
        final settings = await _createEngine(url, images: images, audio: audio);
        final engine = _engine!;
        try {
          final probe = await engine.computeEmbedding(
            LiteRtLmWebText(_probeText),
            _options,
          );
          return (settings, probe, await _inputLimit(engine, probe));
        } catch (e) {
          throw EmbeddingLoadException(
            'LiteRT-LM created the embedding engine for $_file but could not '
            'embed with it (${_config.backend.name}): $e',
            engine: liteRtLmEngineTag,
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
      throw EmbeddingLoadException(
        'LiteRT-LM returned an empty vector for $_file',
        engine: liteRtLmEngineTag,
      );
    }
    if (_unusable(probe.embedding)) {
      throw EmbeddingLoadException(
        'LiteRT-LM returned a vector with NaN, infinity or only zeros for '
        '$_file on ${_config.backend.name}; nothing was embedded. This is how '
        'reduced-precision (fp16) inference fails for EmbeddingGemma 2.',
        engine: liteRtLmEngineTag,
      );
    }
    if (maxInputTokens == null) {
      edgeAiLog(
        '[LiteRtLmWebEmbeddingPass] $_file embedded '
        '${probe.inputLength} tokens in ${probe.numChunks} window(s) without '
        'truncating, and its window could not be pinned: its input limit is '
        'unknown, so maxInputTokens is null.',
      );
    }

    _dimension = dimension;
    _maxInputTokens = maxInputTokens;
    _images = images;
    _audio = audio;
    _loaded = true;
    edgeAiLog(
      '[LiteRtLmWebEmbeddingPass] loaded $_file: dim=$dimension, '
      'maxInputTokens=$maxInputTokens, $settings',
    );
    return EmbeddingPassInfo(
      dimension: dimension,
      maxInputTokens: maxInputTokens,
      modalities: {
        EmbeddingModality.text,
        if (images) EmbeddingModality.image,
        if (audio) EmbeddingModality.audio,
      },
      imageFormats: images ? liteRtLmImageFormats : const {},
      audioFormats: audio ? liteRtLmAudioFormats : const {},
      combinedInputs: true,
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
    edgeAiLog(
      '[LiteRtLmWebEmbeddingPass] $_file: the engine split the '
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
    } catch (e) {
      throw EmbeddingLoadException(
        '@litert-lm/core did not load on this page (window.litertLmReady '
        'failed): $e',
        engine: liteRtLmEngineTag,
        cause: e,
      );
    }
    switch (state) {
      case LiteRtLmWebRuntimeState.ready:
        return;
      case LiteRtLmWebRuntimeState.loaderMissing:
        throw const EmbeddingLoadException(
          'web/index.html does not load @litert-lm/core, so there is no '
          'EmbeddingEngine for EmbeddingGemma 2. Add the module script from '
          "flutter_edge_ai_litertlm's README (Web setup): it imports "
          '@litert-lm/core@0.18.0, sets window.Engine = m.Engine; and '
          '$liteRtLmWebShimLine',
          engine: liteRtLmEngineTag,
        );
      case LiteRtLmWebRuntimeState.embeddingEngineMissing:
        throw const EmbeddingLoadException(
          'window.EmbeddingEngine is not set: web/index.html loads '
          '@litert-lm/core for the LLM engine only. Add '
          '$liteRtLmWebShimLine next to window.Engine = m.Engine; in its '
          'module script.',
          engine: liteRtLmEngineTag,
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
      throw EmbeddingLoadException(
        _webGpuRefusal('asking the browser for a WebGPU adapter failed: $e'),
        engine: liteRtLmEngineTag,
        cause: e,
      );
    }
    switch (support) {
      case LiteRtLmWebGpuSupport.available:
        return;
      case LiteRtLmWebGpuSupport.noWebGpu:
        throw EmbeddingLoadException(
          _webGpuRefusal('this browser has no WebGPU (navigator.gpu)'),
          engine: liteRtLmEngineTag,
        );
      case LiteRtLmWebGpuSupport.noAdapter:
        throw EmbeddingLoadException(
          _webGpuRefusal(
            'WebGPU found no GPU adapter (navigator.gpu.requestAdapter() '
            'returned null)',
          ),
          engine: liteRtLmEngineTag,
        );
    }
  }

  String _webGpuRefusal(String why) =>
      'EmbeddingGemma 2 on the web needs WebGPU, and $why, so $_file was not '
      'loaded. There is no CPU fallback: the CPU (WebAssembly) path of '
      '@litert-lm/core 0.18.0 cannot read the external weights of the '
      'EmbeddingGemma 2 .litertlm bundles. Use a browser with WebGPU enabled '
      'and a GPU it can use.';

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
      // Without ModelInfo on the web, a bundle with no vision encoder is
      // refused here, by the runtime — among other failures this pass cannot
      // tell apart without matching the message, so the hint is conditional.
      // So is a vision encoder that does not fit next to a loaded LLM: the
      // page's one WebAssembly module has 4 GB of memory (wasm32), which the
      // 440m's vision engine (3.3 GB of it) and Gemma 4 E2B do not share —
      // measured on Chrome 155: "Failed to modify graph with delegate" with
      // the LLM loaded, fine once it is closed.
      const visionHint =
          '. If the bundle has no vision encoder (embeddinggemma-2-text-270m '
          'has none), install embeddinggemma-2-text-vision-440m to embed '
          'images. If a .litertlm LLM is loaded on this page, close it first: '
          'the page\'s @litert-lm/core WebAssembly module has 4 GB of memory, '
          'and the vision encoder does not fit in it next to an LLM such as '
          'Gemma 4 E2B.';
      // Every EmbeddingGemma 2 bundle fails here on the CPU, with "Failed to
      // get external weight for buffer id …": say why, whatever the message.
      const cpuHint =
          '. The CPU (WebAssembly) path of @litert-lm/core 0.18.0 cannot read '
          'the external weights of the EmbeddingGemma 2 .litertlm bundles; '
          'they load on WebGPU, the default backend.';
      final cpu = _config.backend == LiteRtLmWebBackend.cpu;
      final towers = [
        if (images) 'its vision encoder',
        if (audio) 'its audio encoder',
      ];
      throw EmbeddingLoadException(
        'LiteRT-LM could not create the embedding engine for $_file '
        '(${_config.backend.name}'
        '${towers.isEmpty ? '' : ', with ${towers.join(' and ')}'})'
        // On the CPU path the CPU is the reason, with or without media.
        ': $e${cpu ? cpuHint : (images ? visionHint : '')}',
        engine: liteRtLmEngineTag,
        cause: e,
      );
    }
    return settings;
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final engine = _engine;
    if (!_loaded || _closed || engine == null) {
      throw const EmbeddingEngineException(
        'LiteRtLmWebEmbeddingPass.embed() needs a loaded, open pass',
        engine: liteRtLmEngineTag,
      );
    }
    // The native order (`embedding_parts.dart`): the text with its task
    // prefix — the one prefix function; the engine adds BOS and EOS — then
    // the images in order, then the audio. A media part is the encoded file
    // as it is, never prefixed.
    final parts = <LiteRtLmWebInput>[
      if (input.text case final text?) LiteRtLmWebText(taskType.prefix + text),
      for (final image in input.images) LiteRtLmWebImage(image),
      if (input.audio case final audio?) LiteRtLmWebAudio(audio),
    ];
    final images = input.images.isNotEmpty;
    final audio = input.audio != null;
    if (parts.isEmpty || (images && !_images) || (audio && !_audio)) {
      // Core refuses all of these before calling (only the modalities the
      // model was loaded with, and never an input without a part); reaching
      // here is a host bug.
      throw EmbeddingEngineException(
        'flutter_edge_ai_litertlm embeds text and the media this model was '
        'loaded with, got $input',
        engine: liteRtLmEngineTag,
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
      response = await liteRtLmPageLock.run(
        () => engine.computeEmbedding(request, _options),
      );
    } catch (e) {
      throw EmbeddingEngineException(
        'LiteRT-LM could not embed the $what for $_file: $e',
        engine: liteRtLmEngineTag,
        cause: e,
      );
    }
    final media = images || audio;
    if (response.truncatedLength case final limit?) {
      if (loneImage) {
        throw EmbeddingEngineException(
          'LiteRT-LM truncated an image of $_file at $limit of '
          '${response.inputLength} tokens',
          engine: liteRtLmEngineTag,
        );
      }
      throw _tooLong(response.inputLength, limit, media: media);
    }
    if (response.numChunks > 1) {
      // WebGPU: the engine averaged windows of the input instead of cutting
      // it — a vector of a different kind than every other in the index.
      final limit = _maxInputTokens;
      if (loneImage || limit == null) {
        throw EmbeddingEngineException(
          'LiteRT-LM split the ${response.inputLength}-token $what for $_file '
          'into ${response.numChunks} windows and averaged them'
          '${limit == null ? ' (its window is unknown)' : ''}; nothing was '
          'returned for it.${loneImage ? '' : ' Split the input and embed the pieces.'}',
          engine: liteRtLmEngineTag,
        );
      }
      throw _tooLong(response.inputLength, limit, media: media);
    }
    final vector = response.embedding;
    if (vector.length != _dimension) {
      throw EmbeddingEngineException(
        '$_file returned a vector of ${vector.length} values for dimension '
        '$_dimension',
        engine: liteRtLmEngineTag,
      );
    }
    if (_unusable(vector)) {
      throw EmbeddingEngineException(
        'LiteRT-LM returned a vector with NaN, infinity or only zeros for '
        'the $what of $_file on ${_config.backend.name}',
        engine: liteRtLmEngineTag,
      );
    }
    return vector;
  }

  EmbeddingInputTooLongException _tooLong(
    int actual,
    int limit, {
    required bool media,
  }) => EmbeddingInputTooLongException(
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

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final engine = _engine;
    _engine = null;
    // Waits for a call in flight inside the runtime (its own mutex); core
    // never closes while one of ITS calls runs, but the load's probe may be.
    if (engine != null) await engine.delete();
  }
}

/// A vector no normalised embedding can be: a NaN or infinity, or all zeros.
bool _unusable(List<double> vector) =>
    vector.any((v) => !v.isFinite) || vector.every((v) => v == 0);
