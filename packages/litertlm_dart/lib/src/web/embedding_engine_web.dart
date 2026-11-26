// The web `EmbeddingEngine`: the same public shape as the native one
// (`src/api/embedding_engine.dart`), over [LiteRtLmWebEmbedder] and the page's
// `@litert-lm/core` `EmbeddingEngine` ([liteRtLmWebRuntime]). The public
// library exports it in place of the native one where `dart.library.js_interop`
// is true.

import 'dart:typed_data' show Float32List;

import '../api/backend.dart';
import '../api/embedding_engine_config.dart';
import '../api/message.dart';
import '../embedder/embedder_constants.dart'
    show
        liteRtLmDefaultVisionTokensPerImage,
        liteRtLmEg2TextSignatures,
        liteRtLmMaxInputLength,
        liteRtLmVisionTokenBudgets;
import '../embedder/embedder_types.dart';
import '../runtime/runtime_log.dart';
import '../runtime/types.dart' show BackendKind;
import 'embedding_runtime_js.dart';
import 'web_embedder.dart';
import 'web_runtime_version.dart';

/// An EmbeddingGemma 2 model, loaded by the page's runtime.
final class EmbeddingEngine {
  EmbeddingEngine._(this._embedder, this.info);

  final LiteRtLmWebEmbedder _embedder;

  /// The dimension, the input limit, the modalities and the backend that
  /// loaded.
  final EmbedderInfo info;

  /// Loads [config.modelPath], a URL the page can fetch (`blob:`, `https:`),
  /// on WebGPU ([Backend.gpu]; a page without WebGPU is refused). The vision
  /// tower, when [config.visionBackend] is set, runs on the text tower's
  /// backend; the audio tower on
  /// [config.audioBackend].
  ///
  /// Throws [UnsupportedError] for what does not run here: the CPU text
  /// tower, the NPU, a CPU thread count, a `cacheDir` or `requireWeightCache`
  /// (the web runtime keeps no weight cache), an `activationDataType` (its
  /// `EmbeddingEngine` settings take none); [ArgumentError] for a
  /// `maxInputLength` above the longest EmbeddingGemma 2 text signature,
  /// 8192, as natively above the bundle's longest (the page cannot read the
  /// bundle's own); [EmbedderLoadException] for a bundle or a page that
  /// cannot run as asked.
  static Future<EmbeddingEngine> create(EmbeddingEngineConfig config) async {
    if (config.maxInputLength case final length?
        when length > liteRtLmEg2TextSignatures.last) {
      throw ArgumentError.value(
        length,
        'maxInputLength',
        'must be from 1 to the longest text signature, '
            '${liteRtLmEg2TextSignatures.last} (signatures: '
            '${liteRtLmEg2TextSignatures.join(', ')})',
      );
    }
    if (config.activationDataType != null) {
      throw UnsupportedError(
        'The web runtime ($liteRtLmWebRuntime) takes no activation type for '
        'an EmbeddingEngine (its EmbeddingEngineSettings have none): leave '
        'activationDataType unset on the web.',
      );
    }
    if (config.cacheDir != null || config.requireWeightCache) {
      throw UnsupportedError(
        'The web runtime ($liteRtLmWebRuntime) keeps no weight cache: leave '
        'cacheDir unset and requireWeightCache false on the web.',
      );
    }
    if (config.backend is CpuBackend) {
      throw UnsupportedError(
        'EmbeddingGemma 2 runs on WebGPU only on the web: the CPU '
        '(WebAssembly) path of $liteRtLmWebRuntime loads the bundles but is '
        'too slow to use (measured on 0.20.0 in Chrome 158, 2026-11-25: '
        'load 110-225 s, then 9-12 s per short text on the page\'s main '
        'thread, about 80 times WebGPU). Pass backend: Backend.gpu().',
      );
    }
    final backend = _webBackend(config.backend, 'backend');
    final audio = config.audioBackend;
    final budget =
        config.visionTokensPerImage ?? liteRtLmDefaultVisionTokensPerImage;
    if (!liteRtLmVisionTokenBudgets.contains(budget)) {
      throw ArgumentError.value(
        config.visionTokensPerImage,
        'visionTokensPerImage',
        'must be one of $liteRtLmVisionTokenBudgets',
      );
    }
    if (config.visionBackend case final vision?
        when _webBackend(vision, 'visionBackend') != backend) {
      throw UnsupportedError(
        'On the web the vision tower runs on the text tower\'s backend '
        '($backend); visionBackend $vision differs.',
      );
    }
    final file = config.modelPath.split('/').last;
    final embedder = LiteRtLmWebEmbedder(
      LiteRtLmWebEmbedderConfig(
        modelPath: config.modelPath,
        fileName: file.isEmpty ? config.modelPath : file,
        runtime: const WindowLiteRtLmWebRuntime(),
        resolveUrl: (path) async => path,
        revokeUrl: (_) {},
        declaredMedia: {
          if (config.visionBackend != null) EmbedderModality.image,
          if (audio != null) EmbedderModality.audio,
        },
        visionTokensPerImage: budget,
        maxInputLength: config.maxInputLength ?? liteRtLmMaxInputLength,
        backend: backend,
        audioBackend: audio == null
            ? liteRtLmWebAudioBackend
            : _webBackend(audio, 'audioBackend'),
      ),
    );
    final loaded = await embedder.load();
    final limit = loaded.maxInputTokens;
    if (limit == null) {
      try {
        await embedder.close();
      } catch (e) {
        // The refusal below is the answer; a failed close only goes to the
        // log.
        runtimeLog('[litertlm_dart/web] closing a refused embedder: $e');
      }
      throw EmbedderLoadException(
        'LiteRT-LM could not pin the input limit of ${config.modelPath} on '
        'the web ($liteRtLmWebRuntime): the engine neither truncated nor '
        'split its over-long probe as expected.',
      );
    }
    return EmbeddingEngine._(
      embedder,
      EmbedderInfo(
        dimension: loaded.dimension,
        maxInputTokens: limit,
        modalities: loaded.modalities,
        visionTokensPerImage: loaded.visionTokensPerImage,
        activeBackend: switch (backend) {
          LiteRtLmWebBackend.cpu => BackendKind.cpu,
          LiteRtLmWebBackend.gpu => BackendKind.gpu,
        },
      ),
    );
  }

  /// Always null on the web: the runtime keeps no weight cache.
  String? get cacheDir => null;

  bool _closed = false;

  /// The embedding of [contents]: at most one text part (its task prefix
  /// already in front), any image parts and at most one audio part, one
  /// vector for all of them, computed with [options] (the runtime's own
  /// `EmbeddingOptions`, as Kotlin's and Swift's). Throws
  /// [EmbedderInputTooLongException] for an input over the limit (never
  /// truncated), [ArgumentError] for contents it does not take or [options]
  /// it cannot apply (a vision budget other than the engine's: the runtime
  /// prepares that one vision signature) and [StateError] after [close].
  Future<Float32List> computeEmbedding(
    List<Content> contents, {
    EmbeddingOptions options = const EmbeddingOptions(),
  }) async {
    if (_closed) throw StateError('The embedding engine is closed.');
    final input = embedderInputOfContents(contents, info.modalities);
    return Float32List.fromList(await _embedder.embed(input, options: options));
  }

  /// Deletes the engine.
  Future<void> close() {
    _closed = true;
    return _embedder.close();
  }
}

LiteRtLmWebBackend _webBackend(Backend backend, String name) =>
    switch (backend) {
      CpuBackend(threadCount: null) => LiteRtLmWebBackend.cpu,
      GpuBackend() => LiteRtLmWebBackend.gpu,
      CpuBackend() => throw UnsupportedError(
        'The web runtime ($liteRtLmWebRuntime) takes no CPU thread count '
        '($name).',
      ),
      NpuBackend() => throw UnsupportedError(
        'EmbeddingGemma 2 runs on the NPU only natively, not on the web '
        '($name).',
      ),
    };
