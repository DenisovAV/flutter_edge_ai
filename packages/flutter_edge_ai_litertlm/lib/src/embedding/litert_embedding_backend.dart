// LiteRT embedding backend — native arm. It only DESCRIBES what to run
// (`describe()` is pure: no native library, no isolate); core builds the pass
// in its embedding worker, hosts it, checks every request and closes it.
//
// Routing is by the file core actually opens (`config.modelPath`): a
// `.litertlm` bundle (EmbeddingGemma 2 — text, images and audio, alone or
// combined — through LiteRT-LM's EmbeddingEngine) or a `.tflite` graph with a
// separate tokenizer (EmbeddingGemma 1, Gecko, text, through the LiteRT C
// API).
//
// A `.litertlm` bundle is read before anything else happens: a per-SoC bundle
// (compiled for one NPU) runs only on that NPU and only when `npu` was asked
// for; the generic bundle runs only on CPU (litert_lm_npu.dart). describe()
// is still the place for that — no worker, no engine — but no longer free of
// I/O: it reads a few KB of the bundle (its NPU target, and its audio encoder
// when audio is declared) and, for the NPU, asks the platform.

import 'dart:io' show FileSystemException, Platform;

import 'package:flutter_edge_ai/engine.dart';
import 'package:path_provider/path_provider.dart';

import 'litert_embedding_pass.dart';
import 'litert_lm_embedding_pass.dart';
import 'litert_lm_npu.dart';
import 'litertlm_npu_target.dart';
import 'vision_budget.dart';
import 'weight_cache_notice.dart';

/// LiteRT embedding backend: `.tflite` embedders (EmbeddingGemma 1, Gecko)
/// over the LiteRT C API, and `.litertlm` embedding bundles (EmbeddingGemma 2:
/// text, images on a bundle with a vision encoder, audio on a bundle with an
/// audio encoder, and combinations of them in one vector) over LiteRT-LM's
/// EmbeddingEngine.
///
/// EmbeddingGemma 2 runs on CPU, or — for a bundle compiled for one SoC
/// (`…_Qualcomm_SM8850.litertlm`, `…_Intel_PTL.litertlm`), loaded with
/// `getActiveEmbedder(preferredBackend: PreferredBackend.npu)` — on that SoC's
/// NPU: on Qualcomm Android and Qualcomm Linux arm64 in an app built with
/// `hooks: user_defines: flutter_edge_ai_litertlm: qualcomm_npu: true`, and
/// on Intel NPUs with Windows x64 (Panther Lake).
/// Nothing switches backend on its own: the generic bundle with `npu`, a
/// per-SoC bundle without it, and `npu` where it cannot run are refused with
/// an `EmbeddingLoadException`, because NPU and CPU vectors are not
/// interchangeable.
final class LiteRtEmbeddingBackend extends EmbeddingBackendProvider {
  /// [visionTokensPerImage] is how many vision tokens an EmbeddingGemma 2
  /// image gets: 140 (the default, closest to the reference model) or 70
  /// (about twice as fast, slightly less faithful). The two give different
  /// image vectors, so an image index records which one it was built with —
  /// give it its own profile id (`…-vis140` or `…-vis70`). Any other value is
  /// refused with `EmbeddingLoadException` when a model loads. Text vectors
  /// do not depend on it.
  ///
  /// [requireWeightCache] (flutter_edge_ai_litertlm 1.14.0) concerns
  /// EmbeddingGemma 2. Its engine writes a weight cache into the app's cache
  /// directory when it loads, one file per tower on CPU (71 MB for the 270m,
  /// 385 MB for the 740m). A tower whose file the engine cannot create — a
  /// path too long for the platform (Windows' 260-character MAX_PATH), a
  /// directory this process cannot write to, or possibly no free space at
  /// all — runs anyway, slower to load and, measured on the 270m, with about
  /// 290 MB more memory. By default no cache at all is a printed warning.
  /// With `true` the load fails instead: `getActiveEmbedder()` throws an
  /// `EmbeddingLoadException` naming the cache directory, the length of the
  /// cache file path and the likely causes, and no engine is left running.
  /// A disk that fills while the cache is being built is not covered: the
  /// engine (XNNPack) then aborts the process in native code, and no flag can
  /// catch that.
  ///
  /// The refusal needs no real cache file at all; one tower's file missing
  /// beside the others is a printed warning either way. It applies on CPU,
  /// and on the NPU only to a load with declared audio, whose tower runs on
  /// CPU (the NPU's text and vision towers write no cache). It does not apply
  /// to `.tflite` embedders nor on the web, which keeps no weight cache; a
  /// debug build says once when it does not apply. It takes effect when an
  /// embedder is loaded: one already loaded is kept as it is (for example
  /// after `FlutterEdgeAi.reset()` and `initialize` with the other value).
  const LiteRtEmbeddingBackend({
    this._visionTokensPerImage = 140,
    this._requireWeightCache = false,
  });

  final int _visionTokensPerImage;
  final bool _requireWeightCache;

  @override
  String get name => 'LiteRT Embedding';

  @override
  int get priority => 0;

  /// A two-file spec (model + tokenizer), or a `.litertlm` bundle. A future
  /// self-contained spec of another kind (an ONNX directory) is not claimed.
  @override
  bool canHandle(EmbeddingModelSpec spec) =>
      spec.tokenizerSource != null ||
      isLiteRtLmFilename(spec.files.first.filename);

  /// GPU joins CPU and NPU for a `.litertlm` bundle on the hosts where
  /// EmbeddingGemma 2 is measured on the GPU ([liteRtLmEmbeddingGpuAbis]):
  /// core then keys the cache by the backend each load reports. A `.tflite`
  /// embedder and every other host keep the default, so a `gpu` request there
  /// still runs on CPU with core's not-applied notice.
  @override
  Set<PreferredBackend> honouredBackends(EmbeddingModelSpec spec) =>
      isLiteRtLmFilename(spec.files.first.filename) &&
          liteRtLmEmbeddingGpuHost()
      ? const {PreferredBackend.cpu, PreferredBackend.gpu, PreferredBackend.npu}
      : super.honouredBackends(spec);

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    final file = spec.files.first.filename;
    final opensBundle = isLiteRtLmFilename(config.modelPath);
    // Wherever it is used: a misconfigured backend fails at its first load,
    // not on the day the first image arrives.
    checkVisionTokensPerImage(
      _visionTokensPerImage,
      engine: opensBundle ? _liteRtLm : _liteRt,
    );
    if (opensBundle != spec.isSelfContained) {
      throw EmbeddingLoadException(
        'identity corrupt: the active embedder ${spec.name} opens '
        '${config.modelPath}, which ${opensBundle ? 'is' : 'is not'} a '
        '.litertlm bundle, while its spec '
        '${spec.isSelfContained ? 'carries no' : 'names a'} tokenizer. '
        'Install the embedder again.',
        engine: opensBundle ? _liteRtLm : _liteRt,
      );
    }
    if (opensBundle) {
      return _describeBundle(
        config,
        file,
        _visionTokensPerImage,
        requireWeightCache: _requireWeightCache,
      );
    }
    final descriptor = _describeTflite(spec, file, config);
    if (_requireWeightCache) {
      noticeRequireWeightCacheNotApplied(
        '$file is a .tflite embedder, which runs without a weight cache file',
      );
    }
    return descriptor;
  }
}

const _liteRt = 'LiteRT';
const _liteRtLm = liteRtLmEngineTag;

/// A `.litertlm` embedding bundle (EmbeddingGemma 2) never asks the tokenizer
/// registry: the bundle carries its own. Declared audio on a bundle without an
/// audio encoder (the 270m, the 440m) is refused here, from the container
/// header (a couple of KB): core calls describe() before it closes the
/// embedder it holds, so that embedder keeps working. Whether the bundle has a
/// vision tower for declared images is the pass's question, answered from
/// ModelInfo at load (the 270m has none). Where it runs — CPU, or the NPU it
/// was compiled for — is decided here too, from the bundle's own bytes
/// ([readLiteRtLmNpuTarget], [placeLiteRtLmEmbedder]). Both refusals come
/// before any isolate or engine exists.
Future<EmbeddingPassDescriptor<LiteRtLmEmbeddingConfig>> _describeBundle(
  RuntimeConfig config,
  String file,
  int visionTokensPerImage, {
  required bool requireWeightCache,
}) async {
  if (config.supportAudio) requireLiteRtLmAudioEncoder(config.modelPath);
  final LiteRtLmNpuTarget? target;
  try {
    target = await readLiteRtLmNpuTarget(config.modelPath);
  } on FileSystemException catch (e) {
    throw EmbeddingLoadException(
      'could not read $file to tell whether it is compiled for an NPU: '
      '${e.osError?.message ?? e.message}',
      engine: _liteRtLm,
      cause: e,
    );
  } on FormatException catch (e) {
    throw EmbeddingLoadException(
      '$file is not a readable .litertlm bundle: ${e.message}',
      engine: _liteRtLm,
      cause: e,
    );
  }
  final placement = await placeLiteRtLmEmbedder(
    file: file,
    target: target,
    requested: config.preferredBackend,
  );
  final onGpu = placement.backend == PreferredBackend.gpu;
  // On the GPU only the text tower runs there: the pass names every tower the
  // container has cpu, and must not name one it lacks (create fails).
  final towers = onGpu
      ? readLiteRtLmMediaTowers(config.modelPath)
      : (vision: false, audio: false);
  if (onGpu && config.supportImage && !towers.vision) {
    // The 270m. The pass would refuse it from ModelInfo after core closed the
    // embedder it holds; the header is already read here, so refuse before,
    // in the pass's words.
    throw EmbeddingLoadException(
      '$file has no vision encoder; install embeddinggemma-2-text-vision-440m',
      engine: _liteRtLm,
    );
  }
  if (requireWeightCache && placement.target != null && !config.supportAudio) {
    noticeRequireWeightCacheNotApplied(
      '$file runs on the ${placement.target} NPU, whose text and vision '
      'towers write no weight cache, and no audio was declared',
    );
  }
  if (requireWeightCache && onGpu) {
    noticeRequireWeightCacheNotApplied(
      '$file runs its text tower on the GPU, which writes its own weight and '
      'program caches (ML Drift), not the XNNPack weight cache the flag '
      'checks; a GPU load is not checked',
    );
  }
  // The platform CACHE directory, not application support: iOS backs that up
  // to iCloud and Android Auto Backup includes it under a 25 MB per-app quota,
  // which a 71-385 MB weight cache would break. If the OS purges the cache,
  // the next engine create rebuilds it. Resolved here: the pass runs in core's
  // worker isolate, which has no platform channels.
  final cache = (await getApplicationCacheDirectory()).path;
  final sep = Platform.pathSeparator;
  return EmbeddingPassDescriptor<LiteRtLmEmbeddingConfig>(
    engineTag: _liteRtLm,
    factory: buildLiteRtLmEmbeddingPass,
    config: LiteRtLmEmbeddingConfig(
      modelPath: config.modelPath,
      // Short on purpose: the engine's cache file name repeats the model's
      // name below it, and Windows paths must stay under MAX_PATH.
      cacheBase: '$cache${sep}flutter_edge_ai${sep}emb',
      declaredMedia: {
        if (config.supportImage) EmbeddingModality.image,
        if (config.supportAudio) EmbeddingModality.audio,
      },
      visionTokensPerImage: visionTokensPerImage,
      // The pass checks the cache on CPU, and on the NPU for declared audio
      // only (see LiteRtLmEmbeddingConfig).
      requireWeightCache: requireWeightCache,
      npuTarget: placement.target,
      npuDispatchDir: placement.dispatchDir,
      gpu: onGpu,
      visionTowerOnCpu: towers.vision,
      audioTowerOnCpu: towers.audio,
    ),
    // `settings_create(path, "cpu" | "gpu" | "npu", vision, audio)`: the text
    // tower on that backend. The vision and audio towers run with it (NULL,
    // D26), except on the GPU, where each present one is named cpu, and the
    // 740m's audio on the NPU (cpu). The pass refuses to load rather than
    // fall back, so this is what runs; the core API reports the text tower's.
    activeBackend: placement.backend,
  );
}

EmbeddingPassDescriptor<LiteRtEmbeddingConfig> _describeTflite(
  EmbeddingModelSpec spec,
  String file,
  RuntimeConfig config,
) {
  if (config.supportImage || config.supportAudio) {
    throw EmbeddingLoadException('$file is a text-only model', engine: _liteRt);
  }
  final tokenizerPath =
      config.tokenizerPath ??
      (throw EmbeddingLoadException(
        'identity corrupt: the active embedder ${spec.name} names a tokenizer, '
        'but core resolved no tokenizer path for it. Install the embedder '
        'again.',
        engine: _liteRt,
      ));
  return EmbeddingPassDescriptor<LiteRtEmbeddingConfig>(
    engineTag: _liteRt,
    factory: buildLiteRtEmbeddingPass,
    config: LiteRtEmbeddingConfig(
      modelPath: config.modelPath,
      tokenizerPath: tokenizerPath,
      // Asked for, not named. Which family this model needs is a fact about
      // the model, not about LiteRT — and hardcoding Gemma SentencePiece here
      // is what made a catch-all `canHandle` a trap: a WordPiece model was
      // accepted and then tokenized with the wrong convention.
      tokenizerFactory: EmbeddingTokenizerRegistry.instance.resolveFor(spec),
    ),
    // CPU, and by decision rather than omission: the GPU delegate compiles
    // and then returns all-zero vectors for EmbeddingGemma's int4 weights
    // (removed in ab3df2bf). Surfaced as EmbeddingModel.activeBackend so a
    // caller who asked for GPU can see what happened in a release build.
    activeBackend: PreferredBackend.cpu,
  );
}
