import 'dart:async';

import 'package:meta/meta.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';
import 'package:litertlm_dart/internal_io.dart'
    show
        backendKindOf,
        createEngineWithBundle,
        engineNpuVendor,
        minCpuGpuContextTokens,
        npuBackendOn,
        LlmModelFamily,
        gpuActivationFor,
        liteRtLmEncoderOnNpu,
        liteRtLmTextCandidates,
        readEngineBundle,
        GpuActivationDecision,
        tryReadBundleActivationDeclaration;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;
import 'package:litertlm_dart/litertlm_dart.dart'
    show LiteRtLmBundleException, LiteRtLmLogLevel;

import 'adapter/backend_fallback.dart';
import 'adapter/core_hints.dart';
import 'adapter/ffi_inference_model.dart';
import 'adapter/runtime_log_binding.dart';
import 'adapter/runtime_mapping.dart';
import 'adapter/structured_output_support.dart';
import 'adapter/tool_calls.dart';
import 'catalog/litert_catalog.dart' show LiteRtLmModels;
import 'litert_lm_engine_host.dart';
import 'litert_lm_load_errors.dart';
import 'litertlm_decision_section.dart';
import 'manifest/litertlm_manifest_resolver.dart' show LitertlmManifestResolver;
import 'thinking_token_budget.dart';

/// Minimum context window (`max_num_tokens`) of a CPU or GPU `.litertlm`
/// load: litertlm_dart's [lm.minCpuGpuContextTokens], where the floor is
/// applied (`Engine.create`). `maxTokens` is the CONTEXT WINDOW, not the
/// reply length; cap a reply with `maxOutputTokens` on the session.
const int kMinLitertlmContextTokens = minCpuGpuContextTokens;

/// LiteRT-LM (.litertlm) inference engine. Pure factory: builds and returns a
/// bare [InferenceModel]; core owns the singleton lifecycle and registers its
/// reset via [InferenceModel.addCloseListener].
///
/// A [MultiModelEngine]: the models it builds are independent, so
/// `FlutterEdgeAi.openModel` can keep several open at once. Engine
/// creations run one at a time across all of them.
/// The LoRA rank a `.litertlm` engine is created with, from core's
/// `RuntimeConfig.loraRanks`: LiteRT-LM takes one rank (Swift's
/// `EngineConfig.loraRank`), so one entry is that rank, none is none, and
/// several are refused by name instead of keeping one of them silently.
@visibleForTesting
int? liteRtLmLoraRank(List<int>? loraRanks) => switch (loraRanks) {
  null || [] => null,
  [final rank] => rank,
  _ => throw ArgumentError.value(
    loraRanks,
    'loraRanks',
    'a .litertlm engine takes one LoRA rank (LiteRT-LM\'s set_lora_rank); '
        'pass one',
  ),
};

class LiteRtLmEngine
    implements
        InferenceEngineProvider,
        HuggingFaceResolverSource,
        ModelCatalogSource,
        MultiModelEngine {
  const LiteRtLmEngine({
    this.backendFallback = true,
    this.nativeLogLevel,
    this.thinkingTokenBudget,
  });

  /// Whether a model that fails to load on its backend is tried on the next
  /// one the model file allows: npu → gpu → cpu, gpu → cpu (the default). A
  /// generic bundle is never tried on the NPU, so `npu` starts at the GPU.
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
  /// with an empty answer. A model that reasons with thinking off too (Qwen3
  /// 4B Thinking 2507) is not capped then: LiteRT-LM applies a budget only to
  /// a generation with thinking on.
  ///
  /// The budget is per generation: every send with thinking on carries it,
  /// so in a tool loop a generation after a tool result has its own. The
  /// thinking counts towards `maxOutputTokens`, and the reply, with the
  /// prompt and the history, towards the context (`maxTokens`, 1024 by
  /// default), so a budget that can act is below both, with room left for
  /// the answer. LiteRT-LM caps the first channel the bundle declares
  /// (`thought` on the Gemma 4 bundles); a bundle that declares none is not
  /// capped, and loading one with a budget prints a warning. On the GPU it
  /// slows the decoding of the whole generation (Gemma 4 E2B: about a fifth
  /// on an M5 Pro, about 40% on an NVIDIA L4); on the CPU no cost was
  /// measured.
  ///
  /// It is fixed when the engine is registered: a second `LiteRtLmEngine`
  /// with another budget does not replace the first. To change it, close the
  /// model, call `FlutterEdgeAi.reset()`, which drops every registration, and
  /// `initialize` again with every provider the app uses. Between 1 and
  /// 0x7fffffff: a value outside throws [ArgumentError] when a model loads.
  /// The web engine accepts it and ignores it: its runtime has no such
  /// setting.
  final int? thinkingTokenBudget;

  @override
  String get name => 'LiteRT-LM';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.litertlm;

  /// The LLMs this engine runs, pinned to Hugging Face commits:
  /// [LiteRtLmModels.catalog]. `FlutterEdgeAi.catalog` includes it once the
  /// engine is passed to `initialize`.
  @override
  ModelCatalog get modelCatalog => LiteRtLmModels.catalog;

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
    try {
      return await _createModel(spec, config);
    } catch (e, st) {
      // litertlm_dart words its refusals in its own API; the app sets core's.
      final hinted = withCoreHintError(e);
      if (identical(hinted, e)) rethrow;
      Error.throwWithStackTrace(hinted, st);
    }
  }

  Future<InferenceModel> _createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    checkThinkingTokenBudget(thinkingTokenBudget);
    bindRuntimeLogToCore();
    final host = liteRtLmEngineHost;
    final cacheDir = await host.cacheDir();

    // What the file says about itself decides where it can run: the text
    // backends to try, in order, and those the file rules out (a file the
    // reader cannot read keeps the rules that need no file). Each attempt is
    // one `Engine.create`, which refuses what cannot run before any engine
    // exists, chooses the NPU vendor from the bundle and applies the context
    // floor and the GPU activation rules.
    final read = await readEngineBundle(config.modelPath);
    final bundle = read.info;
    final candidates = liteRtLmTextCandidates(
      path: config.modelPath,
      bundle: bundle,
      preferredBackend: config.preferredBackend?.toRuntime,
      backendFallback: backendFallback,
      abi: host.abi,
    );

    lm.Backend backendOf(PreferredBackend backend) => switch (backend) {
      PreferredBackend.cpu => const lm.Backend.cpu(),
      PreferredBackend.gpu => const lm.Backend.gpu(),
      PreferredBackend.npu => npuBackendOn(host.npuPlatform),
    };
    // An encoder the caller left unset loads where the file wants it.
    lm.Backend? encoder(
      bool on,
      PreferredBackend? requested,
      lm.Backend? declared,
    ) => !on
        ? null
        : requested != null
        ? backendOf(requested)
        : switch (declared) {
            lm.NpuBackend() => npuBackendOn(host.npuPlatform),
            final declared? => declared,
            null => const lm.Backend.cpu(),
          };
    final visionBackend = encoder(
      config.supportImage,
      config.preferredVisionBackend,
      bundle?.declaredVisionBackend,
    );
    final audioBackend = encoder(
      config.supportAudio,
      config.preferredAudioBackend,
      bundle?.declaredAudioBackend,
    );

    // The GPU activation rule is decided here, by the model type the app
    // declared, as flutter_edge_ai_litertlm always has: the runtime's own
    // rule (by the bundle's model type) is for plain-Dart Engine.create.
    final gpuActivation = config.activationDataType == null
        ? await _declaredTypeActivation(spec, config, abi: host.abi)
        : null;

    final loraRank = liteRtLmLoraRank(config.loraRanks);
    final attempt = await initializeFfiRuntime<_EngineAttempt>(
      preferredBackend: config.preferredBackend,
      logTag: '[LiteRtLmEngine]',
      createClient: _EngineAttempt.new,
      backends: [for (final b in candidates.backends) b.toCore],
      droppedBecause: {
        for (final MapEntry(:key, :value) in candidates.dropped.entries)
          key.toCore: value,
      },
      initializeClient: (slot, backend) async {
        slot.engine = await createEngineWithBundle(
          lm.EngineConfig(
            modelPath: config.modelPath,
            backend: backendOf(backend),
            visionBackend: visionBackend,
            audioBackend: audioBackend,
            maxNumTokens: config.maxTokens,
            maxNumImages: config.supportImage ? config.maxNumImages : null,
            cacheDir: cacheDir,
            activationDataType: config.activationDataType?.toRuntime,
            speculativeDecoding: switch (config.enableSpeculativeDecoding) {
              true => lm.SpeculativeDecodingConfig(
                mode: lm.SpeculativeDecodingMode.on,
              ),
              false => lm.SpeculativeDecodingConfig(
                mode: lm.SpeculativeDecodingMode.off,
              ),
              null => null,
            },
            loraRank: loraRank,
          ),
          read,
          toolCallsOf: liteRtLmToolCallsOf,
          gpuActivation: gpuActivation,
          // This engine's own level, set before each of its engines; null
          // leaves the process's level as it is, whatever LiteRtLmLog says.
          nativeLevel: nativeLogLevel,
        );
      },
      shutdownClient: (slot) => slot.engine?.close(),
      // An NPU this device cannot reach, with other backends left: dropped
      // with a notice, as the load did before it tried any engine.
      skipAttempt: (backend, error) =>
          backend == PreferredBackend.npu &&
          error is NpuDispatchUnavailableException,
      // The file cannot run as asked on any backend (an encoder, an
      // incomplete download), or an encoder needs an NPU out of reach
      // whatever the text runs on: refused at once, not tried again.
      isFatal: (error) =>
          error is LiteRtLmBundleException ||
          (error is NpuDispatchUnavailableException &&
              liteRtLmEncoderOnNpu(
                bundle: bundle,
                supportImage: config.supportImage,
                supportAudio: config.supportAudio,
                preferredVisionBackend:
                    config.preferredVisionBackend?.toRuntime,
                preferredAudioBackend: config.preferredAudioBackend?.toRuntime,
              )),
    );
    final engine = attempt.client.engine!;
    final activeBackend = attempt.activeBackend;

    // Read with the model, so that a decider reads the file the engine
    // loaded; a file without a decision costs one header read.
    final decisionRead = await LitetuneDecisionRead.read(config.modelPath);
    final androidGpu = activeBackend == PreferredBackend.gpu
        ? host.androidGpuFamily()
        : null;
    return FfiInferenceModel(
      engine: engine,
      decisionRead: decisionRead,
      // The context the engine was actually created with (the CPU/GPU floor
      // applied to the backend that loaded).
      maxTokens: engine.maxNumTokens,
      modelType: spec.modelType,
      activeBackend: activeBackend,
      activeVisionBackend: switch (engine.visionBackend) {
        final b? => backendKindOf(b).toCore,
        null => null,
      },
      activeAudioBackend: switch (engine.audioBackend) {
        final b? => backendKindOf(b).toCore,
        null => null,
      },
      fileType: spec.fileType,
      supportImage: config.supportImage,
      supportAudio: config.supportAudio,
      multimodalOrder: config.multimodalOrder,
      maxConcurrentSessions: config.maxConcurrentSessions,
      thinkingTokenBudget: thinkingTokenBudget,
      structuredOutput: liteRtLmStructuredOutputSupport(
        abi: host.abi,
        backend: activeBackend,
        npuVendor: engineNpuVendor(engine),
        androidGpu: androidGpu,
      ),
      onClose: () {}, // no-op: core resets its own state via addCloseListener
    );
  }

  /// The GPU activation a load of [spec] gets when the app set none, by the
  /// model type the app declared (not the bundle's own): float32 for
  /// `ModelType.gemma4` above a 2,048-token context (LiteRT-LM #4001), except
  /// on Android ([abi]), where it keeps float16 and the engine says so, and for
  /// a `ModelType.functionGemma` bundle that declares no
  /// `prefer_activation_type`; none otherwise.
  static Future<GpuActivationDecision> _declaredTypeActivation(
    InferenceModelSpec spec,
    RuntimeConfig config, {
    required String abi,
  }) async {
    final family = switch (spec.modelType) {
      ModelType.gemma4 => LlmModelFamily.gemma4,
      ModelType.functionGemma => LlmModelFamily.functionGemma,
      _ => null,
    };
    // The CPU executor does not read the type, and a CPU-only load has no GPU
    // attempt to warn about.
    if (family == null || config.preferredBackend == PreferredBackend.cpu) {
      return (type: null, reason: null);
    }
    bool? declares;
    if (family == LlmModelFamily.functionGemma) {
      final read = await tryReadBundleActivationDeclaration(config.modelPath);
      declares = read.declaresKey;
      final error = read.error;
      if (error != null) {
        // A failed read leaves the GPU at float16, where this bundle can
        // answer with nothing; a release build is where that gets reported.
        // ignore: avoid_print
        print(
          '[flutter_edge_ai_litertlm] WARNING: could not read which '
          'activation type this FunctionGemma .litertlm declares, so a GPU '
          'attempt runs at the engine default (float16), where a bundle '
          'without one can answer with nothing. Pass '
          'activationDataType: ActivationDataType.float32 to be sure. '
          '${error.split('\n').first}',
        );
      }
    }
    return gpuActivationFor(
      family: family,
      declaresActivation: declares,
      maxNumTokens: config.maxTokens,
      android: abi.startsWith('android'),
    );
  }
}

/// One backend attempt's engine, for [initializeFfiRuntime].
final class _EngineAttempt {
  lm.Engine? engine;
}
