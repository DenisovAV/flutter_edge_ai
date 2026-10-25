import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'dart:async';
import 'dart:io' show FileSystemException;

import 'bundle/litertlm_bundle_info.dart';
import 'bundle/litertlm_bundle_reader.dart';
import 'bundle/litertlm_load_plan.dart';
import 'ffi/backend_preference.dart';
import 'ffi/ffi_inference_model.dart';
import 'litertlm_decision_section.dart';
import 'ffi/litert_lm_client.dart';
import 'ffi/npu_vendor_host.dart';
import 'litert_lm_engine_host.dart';
import 'litert_lm_log_level.dart';
import 'litertlm_bundle_activation.dart';
import 'manifest/litertlm_manifest_resolver.dart' show LitertlmManifestResolver;
import 'thinking_token_budget.dart';

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
/// NPU bundles are compiled for one `cache_length`, which can sit BELOW this
/// floor. In a Gemma 3 bundle built with litert-torch's `npu_export` for the
/// Qualcomm NPU, the prefill mask the compiled graph carries
/// (`2 B x (attention heads / KV heads) x prefill x (cache_length + prefill)`)
/// must stay at or under ~1 MiB or every prefill chunk after the first is
/// dropped — the model answers from chunk 0 alone, with no error. With 4
/// attention heads per KV head that puts the largest working `cache_length` at
/// prefill 128 at **896** (LiteRT-LM#3508). That limit is set when the bundle
/// is built, not by `maxTokens`: LiteRT-LM's NPU executor (v0.18.0,
/// `DetermineMaxSequenceLengthStaticModel`) lowers a larger value to the
/// compiled limit of a bundle with a static KV cache, with a warning, so
/// raising 896 to 1024 would not break it. Garbled Qwen3 output on the NPU is
/// a different bug (LiteRT-LM#3846). The floor is skipped on NPU because it is
/// a CPU/GPU fact: the caller's number is passed through untouched, since the
/// context is a property of the bundle and only the caller knows it.
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
encoderInitArgs(
  RuntimeConfig config,
  PreferredBackend activeBackend, {
  ActivationDataType? gpuDefaultActivation,
  PreferredBackend? visionBackend,
  PreferredBackend? audioBackend,
}) => (
  backend: ffiBackendWireName(activeBackend),
  enableVision: config.supportImage,
  // The load plan's choice (`planLiteRtLmLoad`), else the request.
  visionBackend: encoderBackendWireName(
    visionBackend ?? config.preferredVisionBackend,
  ),
  maxNumImages: config.supportImage ? (config.maxNumImages ?? 1) : 0,
  enableAudio: config.supportAudio,
  audioBackend: encoderBackendWireName(
    audioBackend ?? config.preferredAudioBackend,
  ),
  // The caller's value wins on every backend. The engine's own default (see
  // `gpuActivationDefault`) is for a GPU attempt only: only the GPU executor
  // reads the type, and a CPU or NPU attempt is left as the bundle has it.
  activationDataType: activationDataTypeWireValue(
    config.activationDataType ??
        (activeBackend == PreferredBackend.gpu ? gpuDefaultActivation : null),
  ),
);

/// LiteRT-LM (.litertlm) inference engine. Pure factory: builds and returns a
/// bare [InferenceModel]; core owns the singleton lifecycle and registers its
/// reset via [InferenceModel.addCloseListener].
///
/// A [MultiModelEngine]: the models it builds are independent, so
/// `FlutterEdgeAi.openModel` can keep several open at once. Engine
/// creations run one at a time across all of them.
class LiteRtLmEngine
    implements
        InferenceEngineProvider,
        HuggingFaceResolverSource,
        MultiModelEngine {
  const LiteRtLmEngine({
    this.backendFallback = true,
    this.nativeLogLevel,
    this.thinkingTokenBudget,
  });

  /// Whether a model that fails to load on its backend is tried on the next
  /// one: npu → gpu → cpu, gpu → cpu (the default).
  ///
  /// With false, a load makes exactly one attempt — on `preferredBackend`, or
  /// on the GPU when none is given — and a failure throws a
  /// [BackendInitException] whose one attempt names that backend and carries
  /// LiteRT-LM's own reason ([LiteRtLmEngineCreateException.nativeMessage]).
  /// An NPU this device cannot reach is refused at once, without creating an
  /// engine. Use it when a load on another backend would be wrong, not slow:
  /// a benchmark, an NPU demo, an app that would rather say "did not load on
  /// the GPU" than load a multi-gigabyte model again on the CPU.
  ///
  /// A bundle compiled for an NPU is tried on the NPU only either way: the GPU
  /// and the CPU cannot run it. The vision and audio encoders never fall back.
  /// `InferenceModel.activeBackend` names what ran in both modes.
  final bool backendFallback;

  /// The minimum severity of LiteRT-LM's own native log, set before every
  /// engine this one creates, on Android, iOS, macOS, Linux and Windows. The level is process-wide: engines with
  /// different values override each other, and null leaves whatever level the
  /// process has, LiteRT-LM's default until an engine sets one. Other native
  /// loggers in the process (LiteRT's, the GPU and NPU drivers') are not
  /// covered. Above `info`, debug builds lose the INFO lines from which a
  /// failed create names the backend a model requires.
  final LiteRtLmLogLevel? nativeLogLevel;

  /// The most tokens one generation may spend thinking, in every model this
  /// engine builds, on the CPU, the GPU and the NPU alike; null (the default)
  /// sets no budget. It applies only with thinking on (`enableThinking:
  /// true`): when the thinking reaches the budget, LiteRT-LM closes the
  /// thought channel and the model goes on to the answer or the tool call.
  /// Without one, a model can think until `maxOutputTokens` and end the turn
  /// with an empty answer (measured on Intel's Gemma 4 26B for its NPU).
  ///
  /// The budget is per generation: in a tool loop, each generation after a
  /// tool result starts with a fresh one. The thinking counts towards
  /// `maxOutputTokens`, and the reply towards the context (`maxTokens`, 1024
  /// by default), so a budget that can act is below both, with room left for
  /// the answer. LiteRT-LM caps the first channel the bundle declares
  /// (`thought` on the Gemma 4 bundles); a bundle that declares none is not
  /// capped. On the GPU it slows the decoding of the whole generation (about a
  /// fifth for Gemma 4 E2B on an M5 Pro); on the CPU no cost was measured.
  ///
  /// It is fixed when the engine is registered: a second `LiteRtLmEngine`
  /// with another budget does not replace the first. Between 1 and
  /// 0x7fffffff. The web engine accepts it and ignores it: its runtime has no
  /// such setting.
  final int? thinkingTokenBudget;

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
    checkThinkingTokenBudget(thinkingTokenBudget);
    final host = liteRtLmEngineHost;
    final cacheDir = await host.cacheDir();

    // What the file says about itself decides where it can run
    // (`planLiteRtLmLoad`). A file the reader cannot read keeps the rules that
    // need no file: LiteRT-LM also opens `.task` bundles, which have no
    // container header.
    final bundle = await _readBundle(config.modelPath);
    // Whether the NPU is one of the backends the load tries, from the same
    // rules the plan below applies: a request for it, a bundle compiled for
    // it, a text model that declares it alone, or an encoder that is on and
    // runs there. The plan asks whether the NPU is reachable only then, so the
    // app's stack is looked up first.
    final npuMayRun =
        liteRtLmTextCandidates(
          path: config.modelPath,
          bundle: bundle,
          preferredBackend: config.preferredBackend,
          backendFallback: backendFallback,
          abi: host.abi,
        ).backends.contains(PreferredBackend.npu) ||
        liteRtLmEncoderOnNpu(
          bundle: bundle,
          supportImage: config.supportImage,
          supportAudio: config.supportAudio,
          preferredVisionBackend: config.preferredVisionBackend,
          preferredAudioBackend: config.preferredAudioBackend,
        );

    // Whose NPU a load that tries it runs on, decided once, before the plan
    // and before any engine (`chooseNpuVendor`, the rule the EmbeddingGemma 2
    // placement follows too): the vendor the bundle is compiled for, else the
    // first vendor of this host whose stack the build carries and whose device
    // answers. Asked only when the NPU is one of the backends the load tries:
    // on Android it opens a vendor library.
    final npu = npuMayRun
        ? await chooseNpuVendor(
            target: liteRtLmLoadNpuTarget(
              path: config.modelPath,
              bundle: bundle,
              supportImage: config.supportImage,
              supportAudio: config.supportAudio,
              abi: host.abi,
            ),
            host: host,
          )
        : null;
    String npuRefusal() => switch (npu) {
      NpuRefused(:final reason) => reason,
      _ => npuNoVendorReason(host.abi),
    };

    // FunctionGemma bundles converted before litetune 0.1.4 declare no
    // activation type and, at the FP16 a GPU defaults to, answer with `<pad>`
    // or nothing. The header is read only when the answer can matter (see
    // `activationHeaderMatters`).
    ActivationDataType? gpuDefaultActivation;
    if (activationHeaderMatters(
      requested: config.activationDataType,
      preferredBackend: config.preferredBackend,
      modelType: spec.modelType,
    )) {
      final read = await tryReadBundleActivationDeclaration(config.modelPath);
      final error = read.error;
      if (error != null) {
        // A failed read leaves the GPU attempt at FP16, where this bundle can
        // answer with nothing. A release build is where that gets reported and
        // edgeAiLog is silent there, so it is printed, once per load.
        // ignore: avoid_print
        print(
          '[flutter_edge_ai_litertlm] WARNING: could not read which activation '
          'type this FunctionGemma .litertlm declares, so a GPU attempt runs '
          'at the engine default (float16), where a bundle without one can '
          'answer with nothing. Pass '
          'activationDataType: ActivationDataType.float32 to be sure. '
          '${error.split('\n').first}',
        );
      }
      gpuDefaultActivation = gpuActivationDefault(
        requested: null,
        preferredBackend: config.preferredBackend,
        modelType: spec.modelType,
        declaresKey: read.declaresKey,
      );
      if (gpuDefaultActivation != null) {
        edgeAiLog(
          '[LiteRtLmEngine] this FunctionGemma bundle declares no '
          'prefer_activation_type, and at the GPU default of float16 such a '
          'bundle answers with <pad> only: a GPU attempt uses '
          '${gpuDefaultActivation.name}. Pass '
          'activationDataType: ActivationDataType.float16 to keep the default.',
        );
      }
    }

    final plan = planLiteRtLmLoad(
      path: config.modelPath,
      bundle: bundle,
      preferredBackend: config.preferredBackend,
      backendFallback: backendFallback,
      supportImage: config.supportImage,
      supportAudio: config.supportAudio,
      preferredVisionBackend: config.preferredVisionBackend,
      preferredAudioBackend: config.preferredAudioBackend,
      npuAvailable: () => npu is NpuChosen,
      npuUnavailableReason: npuRefusal,
      abi: host.abi,
    );

    final ffiRuntime = await initializeFfiRuntime<LiteRtLmFfiClient>(
      preferredBackend: config.preferredBackend,
      logTag: '[LiteRtLmEngine]',
      createClient: host.createClient,
      npuUnavailableBecause: npu is NpuRefused ? npu.reason : null,
      backends: plan.textBackends,
      droppedBecause: plan.dropped,
      initializeClient: (client, backend) => _oneCreateAtATime(() async {
        final args = encoderInitArgs(
          config,
          backend,
          gpuDefaultActivation: gpuDefaultActivation,
          visionBackend: plan.visionBackend,
          audioBackend: plan.audioBackend,
        );
        // Per ATTEMPT, not per request: a requested NPU falls back npu -> gpu
        // -> cpu (`ffiBackendFallbackOrder`), and the floor this skips exists
        // for the two it falls back to. Computing it once from the REQUESTED
        // backend would hand an unclamped NPU-sized context to the CPU engine
        // that follows, which is the #318 crash.
        final maxTokens = clampLitertlmContextTokens(
          config.maxTokens,
          preferredBackend: backend,
        );
        // The NPU attempt's dispatch, prepared inside the attempt: a stack
        // that cannot be prepared (NpuDispatchUnavailableException) is a
        // failed attempt, which the fallback order then handles.
        final npuDispatch = backend != PreferredBackend.npu
            ? null
            : switch (npu) {
                NpuChosen(:final vendor) => (
                  dir: await host.prepareDispatchDir(vendor),
                  disableHwMasking: npuDisablesHwMasking(vendor),
                  stagesWeightBanks: npuStagesWeightBanks(vendor),
                ),
                _ => throw StateError(
                  'an npu attempt without a chosen NPU vendor',
                ),
              };
        try {
          await host.initializeClient(
            client,
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
            npuDispatch: npuDispatch,
            nativeLogLevel: nativeLogLevel,
            thinkingTokenBudget: thinkingTokenBudget,
          );
        } on LiteRtLmEngineCreateException catch (e, stackTrace) {
          final target = plan.npuTarget;
          if (backend != PreferredBackend.npu || target == null) rethrow;
          // The SoC of the device is not read before the load (nothing
          // reports it reliably on every platform), so a bundle for another
          // SoC fails here. Other causes fail here too, so the SoC is named
          // as a possible cause, not the cause.
          Error.throwWithStackTrace(
            LiteRtLmEngineCreateException(
              '${e.message}. The bundle is compiled for the $target NPU; if '
              'this device is not a $target, that is the cause.',
              nativeCode: e.nativeCode,
              nativeMessage: e.nativeMessage,
            ),
            stackTrace,
          );
        }
      }),
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

    // Read with the model, so that a decider reads the file the engine
    // loaded; a file without a decision costs one header read.
    final decisionRead = await LitetuneDecisionRead.read(config.modelPath);
    return FfiInferenceModel(
      ffiClient: ffiRuntime.client,
      decisionRead: decisionRead,
      // The value the engine was actually built with: the same rule, resolved
      // against the backend whose attempt succeeded rather than the requested
      // one, so a fallback to CPU reports the clamped context it really has.
      maxTokens: clampLitertlmContextTokens(
        config.maxTokens,
        preferredBackend: ffiRuntime.activeBackend,
      ),
      modelType: spec.modelType,
      activeBackend: ffiRuntime.activeBackend,
      activeVisionBackend: plan.visionBackend,
      activeAudioBackend: plan.audioBackend,
      fileType: spec.fileType,
      supportImage: config.supportImage,
      supportAudio: config.supportAudio,
      multimodalOrder: config.multimodalOrder,
      maxConcurrentSessions: config.maxConcurrentSessions,
      onClose: () {}, // no-op: core resets its own state via addCloseListener
    );
  }

  /// [path]'s bundle info, or null when the file is not one this package
  /// reads (a `.task` bundle, a newer container version, a stamp layout it
  /// does not know): the load then keeps the rules that need no file. A file
  /// that ends inside its own header is refused here, as an incomplete one.
  static Future<LiteRtLmBundleInfo?> _readBundle(String path) async {
    try {
      return await readLiteRtLmBundleInfo(path);
    } on LiteRtLmBundleException catch (e) {
      if (e.problem == LiteRtLmBundleProblem.incomplete) rethrow;
      edgeAiLog('[LiteRtLmEngine] $e; loading without reading the file');
      return null;
    } on FileSystemException catch (e) {
      edgeAiLog('[LiteRtLmEngine] $e; loading without reading the file');
      return null;
    }
  }

  static Future<void> _createTail = Future.value();

  /// Runs engine creations one at a time, on every backend; generation on
  /// engines already created is not held. With `FlutterEdgeAi.openModel`
  /// several engines can be created at once, and what a create touches is
  /// process-wide: the Qualcomm dispatch sets `ADSP_LIBRARY_PATH` with
  /// `setenv` while other drivers read the environment, and two engines on
  /// one file write the same cache files in the engine cache directory.
  /// A create is bound by reading the model, so queueing costs little.
  static Future<void> _oneCreateAtATime(Future<void> Function() body) {
    final previous = _createTail;
    final done = Completer<void>();
    _createTail = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }
}
