import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/model.dart' show ModelFileType;
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver;
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_source.dart'
    show HuggingFaceResolverSource;
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart' show InferenceModel;
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'ffi/backend_preference.dart';
import 'ffi/ffi_inference_model.dart';
import 'ffi/litert_lm_client.dart';
import 'manifest/litertlm_manifest_resolver.dart' show LitertlmManifestResolver;

/// Minimum context window (`max_num_tokens`) for `.litertlm` models.
///
/// `.litertlm` models bake a fixed `kv_cache_max_len` (1024 for every
/// supported model — e.g. Gemma 4 E2B, FunctionGemma). The native engine sizes
/// its KV-cache from `max_num_tokens`; a value below the baked length
/// underflows the magic-number tensor resize and `DYNAMIC_UPDATE_SLICE` then
/// fails to allocate tensors at generation time (#318 — verified on a Pixel
/// 8a: 512 crashes, 1024 works). No native API reports the model's minimum, so
/// we clamp up to the largest known minimum. Clamping up only over-allocates a
/// few MB of KV-cache and never under-allocates.
const int kMinLitertlmContextTokens = 1024;

/// Raises [maxTokens] to [kMinLitertlmContextTokens] when a caller passes a
/// value below it. Such values were almost certainly meant to cap *output*
/// length — `maxTokens` is the whole CONTEXT WINDOW (input + output, the
/// KV-cache), not the generation length. To limit generation, pass
/// `maxOutputTokens` to `createSession`.
///
/// **Not applied on [PreferredBackend.npu].** The floor above is a CPU/GPU
/// fact: those bundles bake `kv_cache_max_len` 1024 and underflow below it.
/// NPU bundles are compiled for one `cache_length`, and on Qualcomm the
/// prefill mask the compiled graph carries
/// (`2 B x num_attention_heads x prefill x (cache_length + prefill)`) must stay
/// at or under ~1 MiB or every prefill chunk after the first is dropped — the
/// model answers from chunk 0 alone, with no error. For the 4-head Gemma 3
/// bundles that puts the largest working value at **896**, i.e. BELOW this
/// floor; clamping up to 1024 is exactly the setting that breaks them
/// (LiteRT-LM#3508). A 16-head model has no working value at prefill 128 at
/// all. So on NPU the caller's number is passed through untouched: the safe
/// context is a property of the bundle, and only the caller knows it.
///
/// Pass the backend of the ATTEMPT, not the one the caller asked for. A
/// requested NPU falls back npu -> gpu -> cpu, and the floor still has to apply
/// to the two that follow.
@visibleForTesting
int clampLitertlmContextTokens(
  int maxTokens, {
  PreferredBackend? preferredBackend,
}) {
  if (preferredBackend == PreferredBackend.npu) return maxTokens;
  if (maxTokens >= kMinLitertlmContextTokens) return maxTokens;
  edgeAiLog(
    '[LiteRtLmEngine] maxTokens ($maxTokens) is below the minimum context '
    'size for .litertlm models; clamping to $kMinLitertlmContextTokens. '
    'maxTokens is the CONTEXT WINDOW (KV-cache, input + output) — not the '
    'generation length. Use maxOutputTokens on createSession to cap how many '
    'tokens are generated.',
  );
  return kMinLitertlmContextTokens;
}

/// Pure map from a [RuntimeConfig] + resolved text backend to the encoder /
/// backend / activation args of [LiteRtLmFfiClient.initialize]. Extracted from
/// [LiteRtLmEngine.createModel] so the vision↔audio wiring is unit-testable
/// without path_provider or a real FFI `dlopen` — the swap it guards is silent
/// under the default config (both encoders resolve to `cpu`). The activation
/// type is here for the same reason: a dropped value is silent until a GPU
/// writes wrong digits.
@visibleForTesting
({
  String backend,
  bool enableVision,
  String visionBackend,
  int maxNumImages,
  bool enableAudio,
  String audioBackend,
  int? activationDataType,
})
encoderInitArgs(RuntimeConfig config, PreferredBackend activeBackend) => (
  backend: ffiBackendWireName(activeBackend),
  enableVision: config.supportImage,
  visionBackend: encoderBackendWireName(config.preferredVisionBackend),
  maxNumImages: config.supportImage ? (config.maxNumImages ?? 1) : 0,
  enableAudio: config.supportAudio,
  audioBackend: encoderBackendWireName(config.preferredAudioBackend),
  activationDataType: activationDataTypeWireValue(config.activationDataType),
);

/// LiteRT-LM (.litertlm) inference engine. Pure factory: builds and returns a
/// bare [InferenceModel]; core owns the singleton lifecycle and registers its
/// reset via [InferenceModel.addCloseListener] (added in a later task).
class LiteRtLmEngine
    implements InferenceEngineProvider, HuggingFaceResolverSource {
  const LiteRtLmEngine();

  @override
  String get name => 'LiteRT-LM';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.litertlm;

  /// The engine's own Hugging Face resolver: reads a repo's
  /// `litertlm_manifest.json`. Auto-registered by
  /// `FlutterEdgeAi.initialize(inferenceEngines: …)`, so `.litertlm` HF manifests
  /// resolve without a separate `huggingFaceResolvers:` list. Pass an explicit
  /// `LitertlmManifestResolver(revision: …)` to `initialize` only to override
  /// (e.g. pin a revision).
  @override
  HuggingFaceResolver get huggingFaceResolver =>
      const LitertlmManifestResolver();

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    final cacheDir = (await getApplicationSupportDirectory()).path;
    final ffiRuntime = await initializeFfiRuntime<LiteRtLmFfiClient>(
      preferredBackend: config.preferredBackend,
      logTag: '[LiteRtLmEngine]',
      createClient: LiteRtLmFfiClient.new,
      initializeClient: (client, backend) async {
        final args = encoderInitArgs(config, backend);
        // Per ATTEMPT, not per request: a requested NPU falls back npu -> gpu
        // -> cpu (`ffiBackendFallbackOrder`), and the floor this skips exists
        // for the two it falls back to. Computing it once from the REQUESTED
        // backend would hand an unclamped NPU-sized context to the CPU engine
        // that follows, which is the #318 crash.
        final maxTokens = clampLitertlmContextTokens(
          config.maxTokens,
          preferredBackend: backend,
        );
        await client.initialize(
          modelPath: config.modelPath,
          backend: args.backend,
          maxTokens: maxTokens,
          cacheDir: cacheDir,
          enableVision: args.enableVision,
          visionBackend: args.visionBackend,
          maxNumImages: args.maxNumImages,
          enableAudio: args.enableAudio,
          audioBackend: args.audioBackend,
          enableSpeculativeDecoding: config.enableSpeculativeDecoding,
          activationDataType: args.activationDataType,
        );
      },
      shutdownClient: (client) => client.shutdown(),
    );

    // Only the GPU executor reads the activation type. A GPU attempt that
    // failed — float32 needs more GPU memory — falls back to CPU without an
    // error, so say that the setting did nothing here.
    if (config.activationDataType != null &&
        ffiRuntime.activeBackend != PreferredBackend.gpu) {
      edgeAiLog(
        '[LiteRtLmEngine] activationDataType '
        '(${config.activationDataType!.name}) has no effect: the model runs on '
        '${ffiRuntime.activeBackend.name}, and only the GPU executor reads it.',
      );
    }

    return FfiInferenceModel(
      ffiClient: ffiRuntime.client,
      // The value the engine was actually built with: the same rule, resolved
      // against the backend whose attempt succeeded rather than the requested
      // one, so a fallback to CPU reports the clamped context it really has.
      maxTokens: clampLitertlmContextTokens(
        config.maxTokens,
        preferredBackend: ffiRuntime.activeBackend,
      ),
      modelType: spec.modelType,
      activeBackend: ffiRuntime.activeBackend,
      fileType: spec.fileType,
      supportImage: config.supportImage,
      supportAudio: config.supportAudio,
      maxConcurrentSessions: config.maxConcurrentSessions,
      onClose: () {}, // no-op: core resets its own state via addCloseListener
    );
  }
}
