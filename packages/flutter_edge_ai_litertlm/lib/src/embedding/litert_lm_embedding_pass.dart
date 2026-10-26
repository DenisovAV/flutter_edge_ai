// The EmbeddingGemma 2 `.litertlm` embedding pass over LiteRT-LM's
// EmbeddingEngine C API — what `LiteRtEmbeddingBackend.describe` hands core for
// a self-contained `.litertlm` embedder spec. Core builds it inside its
// embedding worker isolate, hosts it and closes it (R5 §4).
//
// The bundle carries its own tokenizer, so nothing here touches core's
// tokenizer registry: the pass hands the engine `taskType.prefix + text` and
// the engine tokenizes it, adding BOS and EOS (special tokens pinned on, D26).
//
// What it decides, and why (R5 D21-D26, §4.8, §4.10, measured in
// eg2_design_backup/measurements/REPORT.md):
// - Capabilities come from the bundle, read BEFORE any settings or engine
//   exist: model type, dimension, text signatures and image support from
//   ModelInfo (`vision_signature_selection`), audio support from the
//   container's section table (`litertlm_container.dart`) — never
//   `supports_input_modality`, which claims vision and audio on the text-only
//   270m and audio on the 440m (D23). A declared medium the bundle lacks is
//   refused here, so no engine (and no tower cache) is made for a request
//   that cannot be served. Text; images on a bundle with a vision encoder (the
//   440m and the 740m); audio on a bundle with an audio encoder (the 740m).
// - Media are encoded files, decoded by the engine and reported at load, so
//   core refuses any other container before sending: images through stb
//   (JPEG, PNG, GIF, BMP) at 140 vision tokens per image or the opt-in 70
//   (D25); audio through miniaudio (WAV, MP3, FLAC; mixed down to mono and
//   resampled to 16 kHz by the engine, about 25 tokens per second). Tower
//   backends stay NULL: present towers run on the main backend (D26).
// - One vector may combine parts (`combinedInputs`): the text with its task
//   prefix, then the images in order, then the audio (`embedding_parts.dart`).
// - The input cap is set explicitly to 1024 tokens (D21): the bundles' metadata
//   says 1024 but no C getter exposes it, and one 8192-token input peaked at
//   +10.25 GB. `maxInputTokens` is the smallest text signature at or above the
//   setting — the limit the engine enforces.
// - The engine always gets an existing, writable cache directory that this
//   pass owns (D22), under the platform cache directory (never backed up):
//   without one it runs with no weight cache (measured on the 270m: +290 MB)
//   or writes `.xnnpack_cache` files next to the model. Our part of the path
//   is kept short — `flutter_edge_ai/emb/<8-hex hash>-<base36 size>-<base36
//   mtime>` (see `liteRtLmCacheDirName`: Windows MAX_PATH). XNNPack opens
//   each tower's cache file at create and writes its header at once: a file
//   it cannot create (MAX_PATH, a directory this process cannot write to,
//   possibly no free space at all) leaves that tower uncached, while a disk
//   that fills as the cache is built aborts the process inside XNNPack
//   (`weight_cache.cc`, `XNNPACK_ABORT_CHECK`), which nothing here can catch.
//   After create the pass looks for the caches (`_checkWeightCache`): on CPU,
//   and on the NPU only for declared audio, whose tower runs on CPU (the NPU
//   text and vision towers write none). No real cache file at all is a
//   printed warning, or with `requireWeightCache` an `EmbeddingLoadException`
//   (the engine deleted); one expected tower's file missing is a printed
//   warning either way. On the GPU the text tower's caches are ML Drift's
//   `<model>.text_encoder_<mtime>_<size>_mldrift_{weight,program}_cache.bin`,
//   which Windows opens with the ANSI `CreateFileA` and no long-path
//   support: their paths are checked before create (`_checkGpuCachePaths`:
//   MAX_PATH, a name past 255 — UTF-8 bytes off Windows — and on Windows a
//   character outside ASCII unless the ANSI code page is UTF-8), the files
//   after the probe embedding (`_checkGpuCache`, which does not warn again
//   for a path already warned about), with the same warning / refusal split.
//   The 440m/740m vision and audio towers beside the GPU text tower run on
//   CPU and are checked as on CPU. A cache directory that cannot be listed
//   is a warning, or a refusal under the flag. Caches of earlier copies of
//   the same file name are deleted only once the engine exists — after a
//   successful load, or right before the no-cache refusal, since an older
//   copy's cache may be what left no free space — and not while they were
//   touched in the last 10 minutes.
// - Overflow (§4.8, the P3 gate): options use kTruncate for every request,
//   and the response reports how many tokens the input had and how many the
//   engine kept (`litert_lm_embedding_response_get_input_length` /
//   `…_get_truncated_length`, patch_c_api.sh section 14, native-v0.18.0-e). A
//   truncated response is never returned: it becomes
//   `EmbeddingInputTooLongException` with both counts exact, media tokens
//   included. A NULL response is never an overflow any more, so its status is
//   an engine error — on an image, status 3 is a decode failure (stb), and on
//   audio, status 2 is miniaudio refusing the file.
// - Ownership (§4.10): every create has its delete on every path, and the
//   native error (thread-local) is copied in the same synchronous segment as
//   the failing call, before any other native call.
// - NPU (an EmbeddingGemma 2 per-SoC bundle, placed by `describe()`, see
//   litert_lm_npu.dart): the main backend is "npu", the tower backends stay
//   NULL so present towers run on it too (D26), and the vendor's dispatch
//   directory (Qualcomm's prepared libraries, or on Windows the executable's
//   directory with the Intel stack) is handed to every executor (main,
//   vision, audio; upstream ignores a tower the bundle lacks).
//   `engine_create` succeeds even when the
//   NPU graph cannot run (measured: it only logs a failed warm-up), so the load
//   embeds one probe text and refuses unless it gets a finite, non-zero
//   vector of the right size. On Linux every NPU call runs with SIGPROF
//   blocked: the debug VM profiler's signal breaks QNN (see sigprof_mask.dart),
//   and this pass calls the engine on its own thread, synchronously.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha256;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

import '../bundle/litertlm_bundle_info.dart' show npuVendorOf;
import '../ffi/intel_weight_banks.dart';
import '../ffi/litert_lm_embedding_bindings.dart';
import '../ffi/litert_lm_library.dart';
import '../ffi/npu_vendor_host.dart' show npuStagesWeightBanks;
import '../ffi/sigprof_mask.dart';
import '../npu_stacks.dart' show NpuVendor;
import 'embedding_parts.dart';
import 'litert_lm_embedding_common.dart';
import 'litertlm_container_io.dart';
import 'litertlm_npu_target.dart';
import 'vision_budget.dart';

// Shared with the web pass; re-exported so this file's users keep one import.
export 'litert_lm_embedding_common.dart'
    show
        liteRtLmAudioFormats,
        liteRtLmEngineTag,
        liteRtLmImageFormats,
        liteRtLmMaxInputLength;

/// `kLiteRtLmStatusOk` / `kLiteRtLmStatusUnknown` /
/// `kLiteRtLmStatusInvalidArgument` (`c/error_reporter.h`).
const _statusOk = 0;
const _statusUnknown = 2;
const _statusInvalidArgument = 3;

/// Throws [EmbeddingLoadException] unless the `.litertlm` bundle at
/// [modelPath] has an audio encoder, read from its container header (D23:
/// ModelInfo claims audio on the 270m and the 440m). A header this reader
/// cannot parse is a load failure, never "no audio".
///
/// `LiteRtEmbeddingBackend.describe()` calls it for declared audio, and the
/// pass's `load()` again as a backstop. In describe() is where it matters:
/// core calls describe() before it closes the embedder it holds, so a refusal
/// there leaves that embedder working, while one from `load()` comes after
/// the close.
void requireLiteRtLmAudioEncoder(String modelPath) {
  final file = _fileName(modelPath);
  Never cannotRead(Object e, String reason) =>
      throw liteRtLmUnreadableContainer(file, reason, e);
  final List<String> types;
  try {
    types = readLitertlmModelTypes(modelPath);
  } on FileSystemException catch (e) {
    cannotRead(e, e.osError?.message ?? e.message);
  } on FormatException catch (e) {
    cannotRead(e, e.message);
  }
  if (!litertlmHasAudioEncoder(types)) throw liteRtLmNoAudioEncoder(file);
}

/// The vision and audio towers the `.litertlm` bundle at [modelPath] carries,
/// read from its container header. Called by `LiteRtEmbeddingBackend.describe()`
/// for a GPU load: LiteRT-LM compiles every present tower at create, declared
/// or not, on the main backend unless the tower's own is named, so the pass
/// names each present tower `cpu` and keeps only the text tower on the GPU.
/// A tower the bundle lacks is never named (measured: create fails with code
/// 5; not found in upstream's source). A
/// header this reader cannot parse is a load failure.
({bool vision, bool audio}) readLiteRtLmMediaTowers(String modelPath) {
  final file = _fileName(modelPath);
  Never cannotRead(Object e, String reason) =>
      throw liteRtLmUnreadableContainer(
        file,
        reason,
        e,
        looking: 'its vision and audio towers',
      );
  final List<String> types;
  try {
    types = readLitertlmModelTypes(modelPath);
  } on FileSystemException catch (e) {
    cannotRead(e, e.osError?.message ?? e.message);
  } on FormatException catch (e) {
    cannotRead(e, e.message);
  }
  return (
    vision: litertlmHasVisionTower(types),
    audio: litertlmHasAudioTower(types),
  );
}

/// What `LiteRtEmbeddingBackend.describe` hands core for a `.litertlm`
/// embedder. Crosses to core's worker isolate: strings, a set of enums and an
/// int, all sendable.
final class LiteRtLmEmbeddingConfig {
  const LiteRtLmEmbeddingConfig({
    required this.modelPath,
    required this.cacheBase,
    this.declaredMedia = const {},
    this.numThreads,
    this.visionTokensPerImage = liteRtLmDefaultVisionTokensPerImage,
    this.requireWeightCache = false,
    this.npuTarget,
    this.npuDispatchDir,
    this.gpu = false,
    this.visionTowerOnCpu = false,
    this.audioTowerOnCpu = false,
  }) : assert(
         (npuTarget == null) == (npuDispatchDir == null),
         'an NPU bundle runs with a dispatch directory, a CPU one without',
       ),
       assert(
         gpu || !(visionTowerOnCpu || audioTowerOnCpu),
         'a tower is named cpu only beside a text tower on the GPU',
       );

  /// The `.litertlm` bundle core resolved for the active spec.
  final String modelPath;

  /// `<applicationCache>/flutter_edge_ai/emb` (path_provider's
  /// `getApplicationCacheDirectory()`), resolved in `describe()` — the worker
  /// isolate has no platform channels. The pass keeps one directory per bundle
  /// copy under it. A cache directory, so it is never backed up (iOS iCloud,
  /// Android Auto Backup's 25 MB quota); when the OS purges it, the next engine
  /// create rebuilds the weight cache.
  final String cacheBase;

  /// The media the caller declared. The pass refuses, from the bundle and
  /// before creating an engine, images on a bundle without a vision encoder
  /// and audio on a bundle without an audio encoder.
  final Set<EmbeddingModality> declaredMedia;

  /// Engine threads; null leaves the engine's default (about 4).
  final int? numThreads;

  /// Vision tokens per image (D25): 140 or 70, checked by `describe()`.
  final int visionTokensPerImage;

  /// Whether a load that leaves [cacheBase]'s directory for this bundle
  /// without a real weight cache file is refused with [EmbeddingLoadException]
  /// instead of printing a warning (`LiteRtEmbeddingBackend(requireWeightCache:)`).
  /// Checked on CPU, on the GPU (ML Drift's weight and program caches, whose
  /// path lengths are also checked before create), and on the NPU only when
  /// audio is declared: there the text and vision towers write no cache,
  /// while the audio tower, pinned to CPU, writes one.
  final bool requireWeightCache;

  /// The SoC a per-SoC bundle is compiled for, when `describe()` placed it on
  /// the NPU; null runs the bundle on CPU.
  final LiteRtLmNpuTarget? npuTarget;

  /// Where LiteRT loads the vendor's dispatch from — the Qualcomm dispatch and
  /// QNN libraries, or on Windows the Intel stack beside the executable —
  /// resolved by `describe()` on the caller's isolate (Android extracts the
  /// Qualcomm libraries through a platform channel, which this worker has
  /// none of). Set with [npuTarget].
  final String? npuDispatchDir;

  /// A generic bundle's text tower on the GPU (LiteRT-LM's GPU executor, which
  /// LiteRT runs on the GPU alone, never falling back to CPU), asked for with
  /// `preferredBackend: gpu` on a `liteRtLmEmbeddingGpuAbis` host. Its vision
  /// and audio towers run on CPU ([visionTowerOnCpu], [audioTowerOnCpu]).
  /// Never set with [npuTarget].
  final bool gpu;

  /// With [gpu]: the bundle carries a vision tower (the 440m, the 740m), and
  /// the pass names its backend `cpu`, declared images or not — LiteRT-LM
  /// compiles a present tower at create, on the main backend when its own is
  /// NULL. Set from the container header by `describe()`
  /// ([readLiteRtLmMediaTowers]), because naming a tower the bundle lacks
  /// fails create.
  final bool visionTowerOnCpu;

  /// With [gpu]: the bundle carries an audio tower (the 740m), named `cpu`
  /// like [visionTowerOnCpu].
  final bool audioTowerOnCpu;

  /// The backend the engine is created on.
  PreferredBackend get backend => npuTarget != null
      ? PreferredBackend.npu
      : gpu
      ? PreferredBackend.gpu
      : PreferredBackend.cpu;
}

/// The descriptor factory: a top-level tear-off, so it survives the trip into
/// core's worker isolate.
EmbeddingPass buildLiteRtLmEmbeddingPass(LiteRtLmEmbeddingConfig config) =>
    LiteRtLmEmbeddingPass(config);

/// Why a bundle compiled for [target] fails the NPU probe embed, for the
/// refusal: another SoC's bundle, or a stack that cannot reach this device's
/// NPU — a QNN runtime without this Hexagon version's Skel, or on Windows a PC
/// without an Intel NPU or its driver.
@visibleForTesting
String liteRtLmNpuProbeFailureCauses(LiteRtLmNpuTarget target) =>
    switch (npuVendorOf(target)) {
      NpuVendor.intel =>
        'on another SoC, or on a PC without an Intel NPU or its driver',
      NpuVendor.qualcomm =>
        'on another SoC, or with a QNN runtime that has no Skel for this '
            "device's Hexagon version",
      NpuVendor.googleTensor =>
        'on another Tensor generation (G5 and G6 bundles are not '
            'interchangeable), or without a compatible Pixel system runtime',
      NpuVendor.mediatek =>
        'on another SoC, or with a NeuroPilot runtime on this device that '
            "does not match the bundle's NeuroPilot SDK version",
      // The placement refuses a bundle of a vendor with no dispatch here
      // before any probe embed.
      null => throw StateError('$target: no NPU vendor of this package'),
    };

/// Every C function the pass calls. A `libLiteRtLm` that exports fewer is
/// refused at load by [checkLiteRtLmEmbeddingSymbols], by name, instead of
/// failing on the first lookup somewhere inside the worker.
const liteRtLmEmbeddingSymbols = <String>[
  'litert_lm_clear_last_error',
  'litert_lm_get_last_error_code',
  'litert_lm_get_last_error_message',
  'litert_lm_loaded_file_create',
  'litert_lm_loaded_file_delete',
  'litert_lm_loaded_file_model_type',
  'litert_lm_loaded_file_embedding_dimension',
  'litert_lm_loaded_file_embedding_signature_selection',
  'litert_lm_loaded_file_vision_signature_selection',
  'litert_lm_embedding_engine_settings_create',
  'litert_lm_embedding_engine_settings_delete',
  'litert_lm_embedding_engine_settings_set_cache_dir',
  'litert_lm_embedding_engine_settings_set_max_input_length',
  'litert_lm_embedding_engine_settings_set_num_threads',
  'litert_lm_embedding_engine_settings_set_vision_tokens_per_image',
  'litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir',
  'litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir',
  'litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir',
  'litert_lm_embedding_engine_create',
  'litert_lm_embedding_engine_delete',
  'litert_lm_embedding_engine_compute_embedding',
  'litert_lm_embedding_options_create',
  'litert_lm_embedding_options_delete',
  'litert_lm_embedding_options_set_normalize',
  'litert_lm_embedding_options_set_insert_special_tokens',
  'litert_lm_embedding_options_set_input_overflow_strategy',
  'litert_lm_input_data_create',
  'litert_lm_input_data_delete',
  'litert_lm_embedding_response_get_size',
  'litert_lm_embedding_response_get_values',
  'litert_lm_embedding_response_get_input_length',
  'litert_lm_embedding_response_get_truncated_length',
  'litert_lm_embedding_response_delete',
];

/// Throws [EmbeddingLoadException] naming every symbol of
/// [liteRtLmEmbeddingSymbols] that [provides] reports missing from [library].
void checkLiteRtLmEmbeddingSymbols(
  bool Function(String symbol) provides, {
  required String library,
}) {
  final missing = [
    for (final symbol in liteRtLmEmbeddingSymbols)
      if (!provides(symbol)) symbol,
  ];
  if (missing.isEmpty) return;
  throw EmbeddingLoadException(
    '$library does not export the LiteRT-LM EmbeddingEngine C API '
    '(missing: ${missing.join(', ')}). EmbeddingGemma 2 needs the native '
    'libraries of native-v0.18.0-e or newer; a stale local prebuilt under '
    'native/litert_lm/prebuilt/ is the usual cause.',
    engine: liteRtLmEngineTag,
  );
}

/// Binds [library] after checking it exports everything the pass calls.
LiteRtLmEmbeddingBindings bindLiteRtLmEmbeddings(
  DynamicLibrary library, {
  String label = 'libLiteRtLm',
}) {
  checkLiteRtLmEmbeddingSymbols(library.providesSymbol, library: label);
  return LiteRtLmEmbeddingBindings(library);
}

LiteRtLmEmbeddingBindings _openBindings() =>
    bindLiteRtLmEmbeddings(openLiteRtLmLibrary());

/// The `.litertlm` embedding pass: text, images on a bundle with a vision
/// encoder, audio on a bundle with an audio encoder, and any combination of
/// them in one vector; CPU, or the NPU for a per-SoC bundle.
///
/// Built and run inside one isolate: the native handles it holds cannot cross
/// an isolate boundary — only its [LiteRtLmEmbeddingConfig] does.
final class LiteRtLmEmbeddingPass extends EmbeddingPass {
  LiteRtLmEmbeddingPass(
    this._config, {
    @visibleForTesting LiteRtLmEmbeddingBindings Function()? openBindings,
    @visibleForTesting Allocator allocator = calloc,
    @visibleForTesting DateTime Function()? clock,
  }) : _open = openBindings ?? _openBindings,
       _alloc = allocator,
       _now = clock ?? DateTime.now;

  final LiteRtLmEmbeddingConfig _config;
  final LiteRtLmEmbeddingBindings Function() _open;

  /// Every pointer the pass allocates, and frees.
  final Allocator _alloc;

  /// What "now" is when judging whether a sibling cache is still in use.
  final DateTime Function() _now;

  LiteRtLmEmbeddingBindings? _bindings;
  Pointer<LiteRtLmEmbeddingEngine> _engine = nullptr;
  Pointer<LiteRtLmEmbeddingOptions> _options = nullptr;

  /// The Intel NPU weight banks this engine's create wrote, held until the
  /// engine is deleted (intel_weight_banks.dart).
  IntelWeightBankClaim? _banks;
  int _dimension = 0;
  int _maxInputTokens = 0;
  bool _images = false;
  bool _audio = false;
  String? _cacheDir;
  bool _loaded = false;
  bool _closed = false;

  String get _file => _fileName(_config.modelPath);

  /// The engine-owned cache directory [load] created; null before.
  @visibleForTesting
  String? get cacheDir => _cacheDir;

  @override
  Future<EmbeddingPassInfo> load() async {
    if (_loaded || _closed) {
      throw StateError('LiteRtLmEmbeddingPass.load() runs once, before close');
    }
    final LiteRtLmEmbeddingBindings b;
    try {
      b = _open();
    } on EmbeddingLoadException {
      rethrow;
    } catch (e) {
      throw EmbeddingLoadException(
        'could not open the LiteRT-LM native library: $e',
        engine: liteRtLmEngineTag,
        cause: e,
      );
    }
    _bindings = b;

    final info = _readModelInfo(b);
    final textSignatures = _checkModelInfo(info);
    final (:setting, :maxInputTokens) = liteRtLmInputLimit(textSignatures);
    final images = _config.declaredMedia.contains(EmbeddingModality.image);
    // Checked by _checkModelInfo against the container: the bundle has an
    // audio encoder whenever audio was declared.
    final audio = _config.declaredMedia.contains(EmbeddingModality.audio);
    final (:cacheDir, :modelSize) = _createCacheDir();

    try {
      // Before create: a GPU cache path the accelerator cannot open costs a
      // cold GPU load at every start and is reported only on stderr. Warned
      // about here, it is not warned about again after the probe.
      final gpuPathWarned =
          _config.gpu && _checkGpuCachePaths(cacheDir, modelSize);
      _engine = _createEngine(
        b,
        maxInputLength: setting,
        cacheDir: cacheDir,
        // Only when images will be embedded: the budget means nothing to a
        // text request, and the bundle's own default is 140 anyway.
        visionTokensPerImage: images ? _config.visionTokensPerImage : null,
        audio: audio,
      );
      _options = _createOptions(b);
      if (_config.gpu) _logCacheListing(cacheDir, 'after engine create');
      // An accelerator gets one real embedding before it is trusted: create
      // compiles but never runs the graph.
      if (_onNpu || _config.gpu) {
        _probeAccelerator(b, info.dimension, _config.npuTarget);
      }
      if (_config.gpu) {
        _logCacheListing(cacheDir, 'after the probe embedding');
        _checkGpuCache(
          cacheDir,
          modelSize: modelSize,
          pathWarned: gpuPathWarned,
        );
      }
      // Every tower on CPU writes a weight cache. On the NPU the text and
      // vision towers write none (upstream gives an NPU graph no XNNPack
      // cache), but declared audio runs on CPU (see _createEngine) and writes
      // one. The GPU's text tower writes ML Drift's caches instead, checked
      // above, and the 440m/740m vision and audio towers beside it run on CPU
      // (named so at create, declared or not) and write XNNPack's.
      // Inside the try: a refusal deletes the engine and the options it made.
      final onCpu = _config.backend == PreferredBackend.cpu;
      final vision = onCpu ? _hasVision(info) : _config.visionTowerOnCpu;
      final audioOnCpu = audio || _config.audioTowerOnCpu;
      if (onCpu ||
          (_onNpu && audio) ||
          (_config.gpu && (vision || audioOnCpu))) {
        _checkWeightCache(
          cacheDir,
          modelSize: modelSize,
          text: onCpu,
          vision: vision,
          audio: audioOnCpu,
        );
      }
    } catch (_) {
      _free();
      rethrow;
    }
    // Only now: a load that failed must not have cost another copy its cache
    // (the no-cache refusal, which collects them first, is the exception).
    _deleteStaleSiblings(cacheDir);

    _dimension = info.dimension;
    _maxInputTokens = maxInputTokens;
    _images = images;
    _audio = audio;
    _cacheDir = cacheDir;
    _loaded = true;
    // D23: what the BUNDLE can do — images whenever it has a vision encoder;
    // audio is known only when it was declared (the container is read for it
    // then and only then). Core keeps the model at what was declared.
    final vision = _hasVision(info);
    edgeAiLog(
      '[LiteRtLmEmbeddingPass] loaded $_file: dim=${info.dimension}, '
      'maxInputTokens=$maxInputTokens, '
      'backend=${_onNpu ? 'npu (${_config.npuTarget}, dispatch '
                '${_config.npuDispatchDir})' : _config.backend.name}'
      '${_config.visionTowerOnCpu || _config.audioTowerOnCpu ? ' (${[if (_config.visionTowerOnCpu) 'vision', if (_config.audioTowerOnCpu) 'audio'].join(' and ')} on cpu)' : ''}, '
      'vision=${vision ? info.visionSignatures : 'none'}'
      '${images ? ', ${_config.visionTokensPerImage} tokens/image' : ''}, '
      'audio=${audio ? 'yes' : 'not declared'}, '
      'cache=$cacheDir',
    );
    return EmbeddingPassInfo(
      dimension: info.dimension,
      maxInputTokens: maxInputTokens,
      modalities: {
        EmbeddingModality.text,
        if (vision) EmbeddingModality.image,
        if (audio) EmbeddingModality.audio,
      },
      imageFormats: vision ? liteRtLmImageFormats : const {},
      audioFormats: audio ? liteRtLmAudioFormats : const {},
      combinedInputs: true,
      // The budget the engine was created with: only when images were
      // declared (it is not set otherwise, see _createEngine).
      visionTokensPerImage: images ? _config.visionTokensPerImage : null,
      // Required by core on the hosts where this backend honours the GPU,
      // and true everywhere: the engine runs where it was created or fails.
      activeBackend: _config.backend,
    );
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final b = _bindings;
    if (!_loaded || _closed || b == null) {
      throw const EmbeddingEngineException(
        'LiteRtLmEmbeddingPass.embed() needs a loaded, open pass',
        engine: liteRtLmEngineTag,
      );
    }
    final parts = embeddingParts(input, taskType);
    final kinds = {for (final part in parts) part.kind};
    if (parts.isEmpty ||
        (kinds.contains(EmbeddingPartKind.image) && !_images) ||
        (kinds.contains(EmbeddingPartKind.audio) && !_audio)) {
      // Core refuses all of these before sending (only the modalities the
      // model was loaded with, and never an input without a part); reaching
      // here is a host bug.
      throw EmbeddingEngineException(
        'flutter_edge_ai_litertlm embeds text and the media this model was '
        'loaded with, got $input',
        engine: liteRtLmEngineTag,
      );
    }
    final images = kinds.contains(EmbeddingPartKind.image);
    final audio = kinds.contains(EmbeddingPartKind.audio);

    // Everything below is synchronous: the native error state is
    // thread-local, and an `await` could resume this isolate on another
    // thread before it is read.
    final handles = <Pointer<LiteRtLmInputData>>[];
    try {
      for (final part in parts) {
        handles.add(_createPart(b, part));
      }
      final partArray = _alloc<Pointer<LiteRtLmInputData>>(handles.length);
      try {
        for (var i = 0; i < handles.length; i++) {
          partArray[i] = handles[i];
        }
        final (:response, :code, :message) = _compute(
          b,
          partArray,
          handles.length,
        );
        if (response == nullptr) {
          // kTruncate: an overflow returns a (truncated) response, never NULL.
          throw EmbeddingEngineException(
            code == _statusInvalidArgument && images
                // stb refusing the bytes (measured: a truncated PNG,
                // "outofdata").
                ? 'LiteRT-LM could not decode an image for $_file (a corrupt '
                      'or truncated file?): $message'
                : code == _statusUnknown && audio
                // miniaudio refusing the bytes (measured: a WAV header with
                // no samples, a RIFF header over garbage).
                ? 'LiteRT-LM could not decode the audio for $_file (a corrupt '
                      'file?): $message'
                : 'compute_embedding failed for $_file: $message',
            engine: liteRtLmEngineTag,
            nativeCode: code == _statusOk ? null : code,
          );
        }
        try {
          return _vectorOf(b, response);
        } finally {
          b.litert_lm_embedding_response_delete(response);
        }
      } finally {
        _alloc.free(partArray);
      }
    } finally {
      for (final handle in handles) {
        b.litert_lm_input_data_delete(handle);
      }
    }
  }

  /// One `LiteRtLmInputData` holding [part]'s bytes (the engine copies them).
  Pointer<LiteRtLmInputData> _createPart(
    LiteRtLmEmbeddingBindings b,
    EmbeddingPart part,
  ) {
    final bytes = part.bytes;
    final buffer = _alloc<Uint8>(math.max(bytes.length, 1));
    final Pointer<LiteRtLmInputData> handle;
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      // Copies the bytes (std::string). Returns NULL only for an unknown
      // type, and then sets no error — so none is read.
      handle = b.litert_lm_input_data_create(
        switch (part.kind) {
          EmbeddingPartKind.text =>
            LiteRtLmInputDataType.kLiteRtLmInputDataTypeText,
          EmbeddingPartKind.image =>
            LiteRtLmInputDataType.kLiteRtLmInputDataTypeImage,
          EmbeddingPartKind.audio =>
            LiteRtLmInputDataType.kLiteRtLmInputDataTypeAudio,
        },
        buffer.cast(),
        bytes.length,
      );
    } finally {
      _alloc.free(buffer);
    }
    if (handle == nullptr) {
      throw EmbeddingEngineException(
        'litert_lm_input_data_create returned NULL for a ${part.kind.name} '
        'part',
        engine: liteRtLmEngineTag,
      );
    }
    return handle;
  }

  /// The vector in [response], or the overflow it reports.
  List<double> _vectorOf(
    LiteRtLmEmbeddingBindings b,
    Pointer<LiteRtLmEmbeddingResponse> response,
  ) {
    final inputLength = b.litert_lm_embedding_response_get_input_length(
      response,
    );
    final truncatedLength = b.litert_lm_embedding_response_get_truncated_length(
      response,
    );
    if (inputLength < 0 || truncatedLength < 0) {
      // -1 is the getters' answer to a NULL response, which this is not.
      throw EmbeddingEngineException(
        '$_file returned a response without token counts (input length '
        '$inputLength, truncated length $truncatedLength)',
        engine: liteRtLmEngineTag,
      );
    }
    // A count past the limit with nothing reported truncated would be a
    // runtime that fills the getters differently (a later pin): refused too,
    // against the limit read at load, never returned as a vector.
    if (truncatedLength > 0 || inputLength > _maxInputTokens) {
      // §4.8, the P3 gate: the engine kept the first truncatedLength tokens.
      // A vector of part of the input is not what was asked for.
      final limit = truncatedLength > 0 ? truncatedLength : _maxInputTokens;
      throw EmbeddingInputTooLongException(
        'The input is $inputLength tokens long; $_file accepts at most '
        '$limit (task prefix, BOS and EOS included, and media too: about 140 '
        'tokens per image and 25 per second of audio). Nothing was embedded; '
        'split the input and embed the pieces.',
        maxInputTokens: limit,
        actualTokens: inputLength,
      );
    }
    final size = b.litert_lm_embedding_response_get_size(response);
    final values = b.litert_lm_embedding_response_get_values(response);
    if (size != _dimension || values == nullptr) {
      throw EmbeddingEngineException(
        '$_file returned a vector of $size values for dimension $_dimension',
        engine: liteRtLmEngineTag,
      );
    }
    // The values belong to the response: copy before deleting it.
    return List<double>.generate(size, (i) => values[i]);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _free();
  }

  /// Deletes the options and the engine, whichever exist. Idempotent.
  void _free() {
    final b = _bindings;
    if (b == null) return;
    final options = _options;
    final engine = _engine;
    _options = nullptr;
    _engine = nullptr;
    if (options != nullptr) b.litert_lm_embedding_options_delete(options);
    if (engine != nullptr) {
      _npuCall(() => b.litert_lm_embedding_engine_delete(engine));
    }
    // After the delete, which removes the banks the dispatch wrote.
    _banks?.release();
    _banks = null;
  }

  bool get _onNpu => _config.npuTarget != null;

  /// Runs [body] as an NPU call must run on Linux: with SIGPROF blocked on
  /// this thread. A debug or profile VM samples every isolate thread with it,
  /// and Qualcomm's QNN backend does not survive that on Linux (measured on a
  /// QCS8275: engine create fails under the profiler, and works with the
  /// signal blocked). The LLM client blocks it around its engine create; this
  /// pass runs the engine synchronously on its worker's thread, so create,
  /// compute and delete all get it. Android's FastRPC survives the signal.
  T _npuCall<T>(T Function() body) =>
      _onNpu && Platform.isLinux ? withSigprofBlocked(body) : body();

  /// One `compute_embedding` of the [count] [parts], with the error copied in
  /// the same synchronous segment (and the same SIGPROF mask) as the call.
  ({Pointer<LiteRtLmEmbeddingResponse> response, int code, String message})
  _compute(
    LiteRtLmEmbeddingBindings b,
    Pointer<Pointer<LiteRtLmInputData>> parts,
    int count,
  ) => _npuCall(() {
    // The error state is per thread and survives successful calls: clear it,
    // so a NULL with nothing reported is never read as an old status.
    b.litert_lm_clear_last_error();
    final response = b.litert_lm_embedding_engine_compute_embedding(
      _engine,
      parts,
      count,
      _options,
    );
    if (response != nullptr) return (response: response, code: 0, message: '');
    final (:code, :message) = _lastError(b);
    return (response: response, code: code, message: message);
  });

  /// The text the NPU load check embeds.
  static const _probeText = 'task: search result | query: probe';

  /// Embeds [_probeText] on a just-created NPU engine and throws
  /// [EmbeddingLoadException] unless it gets [dimension] finite values that
  /// are not all zero. `engine_create` does not run the graph — it reports a
  /// failed warm-up only in the native log — so without this a bundle the NPU
  /// cannot run (another SoC's, or a stack without this Hexagon version's
  /// Skel) would load and fail on the first request instead. Text only: the
  /// vision tower of a per-SoC bundle is compiled for the same SoC and loaded
  /// by the same dispatch, and probing it would cost an image embedding
  /// (about 0.3 s on an SM8650) at every load.
  /// One embedding of [_probeText] on the NPU [target] or, with no target,
  /// on the GPU; refuses an error, a wrong size, or a non-finite or zero
  /// vector.
  void _probeAccelerator(
    LiteRtLmEmbeddingBindings b,
    int dimension,
    LiteRtLmNpuTarget? target,
  ) {
    final bytes = utf8.encode(_probeText);
    final buffer = _alloc<Uint8>(bytes.length);
    final Pointer<LiteRtLmInputData> part;
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      part = b.litert_lm_input_data_create(
        LiteRtLmInputDataType.kLiteRtLmInputDataTypeText,
        buffer.cast(),
        bytes.length,
      );
    } finally {
      _alloc.free(buffer);
    }
    if (part == nullptr) {
      throw const EmbeddingLoadException(
        'litert_lm_input_data_create returned NULL for the accelerator probe',
        engine: liteRtLmEngineTag,
      );
    }
    final partArray = _alloc<Pointer<LiteRtLmInputData>>();
    try {
      partArray[0] = part;
      final (:response, :code, :message) = _compute(b, partArray, 1);
      if (response == nullptr) {
        throw EmbeddingLoadException(
          target == null
              ? 'LiteRT-LM could not run $_file on the GPU: $message. Load it '
                    'with preferredBackend: cpu to embed on the CPU.'
              : 'LiteRT-LM could not run $_file on the NPU of this device: '
                    '$message. The bundle is compiled for $target; '
                    '${liteRtLmNpuProbeFailureCauses(target)}, it fails this '
                    'way.',
          engine: liteRtLmEngineTag,
          nativeCode: code == _statusOk ? null : code,
        );
      }
      try {
        final size = b.litert_lm_embedding_response_get_size(response);
        final values = b.litert_lm_embedding_response_get_values(response);
        final fault = size != dimension || values == nullptr
            ? '$size values for dimension $dimension'
            : _vectorFault(values, size);
        if (fault != null) {
          throw EmbeddingLoadException(
            '$_file on the ${target == null ? 'GPU' : '$target NPU'} '
            'returned $fault for a test input; it is not used.',
            engine: liteRtLmEngineTag,
          );
        }
      } finally {
        b.litert_lm_embedding_response_delete(response);
      }
    } finally {
      b.litert_lm_input_data_delete(part);
      _alloc.free(partArray);
    }
  }

  /// What is wrong with a vector of [size] [values], or null: a NaN or an
  /// infinity, or all zeros.
  static String? _vectorFault(Pointer<Float> values, int size) {
    var nonZero = false;
    for (var i = 0; i < size; i++) {
      final v = values[i];
      if (!v.isFinite) return 'a non-finite value ($v at $i)';
      if (v != 0) nonZero = true;
    }
    return nonZero ? null : 'an all-zero vector';
  }

  // ── ModelInfo ──────────────────────────────────────────────────────────

  _ModelInfo _readModelInfo(LiteRtLmEmbeddingBindings b) {
    final path = _config.modelPath.toNativeUtf8(allocator: _alloc);
    final Pointer<LiteRtLmLoadedFile> file;
    try {
      b.litert_lm_clear_last_error();
      file = b.litert_lm_loaded_file_create(path.cast());
    } finally {
      _alloc.free(path);
    }
    if (file == nullptr) {
      final (:code, :message) = _lastError(b);
      throw EmbeddingLoadException(
        'LiteRT-LM could not read $_file: $message',
        engine: liteRtLmEngineTag,
        nativeCode: code == _statusOk ? null : code,
      );
    }
    try {
      final LiteRtLmModelType? type;
      try {
        type = b.litert_lm_loaded_file_model_type(file);
      } on ArgumentError {
        // A model type newer than these bindings: not one this pass runs.
        return _unknownModelInfo;
      }
      return (
        type: type,
        dimension: b.litert_lm_loaded_file_embedding_dimension(file),
        textSignatures: _signatures(
          (lengths, max) =>
              b.litert_lm_loaded_file_embedding_signature_selection(
                file,
                lengths,
                max,
              ),
        ),
        visionSignatures: _signatures(
          (lengths, max) => b.litert_lm_loaded_file_vision_signature_selection(
            file,
            lengths,
            max,
          ),
        ),
      );
    } finally {
      b.litert_lm_loaded_file_delete(file);
    }
  }

  /// A ModelInfo length list: the count first (a NULL array), then the
  /// values. Null when the file defines none (-1).
  List<int>? _signatures(int Function(Pointer<Int32>, int) read) {
    final count = read(nullptr, 0);
    if (count < 0) return null;
    if (count == 0) return const [];
    final lengths = _alloc<Int32>(count);
    try {
      final written = math.min(read(lengths, count), count);
      return [for (var i = 0; i < written; i++) lengths[i]];
    } finally {
      _alloc.free(lengths);
    }
  }

  /// Refuses what this pass cannot run, from ModelInfo alone; returns the
  /// text signatures.
  List<int> _checkModelInfo(_ModelInfo info) {
    switch (info.type) {
      case LiteRtLmModelType.kLiteRtLmModelTypeEmbedding:
        break;
      case LiteRtLmModelType.kLiteRtLmModelTypeLlm:
        _refuse(
          '$_file is an LLM bundle, not an embedder. Install it with '
          '`installModel(fileType: ModelFileType.litertlm)` for inference, '
          'and an EmbeddingGemma 2 bundle with `installEmbedder()`.',
        );
      case LiteRtLmModelType.kLiteRtLmModelTypeUnknown || null:
        _refuse('$_file is not a LiteRT-LM embedding bundle.');
    }
    if (info.dimension <= 0) {
      _refuse('$_file declares no embedding dimension.');
    }
    final text = info.textSignatures;
    if (text == null || !text.any((length) => length > 0)) {
      _refuse('$_file declares no text signature to embed with.');
    }
    final media = _config.declaredMedia;
    if (media.contains(EmbeddingModality.audio)) {
      // describe() already refused a bundle without one; this is the backstop
      // for a pass built by any other route.
      requireLiteRtLmAudioEncoder(_config.modelPath);
    }
    if (media.contains(EmbeddingModality.image)) {
      // D23: from the vision signatures, never supports_input_modality.
      if (!_hasVision(info)) {
        _refuse(
          '$_file has no vision encoder; install '
          'embeddinggemma-2-text-vision-440m',
        );
      }
      final budgets = info.visionSignatures!;
      final budget = _config.visionTokensPerImage;
      if (!budgets.contains(budget)) {
        _refuse(
          '$_file has vision signatures for ${budgets.join(' and ')} tokens '
          'per image, not $budget: '
          'LiteRtEmbeddingBackend(visionTokensPerImage: …) must be one of '
          'them.',
        );
      }
    }
    return text;
  }

  /// Whether the bundle has a vision encoder: a non-empty vision signature
  /// list (`[70, 140]` on the 440m and 740m, -1 on the 270m).
  static bool _hasVision(_ModelInfo info) =>
      info.visionSignatures?.any((length) => length > 0) ?? false;

  Never _refuse(String message) =>
      throw EmbeddingLoadException(message, engine: liteRtLmEngineTag);

  // ── Cache directory (D22) ──────────────────────────────────────────────

  /// Creates `<cacheBase>/<liteRtLmCacheDirName>/` for this copy of the
  /// bundle and returns its path, with the bundle's size (which the engine's
  /// cache file names repeat). Nothing else is touched until the engine
  /// exists ([_deleteStaleSiblings]).
  ({String cacheDir, int modelSize}) _createCacheDir() {
    try {
      final stat = File(_config.modelPath).statSync();
      if (stat.type == FileSystemEntityType.notFound) {
        throw FileSystemException('model file not found', _config.modelPath);
      }
      final name = liteRtLmCacheDirName(
        _file,
        size: stat.size,
        modified: stat.modified,
      );
      final dir = Directory(
        '${_config.cacheBase}${Platform.pathSeparator}$name',
      )..createSync(recursive: true);
      return (cacheDir: dir.path, modelSize: stat.size);
    } on FileSystemException catch (e) {
      throw EmbeddingLoadException(
        'could not create the embedding cache directory for $_file under '
        '${_config.cacheBase}: ${e.osError?.message ?? e.message}',
        engine: liteRtLmEngineTag,
        cause: e,
      );
    }
  }

  /// Deletes the caches earlier copies of this file name left (a re-download
  /// or a new revision under the same name changes size or mtime). Runs only
  /// after this pass's engine exists — after a successful load, or right
  /// before the no-cache refusal — and spares any sibling touched within
  /// [_siblingGrace] — directory or newest entry — because another process
  /// (an app extension sharing the container, the app mid-replacement) may be
  /// creating its engine from it right now; it is collected by a later load.
  /// Costs disk, never correctness: a sibling that will not go is logged and
  /// the rest are still tried.
  void _deleteStaleSiblings(String cacheDir) {
    final keep = _fileName(cacheDir);
    final ours = RegExp(
      '^${liteRtLmCacheDirPrefix(_file)}-[0-9a-z]+-[0-9a-z]+\$',
    );
    final List<FileSystemEntity> entries;
    try {
      // Sorted, so the order is the same everywhere (listing order is not).
      entries = Directory(_config.cacheBase).listSync()
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException catch (e) {
      edgeAiLog(
        '[LiteRtLmEmbeddingPass] could not list ${_config.cacheBase}: $e',
      );
      return;
    }
    final now = _now();
    for (final entry in entries) {
      final name = _fileName(entry.path);
      if (entry is! Directory || name == keep || !ours.hasMatch(name)) {
        continue;
      }
      try {
        if (now.difference(_lastTouched(entry)) < _siblingGrace) continue;
        entry.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        edgeAiLog(
          '[LiteRtLmEmbeddingPass] could not delete the stale cache '
          '${entry.path}: $e',
        );
      }
    }
  }

  /// The latest modification of [dir] itself or of anything directly in it.
  static DateTime _lastTouched(Directory dir) {
    var latest = dir.statSync().modified;
    for (final entry in dir.listSync()) {
      final modified = entry.statSync().modified;
      if (modified.isAfter(latest)) latest = modified;
    }
    return latest;
  }

  /// How recently a sibling cache may have been touched and still be spared.
  static const _siblingGrace = Duration(minutes: 10);

  /// The engine writes its weight cache at create: one file per tower that
  /// runs on CPU (the text and vision towers of every bundle that has them,
  /// whatever was declared, and the 740m's audio tower), each opened and given
  /// its header at once. A tower whose file could not be created (a path too
  /// long for the platform, a directory this process cannot write to,
  /// possibly no free space at all) runs without one — slower to load and,
  /// measured on the 270m, about 290 MB larger — and says so only in the
  /// native log, which this pass does not capture. Said here in release
  /// builds too, because that is a cost the app pays silently; with
  /// [LiteRtLmEmbeddingConfig.requireWeightCache], no cache at all is a load
  /// failure instead (the caller deletes the engine). A disk that fills while
  /// the cache is built never gets here: XNNPack aborts the process.
  ///
  /// A real cache is what [liteRtLmWrittenWeightCaches] finds: a 0-byte or
  /// header-only file is what a failed or partial header write left, not a
  /// cache. The refusal looks at the directory as a whole. The towers whose
  /// file is expected ([text], [vision], [audio]) are matched by the tower's
  /// name in the file name (upstream constants) and only warned about: a wrong
  /// guess must never refuse a load that works.
  void _checkWeightCache(
    String cacheDir, {
    required int modelSize,
    required bool text,
    required bool vision,
    required bool audio,
  }) {
    final List<String> written;
    try {
      written = liteRtLmWrittenWeightCaches(Directory(cacheDir).listSync());
    } on FileSystemException catch (e) {
      // The directory existed a moment ago. With the flag, an unchecked cache
      // is not a confirmed one; without it, said, since a directory nobody
      // can list is most likely one the engine could not write to either.
      final what =
          'could not check the weight cache LiteRT-LM was to write to '
          '$cacheDir while loading $_file: ${e.osError?.message ?? e.message}';
      if (_config.requireWeightCache) {
        throw EmbeddingLoadException(what, engine: liteRtLmEngineTag, cause: e);
      }
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_litertlm] WARNING: $what. '
        'LiteRtEmbeddingBackend(requireWeightCache: true) makes this a load '
        'failure.',
      );
      return;
    }
    // How long [tower]'s cache file path is (what MAX_PATH applies to), and
    // what likely kept the engine from creating it.
    String pathAndCauses(String tower) {
      final length = liteRtLmCacheFilePathLength(
        cacheDir,
        _file,
        modelSize,
        tower: tower,
      );
      final causes = liteRtLmNoWeightCacheCauses(
        cachePathLength: length,
        windows: Platform.isWindows,
      );
      return 'The cache file path is about $length characters long. $causes';
    }

    String towerName(String tower) => switch (tower) {
      _textTower => 'the text tower',
      _visionTower => 'the vision tower',
      _ => 'the audio tower',
    };
    if (written.isEmpty) {
      // The tower whose file was surely expected: the text tower on CPU, the
      // vision tower beside a GPU text tower, the audio tower on the NPU (or
      // beside a GPU text tower on a bundle without vision).
      final first = text
          ? _textTower
          : vision
          ? _visionTower
          : _audioTower;
      final why = pathAndCauses(first);
      // On the GPU and the NPU the text tower writes no XNNPack cache: the
      // towers it was expected for are named, and the 270m figure (its text
      // tower) does not apply.
      final towers = [if (vision) _visionTower, if (audio) _audioTower];
      final whose = text
          ? ''
          : ' for ${towers.map(towerName).join(' and ')}, which '
                '${towers.length == 1 ? 'runs' : 'run'} on CPU,';
      final cost = text
          ? 'slower to load; about 290 MB more memory for the 270m'
          : 'slower to load, more memory';
      if (_config.requireWeightCache) {
        // Collected first, as after a successful create (the engine exists):
        // an older copy's cache may be what left no free space, and keeping
        // it would refuse every later load too.
        _deleteStaleSiblings(cacheDir);
        throw EmbeddingLoadException(
          'LiteRT-LM wrote no weight cache to $cacheDir$whose while loading '
          '$_file, and LiteRtEmbeddingBackend(requireWeightCache: true) '
          'refuses to run it without one ($cost). $why',
          engine: liteRtLmEngineTag,
        );
      }
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_litertlm] WARNING: LiteRT-LM wrote no weight cache '
        'to $cacheDir$whose while loading $_file, so this embedder runs '
        'without one ($cost). $why '
        'LiteRtEmbeddingBackend(requireWeightCache: true) makes this a load '
        'failure.',
      );
      return;
    }
    bool has(String tower) => written.any((name) => name.contains(tower));
    final missing = [
      if (text && !has('$_textTower.')) _textTower,
      if (vision && !has('$_visionTower.')) _visionTower,
      if (audio && !has('audio_encoder.')) _audioTower,
    ];
    if (missing.isEmpty) return;
    // The path reported is the last tower's, the longest name of them (text,
    // then vision, then audio).
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] WARNING: LiteRT-LM wrote no weight cache for '
      '${missing.map(towerName).join(' and ')} of $_file to $cacheDir, so '
      '${missing.length == 1 ? 'it runs' : 'they run'} without one (slower to '
      'load, more memory). ${pathAndCauses(missing.last)}',
    );
  }

  /// What a GPU load without ML Drift's caches costs, from the 270m's
  /// measurements (README): the first load, which builds them, against a
  /// load that finds them.
  static const _coldGpuCost =
      'every GPU load then compiles the programs and uploads the weights '
      'again (measured on the 270m: 5.9-8.2 s for a first load, 1.7-3.6 s for '
      'one that finds the caches)';

  /// Refuses (with [LiteRtLmEmbeddingConfig.requireWeightCache]) or warns
  /// about, before the engine exists, GPU cache files LiteRT's WebGPU
  /// accelerator cannot create in [cacheDir] ([liteRtLmGpuCachePathProblem]).
  /// The directory is not shortened for it: its name is already the short
  /// form, and the rest is the app's cache path and the model's file name.
  /// Returns whether it warned, so the check after the probe does not warn
  /// again for the same cause.
  bool _checkGpuCachePaths(String cacheDir, int modelSize) {
    final problem = liteRtLmGpuCachePathProblem(
      cacheDir,
      _file,
      modelSize,
      windows: Platform.isWindows,
      ansiCodePageIsUtf8: _ansiCodePageIsUtf8(),
    );
    if (problem == null) return false;
    final what =
        'LiteRT-LM cannot write the GPU caches of $_file under the cache root '
        '${_config.cacheBase}: $problem. Without them $_coldGpuCost. A shorter '
        'model file name or app cache path, in ASCII, avoids it.';
    if (_config.requireWeightCache) {
      throw EmbeddingLoadException(
        '$what LiteRtEmbeddingBackend(requireWeightCache: true) refuses to '
        'run it.',
        engine: liteRtLmEngineTag,
      );
    }
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] WARNING: $what '
      'LiteRtEmbeddingBackend(requireWeightCache: true) makes this a load '
      'failure.',
    );
    return true;
  }

  /// Logs [cacheDir]'s files and their sizes (debug, `edgeAiLog`): when ML
  /// Drift writes each GPU cache — at create, at the first run, or only at
  /// engine delete — is not documented, and a device run reads it here.
  void _logCacheListing(String cacheDir, String when) {
    try {
      final files = Directory(cacheDir).listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      edgeAiLog(
        '[LiteRtLmEmbeddingPass] $cacheDir $when: '
        '${files.isEmpty ? 'empty' : files.map((f) => '${_fileName(f.path)} ${_sizeOf(f)} B').join(', ')}',
      );
    } on FileSystemException catch (e) {
      edgeAiLog('[LiteRtLmEmbeddingPass] could not list $cacheDir $when: $e');
    }
  }

  /// After the probe embedding on the GPU, looks for ML Drift's two caches
  /// ([liteRtLmWrittenGpuCaches]). As on CPU, the refusal under
  /// [LiteRtLmEmbeddingConfig.requireWeightCache] needs no GPU cache at all
  /// and one missing beside the other is a printed warning either way. That
  /// split is the assumption a device run confirms (the listings
  /// [_logCacheListing] prints): the weight cache is written while the engine
  /// is created, and the program cache by then or at the probe, the graph's
  /// first run. A cache written only at engine delete would refuse every GPU
  /// load under the flag on its first start, which the integration tests,
  /// registered with the flag, would show.
  ///
  /// [pathWarned]: the check before create already warned about these files
  /// ([_checkGpuCachePaths]), so a missing cache is not warned about twice.
  /// The refusal is not affected: with the flag, that check refused first.
  void _checkGpuCache(
    String cacheDir, {
    required int modelSize,
    required bool pathWarned,
  }) {
    final ({bool weight, bool program}) written;
    try {
      written = liteRtLmWrittenGpuCaches(Directory(cacheDir).listSync());
    } on FileSystemException catch (e) {
      final what =
          'could not check the GPU caches LiteRT-LM was to write to $cacheDir '
          'while loading $_file: ${e.osError?.message ?? e.message}';
      if (_config.requireWeightCache) {
        throw EmbeddingLoadException(what, engine: liteRtLmEngineTag, cause: e);
      }
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_litertlm] WARNING: $what. '
        'LiteRtEmbeddingBackend(requireWeightCache: true) makes this a load '
        'failure.',
      );
      return;
    }
    if (written.weight && written.program) return;
    if (pathWarned && !_config.requireWeightCache) return;
    final names = liteRtLmGpuCacheFileNames(_file, modelSize);
    final path = '$cacheDir${Platform.pathSeparator}${names.program}';
    final why =
        'The program cache file path is about ${path.length} characters long. '
        '${liteRtLmNoWeightCacheCauses(cachePathLength: path.length, windows: Platform.isWindows)}';
    if (!written.weight && !written.program) {
      if (_config.requireWeightCache) {
        // As on CPU: an older copy's cache may be what left no free space.
        _deleteStaleSiblings(cacheDir);
        throw EmbeddingLoadException(
          'LiteRT-LM wrote no GPU cache (ML Drift weight and program caches) '
          'to $cacheDir while loading $_file, and '
          'LiteRtEmbeddingBackend(requireWeightCache: true) refuses to run it '
          'without them: $_coldGpuCost. $why',
          engine: liteRtLmEngineTag,
        );
      }
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_litertlm] WARNING: LiteRT-LM wrote no GPU cache (ML '
        'Drift weight and program caches) to $cacheDir while loading $_file: '
        '$_coldGpuCost. $why LiteRtEmbeddingBackend(requireWeightCache: true) '
        'makes this a load failure.',
      );
      return;
    }
    final missing = written.weight ? 'program' : 'weight';
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] WARNING: LiteRT-LM wrote no GPU $missing '
      'cache (ML Drift) to $cacheDir while loading $_file, so the next GPU '
      'load ${missing == 'program' ? 'compiles the programs' : 'uploads the weights'} '
      'again. $why',
    );
  }

  // ── Settings, engine, options ──────────────────────────────────────────

  Pointer<LiteRtLmEmbeddingEngine> _createEngine(
    LiteRtLmEmbeddingBindings b, {
    required int maxInputLength,
    required String cacheDir,
    required int? visionTokensPerImage,
    required bool audio,
  }) {
    final path = _config.modelPath.toNativeUtf8(allocator: _alloc);
    final backend = _config.backend.name.toNativeUtf8(allocator: _alloc);
    // Tower backends NULL (D26): present towers run on the main backend, and
    // naming one the bundle lacks fails create with code 5. One exception:
    // the per-SoC 740m bundles compile the audio encoder for cpu/gpu only —
    // on the NPU its NULL backend fails create with "Audio backend constraint
    // mismatch. Model requires one of [cpu,gpu] but Audio backend is NPU"
    // (Galaxy S26+, SM8850, 2026-10-13). Audio is declared only on a bundle
    // whose container has an audio encoder, so naming it here is safe.
    // The other: with the text tower on the GPU, every tower the container
    // has is named cpu (describe() read which), so only text runs on the GPU;
    // the bundles' `tf_lite_end_of_vision`/`_audio` sections are themselves
    // constrained to cpu.
    final visionBackend = _config.visionTowerOnCpu
        ? 'cpu'.toNativeUtf8(allocator: _alloc)
        : nullptr;
    final audioBackend = (_onNpu && audio) || _config.audioTowerOnCpu
        ? 'cpu'.toNativeUtf8(allocator: _alloc)
        : nullptr;
    final Pointer<LiteRtLmEmbeddingEngineSettings> settings;
    try {
      b.litert_lm_clear_last_error();
      settings = b.litert_lm_embedding_engine_settings_create(
        path.cast(),
        backend.cast(),
        visionBackend.cast(),
        audioBackend.cast(),
      );
    } finally {
      _alloc.free(path);
      _alloc.free(backend);
      if (visionBackend != nullptr) _alloc.free(visionBackend);
      if (audioBackend != nullptr) _alloc.free(audioBackend);
    }
    if (settings == nullptr) {
      final (:code, :message) = _lastError(b);
      throw EmbeddingLoadException(
        'LiteRT-LM could not build embedding settings for $_file: $message',
        engine: liteRtLmEngineTag,
        nativeCode: code == _statusOk ? null : code,
      );
    }
    try {
      final dir = cacheDir.toNativeUtf8(allocator: _alloc);
      try {
        b.litert_lm_embedding_engine_settings_set_cache_dir(
          settings,
          dir.cast(),
        );
      } finally {
        _alloc.free(dir);
      }
      b.litert_lm_embedding_engine_settings_set_max_input_length(
        settings,
        maxInputLength,
      );
      final threads = _config.numThreads;
      if (threads != null) {
        b.litert_lm_embedding_engine_settings_set_num_threads(
          settings,
          threads,
        );
      }
      if (visionTokensPerImage != null) {
        // D25: 140 by default, 70 opt-in; checked against the bundle's vision
        // signatures from ModelInfo already.
        b.litert_lm_embedding_engine_settings_set_vision_tokens_per_image(
          settings,
          visionTokensPerImage,
        );
      }
      final dispatchDir = _config.npuDispatchDir;
      if (_onNpu && dispatchDir != null) {
        // Every executor: the towers run on the main backend, and each has
        // its own settings. Upstream skips a tower the bundle lacks.
        //
        // Intel (Windows): the LLM path also sets `use_hw_masking_for_npu`
        // false there, because the kWH mask method failed a CFG check
        // (0xc0000409) on Intel's NPU. LiteRT-LM's embedding engine never
        // reads that flag (only the LLM NPU executor does), and EmbeddingGemma
        // 2 270m `_Intel_PTL` runs without it (Panther Lake, 2026-10-21).
        final dir = dispatchDir.toNativeUtf8(allocator: _alloc);
        try {
          b
            ..litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir(
              settings,
              dir.cast(),
            )
            ..litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir(
              settings,
              dir.cast(),
            )
            ..litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir(
              settings,
              dir.cast(),
            );
        } finally {
          _alloc.free(dir);
        }
      }
      // The Intel dispatch writes the bundle's weights to a bank in the temp
      // directory during the create (74.5 MB for the 270m): the ones new
      // after it are this engine's.
      final vendor = _onNpu ? npuVendorOf(_config.npuTarget!) : null;
      final claimBanks = vendor != null && npuStagesWeightBanks(vendor);
      final banksBefore = claimBanks ? listIntelWeightBanks() : null;
      final (:engine, :code, :message) = _npuCall(() {
        b.litert_lm_clear_last_error();
        final engine = b.litert_lm_embedding_engine_create(settings);
        if (engine != nullptr) return (engine: engine, code: 0, message: '');
        final (:code, :message) = _lastError(b);
        return (engine: engine, code: code, message: message);
      });
      if (engine == nullptr) {
        throw EmbeddingLoadException(
          _onNpu
              ? 'LiteRT-LM could not create the embedding engine for $_file '
                    'on the ${_config.npuTarget} NPU: $message'
              // LiteRT runs the GPU graph with no CPU accelerator: a missing
              // WebGPU adapter or an op it cannot place fails here.
              : _config.gpu
              ? 'LiteRT-LM could not create the embedding engine for $_file '
                    'on the GPU: $message. Load it with preferredBackend: cpu '
                    'to embed on the CPU.'
              // Measured: a missing or read-only cache dir is code 3 at create.
              : code == _statusInvalidArgument
              ? 'LiteRT-LM refused the embedding cache directory $cacheDir '
                    '(missing or not writable): $message'
              : 'LiteRT-LM could not create the embedding engine for $_file: '
                    '$message',
          engine: liteRtLmEngineTag,
          nativeCode: code == _statusOk ? null : code,
        );
      }
      if (claimBanks) {
        _banks = IntelWeightBankClaim.newSince(
          banksBefore,
          listIntelWeightBanks(),
        );
      }
      return engine;
    } finally {
      // The engine copied what it needs.
      b.litert_lm_embedding_engine_settings_delete(settings);
    }
  }

  Pointer<LiteRtLmEmbeddingOptions> _createOptions(
    LiteRtLmEmbeddingBindings b,
  ) {
    final options = b.litert_lm_embedding_options_create();
    if (options == nullptr) {
      // `new` in C++; a NULL here sets no error.
      throw const EmbeddingLoadException(
        'litert_lm_embedding_options_create returned NULL',
        engine: liteRtLmEngineTag,
      );
    }
    b
      ..litert_lm_embedding_options_set_normalize(options, true)
      // Pinned (D26): BOS 2 / EOS 1, as Sentence Transformers; off changes
      // the vectors (cos ≈ 0.90).
      ..litert_lm_embedding_options_set_insert_special_tokens(options, true)
      // kTruncate (§4.8, the P3 gate): an overflowing input comes back as a
      // truncated response whose token counts the pass reports exactly.
      ..litert_lm_embedding_options_set_input_overflow_strategy(
        options,
        LiteRtLmInputOverflowStrategy.kLiteRtLmInputOverflowStrategyTruncate,
      );
    // output_size is never set: MRL is an app recipe (D18).
    return options;
  }
}

/// The text input setting and the resulting limit for a bundle whose text
/// signatures are [textSignatures] (at least one positive).
///
/// The setting is [liteRtLmMaxInputLength] (D21), or the largest signature
/// when none reaches it; the engine then accepts inputs up to the smallest
/// signature at or above the setting — that is `maxInputTokens`.
({int setting, int maxInputTokens}) liteRtLmInputLimit(
  List<int> textSignatures,
) {
  final lengths = [
    for (final length in textSignatures)
      if (length > 0) length,
  ]..sort();
  if (lengths.isEmpty) {
    throw ArgumentError.value(textSignatures, 'textSignatures', 'no length');
  }
  final setting = math.min(liteRtLmMaxInputLength, lengths.last);
  return (
    setting: setting,
    maxInputTokens: lengths.firstWhere((length) => length >= setting),
  );
}

/// The cache directory name for one copy of a bundle:
/// `<liteRtLmCacheDirPrefix(file)>-<size>-<mtime ms>`, both numbers in base 36,
/// so a re-downloaded or replaced file never reads the weight cache of another
/// (the engine's own cache file names carry the same pair).
///
/// Short on purpose (R5 D22 spells the file name out): the engine names its
/// cache file `<model file name>_<mtime>_<size>.<graph>.xnnpack_cache` inside
/// this directory, and on Windows the whole path must stay under MAX_PATH or
/// the engine runs without a weight cache. With `<cache>/flutter_edge_ai/emb/`
/// and this 24-character name the example app's path is 232 characters for a
/// 20-character user name; spelling the file name out made it about 284.
String liteRtLmCacheDirName(
  String modelFileName, {
  required int size,
  required DateTime modified,
}) =>
    '${liteRtLmCacheDirPrefix(modelFileName)}-${size.toRadixString(36)}-'
    '${modified.millisecondsSinceEpoch.toRadixString(36)}';

/// The part of [liteRtLmCacheDirName] that names the file: the first 8 hex
/// digits of the SHA-256 of its name. Directories with this prefix and another
/// size or time are stale copies of the same file.
String liteRtLmCacheDirPrefix(String modelFileName) =>
    sha256.convert(utf8.encode(modelFileName)).toString().substring(0, 8);

/// The tower names LiteRT-LM puts in its weight cache file names
/// (`embedding_executor_settings.h`, `vision_executor_settings.h`,
/// `audio_executor_settings.h`). The vision tower's adapter
/// (`.vision_adapter`) is as long as its encoder; the audio tower's is
/// `.static_audio_encoder` or this, the longer.
const _textTower = '.text_encoder';
const _visionTower = '.vision_encoder';
const _audioTower = '.streaming_audio_encoder';

/// `ExecutorSettingsBase::kXnnpackCacheSuffix`.
const _xnnpackCacheSuffix = '.xnnpack_cache';

/// Windows' MAX_PATH: a path of this many characters or more cannot be
/// created there.
const _windowsMaxPath = 260;

/// The smallest file that counts as a weight cache. XNNPack writes a header
/// of about 100 bytes when it opens the file, then the packed weights (71 MB
/// for the 270m's text tower); anything below this is what a failed or
/// partial header write left. The threshold
/// `example/integration_test/embeddinggemma2_test.dart` holds a device run to.
@visibleForTesting
const liteRtLmMinWeightCacheBytes = 1 << 20;

/// The names of the real weight cache files among [entries], a cache
/// directory's listing: `*.xnnpack_cache` files of at least
/// [liteRtLmMinWeightCacheBytes]. Each is stat'ed on its own, so a file that
/// vanished or cannot be stat'ed is skipped instead of ending the scan.
@visibleForTesting
List<String> liteRtLmWrittenWeightCaches(Iterable<FileSystemEntity> entries) =>
    [
      for (final entry in entries)
        if (entry is File &&
            entry.path.endsWith(_xnnpackCacheSuffix) &&
            _sizeOf(entry) >= liteRtLmMinWeightCacheBytes)
          _fileName(entry.path),
    ];

/// [file]'s size, or -1 when it is gone or cannot be stat'ed: `statSync`
/// reports that as `notFound` rather than throwing.
int _sizeOf(File file) {
  final stat = file.statSync();
  return stat.type == FileSystemEntityType.file ? stat.size : -1;
}

/// The length of the path LiteRT-LM gives [tower]'s weight cache in
/// [cacheDir]: `<cacheDir>/<model file name>_<mtime s>_<size><tower>.xnnpack_cache`
/// (`executor_settings_base.cc` `GetWeightCacheFile`, `file_util.cc`
/// `GetFileCacheIdentifier`), with the mtime's seconds taken as 10 digits
/// (every date from 2001 to 2286). The text tower's by default — the vision
/// tower's is 2 characters longer, the audio tower's 8 or 11 — so this is what
/// Windows' MAX_PATH applies to, not the directory's length.
@visibleForTesting
int liteRtLmCacheFilePathLength(
  String cacheDir,
  String modelFileName,
  int modelSize, {
  String tower = _textTower,
}) =>
    cacheDir.length +
    1 +
    modelFileName.length +
    '_0000000000_$modelSize'.length +
    tower.length +
    _xnnpackCacheSuffix.length;

/// The suffixes LiteRT's WebGPU accelerator (ML Drift, a closed library)
/// appends to the cache key LiteRT-LM hands it for the text tower on the GPU.
const _gpuWeightCacheSuffix = '_mldrift_weight_cache.bin';
const _gpuProgramCacheSuffix = '_mldrift_program_cache.bin';

/// The longest file name NTFS, ext4 and the other usual file systems accept.
const _maxFileNameLength = 255;

/// The names LiteRT's WebGPU accelerator gives the text tower's GPU caches in
/// a cache directory: LiteRT-LM sets the serialization directory and the model
/// cache key `<model file name>.text_encoder_<mtime s>_<size>`
/// (`litert_compiled_model_executor_utils.cc`, `file_util.cc`), and ML Drift
/// appends `_mldrift_weight_cache.bin` / `_mldrift_program_cache.bin`. The
/// mtime's seconds are taken as 10 digits, as in
/// [liteRtLmCacheFilePathLength]. The program cache's is the longer, by one.
@visibleForTesting
({String weight, String program}) liteRtLmGpuCacheFileNames(
  String modelFileName,
  int modelSize,
) {
  final key = '$modelFileName${_textTower}_0000000000_$modelSize';
  return (
    weight: '$key$_gpuWeightCacheSuffix',
    program: '$key$_gpuProgramCacheSuffix',
  );
}

/// Why LiteRT's WebGPU accelerator cannot create the GPU caches of
/// [modelFileName] in [cacheDir], decided from the path alone before the
/// engine exists; null when both fit. On Windows it opens them with the ANSI
/// `CreateFileA` and no `\\?\` prefix, so a path of 260 characters or more
/// fails there, and so does a path with characters outside ASCII: the
/// accelerator gets it as UTF-8 and `CreateFileA` reads it in the ANSI code
/// page, unless that code page is UTF-8 ([ansiCodePageIsUtf8]). A file name
/// past 255 fails on every file system: UTF-16 code units on Windows (NTFS),
/// UTF-8 bytes elsewhere (ext4, APFS). A failed write is said only on stderr
/// and the create still succeeds, so without this the GPU would be cold at
/// every start in silence.
@visibleForTesting
String? liteRtLmGpuCachePathProblem(
  String cacheDir,
  String modelFileName,
  int modelSize, {
  required bool windows,
  bool ansiCodePageIsUtf8 = false,
}) {
  final names = liteRtLmGpuCacheFileNames(modelFileName, modelSize);
  final unit = windows ? 'character' : 'byte';
  final problems = <String>[
    if (windows &&
        !ansiCodePageIsUtf8 &&
        liteRtLmPathOutsideAscii('$cacheDir${names.program}'))
      'their path has characters outside ASCII, which the accelerator opens '
          "with Windows' ANSI CreateFileA from a UTF-8 path, so it cannot "
          'open them at any length',
    for (final (kind, name) in [
      ('weight', names.weight),
      ('program', names.program),
    ]) ...[
      if (windows && cacheDir.length + 1 + name.length >= _windowsMaxPath)
        'its $kind cache file path would be about '
            '${cacheDir.length + 1 + name.length} characters long, past '
            "Windows' $_windowsMaxPath-character MAX_PATH",
      if (_fileNameLength(name, windows: windows) > _maxFileNameLength)
        'its $kind cache file name would be about '
            '${_fileNameLength(name, windows: windows)} ${unit}s long, past '
            'the $_maxFileNameLength-$unit limit on a file name',
    ],
  ];
  return problems.isEmpty ? null : problems.join('; ');
}

/// A file name's length as its file system counts it: UTF-16 code units on
/// NTFS, UTF-8 bytes on ext4 and APFS.
int _fileNameLength(String name, {required bool windows}) =>
    windows ? name.length : utf8.encode(name).length;

/// Whether [path] has a character outside ASCII.
@visibleForTesting
bool liteRtLmPathOutsideAscii(String path) =>
    path.codeUnits.any((unit) => unit > 0x7F);

/// Whether this process's ANSI code page is UTF-8 (65001, set by an app
/// manifest's `activeCodePage` or the system-wide beta option): then the
/// ANSI file APIs read a UTF-8 path as it is. False off Windows.
bool _ansiCodePageIsUtf8() {
  if (!Platform.isWindows) return false;
  final getAcp = DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<Uint32 Function(), int Function()>('GetACP');
  return getAcp() == 65001;
}

/// The names of the real GPU cache files among [entries], a cache directory's
/// listing: `*_mldrift_weight_cache.bin` and `*_mldrift_program_cache.bin` of
/// at least [liteRtLmMinWeightCacheBytes] (measured on the 270m: 68 MB and
/// 9 MB).
@visibleForTesting
({bool weight, bool program}) liteRtLmWrittenGpuCaches(
  Iterable<FileSystemEntity> entries,
) {
  bool has(String suffix) => entries.any(
    (entry) =>
        entry is File &&
        entry.path.endsWith(suffix) &&
        _sizeOf(entry) >= liteRtLmMinWeightCacheBytes,
  );
  return (
    weight: has(_gpuWeightCacheSuffix),
    program: has(_gpuProgramCacheSuffix),
  );
}

/// Why the engine wrote no weight cache, for the refusal and the warnings,
/// given the length of the cache file path ([liteRtLmCacheFilePathLength]).
/// On Windows from 260 characters MAX_PATH is the likely cause; otherwise
/// every cause that leaves a tower uncached is listed. A disk that fills while
/// the cache is built is not one of them: XNNPack aborts the process then.
@visibleForTesting
String liteRtLmNoWeightCacheCauses({
  required int cachePathLength,
  required bool windows,
}) => windows && cachePathLength >= _windowsMaxPath
    ? "That is past Windows' 260-character MAX_PATH, the likely cause (a "
          'shorter model file name or app cache path avoids it); the others '
          'are a directory this process cannot write to and no free space at '
          'all.'
    : 'Likely causes: a path too long for the platform (on Windows, MAX_PATH '
          'is 260 characters), a directory this process cannot write to, or no '
          'free space at all.';

typedef _ModelInfo = ({
  LiteRtLmModelType? type,
  int dimension,
  List<int>? textSignatures,
  List<int>? visionSignatures,
});

const _ModelInfo _unknownModelInfo = (
  type: null,
  dimension: -1,
  textSignatures: null,
  visionSignatures: null,
);

/// The calling thread's last LiteRT-LM error, copied. Call it right after the
/// failing call, before any other native call or `await`, and clear the state
/// right before that call: success never resets it, so without the clear an
/// earlier failure on this (pooled) thread would read as this one's. Code 0
/// after a NULL means the call reported nothing.
({int code, String message}) _lastError(LiteRtLmEmbeddingBindings b) {
  final code = b.litert_lm_get_last_error_code();
  final message = b.litert_lm_get_last_error_message();
  return (
    code: code,
    message: code == _statusOk || message == nullptr
        ? 'no error reported (status $code)'
        : message.cast<Utf8>().toDartString(),
  );
}

String _fileName(String path) => path.split(RegExp(r'[/\\]')).last;
