// LiteRT-LM's Kotlin/Swift `Engine`: one loaded `.litertlm` model on one
// backend. `Engine.create` is one load attempt. Before any native call it
// reads the file and refuses what cannot run (the load plan), chooses the NPU
// vendor from the bundle, and applies the rules a pure Dart caller would
// otherwise trip over: the 1024-token context floor on the CPU and the GPU,
// and float32 activations on the GPU where float16 is known to break.

import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:ffi' show Abi;
import 'dart:io' show File, FileSystemException, Platform;

import 'package:meta/meta.dart' show internal, visibleForTesting;

import '../bundle/litertlm_bundle_activation.dart';
import '../bundle/litertlm_bundle_info.dart';
import '../bundle/litertlm_bundle_reader.dart';
import '../bundle/litertlm_bundle_sampler.dart'
    show LlmModelFamily, readLlmModelFamily;
import '../bundle/litertlm_load_plan.dart';
import '../ffi/backend_preference.dart'
    show
        activationDataTypeWireValue,
        encoderBackendWireName,
        ffiBackendWireName,
        npuNoVendorReason;
import '../ffi/channel_content_filter.dart';
import '../ffi/conversation_handles.dart';
import '../ffi/litert_lm_client.dart';
import '../ffi/npu_vendor_host.dart';
import '../ffi/open_session_backing.dart';
import '../runtime/constrained_decoding_hosts.dart';
import '../ffi/send_options.dart';
import '../runtime/errors.dart';
import '../runtime/litert_lm_log_level.dart';
import '../runtime/load_errors.dart'
    show LibraryLoadFailure, LiteRtLmLibraryException;
import '../runtime/npu_stacks.dart';
import '../runtime/runtime_log.dart';
import '../runtime/types.dart';
import 'backend.dart';
import 'config.dart';
import 'conversation.dart';
import 'message.dart';

/// The smallest context window a CPU or GPU `.litertlm` engine is created
/// with: the `kv_cache_max_len` the published CPU/GPU bundles bake. Below it
/// the native KV-cache resize underflows and generation fails to allocate
/// tensors (#318: 100, 256 and 512 crash on a Pixel 8a, 1024 works). An NPU
/// bundle has one compiled cache length, which can be lower, so the NPU is
/// left as asked.
const minCpuGpuContextTokens = 1024;

/// The context [maxNumTokens] is created with on [backend]: raised to
/// [minCpuGpuContextTokens] on the CPU and the GPU, with a log line saying
/// that the context window is not the reply length.
int contextTokensFor(int maxNumTokens, BackendKind backend) {
  if (backend == BackendKind.npu || maxNumTokens >= minCpuGpuContextTokens) {
    return maxNumTokens;
  }
  runtimeLog(
    '[LiteRtLmEngine] maxNumTokens ($maxNumTokens) is below the minimum '
    'context size for .litertlm models on the CPU and the GPU; clamping to '
    '$minCpuGpuContextTokens. It is the CONTEXT WINDOW (KV-cache, input + '
    'output), not the reply length: ConversationConfig.maxOutputTokens caps '
    'how many tokens are generated.',
  );
  return minCpuGpuContextTokens;
}

/// A GPU activation the caller decided by a rule of its own, for
/// [createEngineWithBundle]: the type (null: the engine's default) and why it
/// was chosen. Given, the engine does not apply [gpuActivationFor].
typedef GpuActivationDecision = ({
  ActivationDataType? type,
  GpuActivationReason? reason,
});

/// The activation type a GPU load runs at when the caller set none: float32
/// for Gemma 4 with a context above [gemma4Fp16MaxContextTokens] (its float16
/// rotary positions stop being distinct there, LiteRT-LM #4001), and for a
/// FunctionGemma bundle that declares no `prefer_activation_type` (converted
/// before litetune 0.1.4: at float16 it answers with `<pad>` or nothing).
/// [family] is the bundle's `llm_model_type`; [declaresActivation] whether it
/// declares a type (null: unread). Null leaves the bundle's own.
({ActivationDataType? type, GpuActivationReason? reason}) gpuActivationFor({
  required LlmModelFamily? family,
  required bool? declaresActivation,
  required int maxNumTokens,
}) => switch (family) {
  LlmModelFamily.gemma4 when maxNumTokens > gemma4Fp16MaxContextTokens => (
    type: ActivationDataType.float32,
    reason: GpuActivationReason.gemma4LongContext,
  ),
  LlmModelFamily.functionGemma when declaresActivation == false => (
    type: ActivationDataType.float32,
    reason: GpuActivationReason.functionGemmaWithoutKey,
  ),
  _ => (type: null, reason: null),
};

/// A platform for code that passed no [NpuPlatform]: the manifest is not
/// readable (the stack is then checked by loading it), Android cannot prepare
/// a dispatch directory, and the dispatch is looked for beside the
/// executable.
final class _DartNpuPlatform implements NpuPlatform {
  const _DartNpuPlatform();

  @override
  Future<String> readNativeAssetsManifest() => Future.error(
    UnsupportedError('no NpuPlatform was given to read the build manifest'),
  );

  @override
  Future<String?> prepareAndroidDispatchDir(
    List<String> libFileNames,
    NpuStack vendor,
  ) => throw NpuDispatchUnavailableException(
    'the ${vendor.label} NPU libraries need a dispatch directory on Android, '
    'which plain Dart cannot prepare: pass Backend.npu(dispatchDir:) with a '
    "directory holding that vendor's libraries only (flutter_edge_ai_litertlm "
    'prepares one through its platform channel)',
  );

  @override
  String get executableDir => executableDirOf();
}

/// What [Engine.create] reaches outside Dart, behind one object so a VM test
/// can drive a whole load without a native library or a device.
class EngineHost {
  const EngineHost();

  /// `Abi.current()`, as its `toString()`.
  String get abi => '${Abi.current()}';

  /// The NPU answers for [platform].
  LiteRtLmNpuHost npuHost(NpuPlatform? platform) =>
      LiteRtLmPlatformNpuHost(platform ?? const _DartNpuPlatform());

  /// The GPU family of an Android device; null elsewhere.
  AndroidGpuFamily? androidGpuFamily() => Platform.isAndroid
      ? androidGpuFamilyFrom((path) => File(path).existsSync())
      : null;

  /// A client for one load.
  LiteRtLmFfiClient createClient() => LiteRtLmFfiClient();

  /// Creates the engine in [client].
  Future<void> initializeClient(
    LiteRtLmFfiClient client, {
    required String modelPath,
    required String backend,
    required int maxTokens,
    required String? cacheDir,
    required bool enableVision,
    required String visionBackend,
    required int maxNumImages,
    required bool enableAudio,
    required String audioBackend,
    required bool? enableSpeculativeDecoding,
    required int? speculativeDecodingMode,
    required int? numThreads,
    required int? activationDataType,
    required GpuActivationReason? gpuActivationReason,
    required NpuDispatch? npuDispatch,
    required LiteRtLmLogLevel? nativeLogLevel,
  }) => client.initialize(
    modelPath: modelPath,
    backend: backend,
    maxTokens: maxTokens,
    cacheDir: cacheDir,
    enableVision: enableVision,
    visionBackend: visionBackend,
    maxNumImages: maxNumImages,
    enableAudio: enableAudio,
    audioBackend: audioBackend,
    enableSpeculativeDecoding: enableSpeculativeDecoding,
    speculativeDecodingMode: speculativeDecodingMode,
    numThreads: numThreads,
    activationDataType: activationDataType,
    gpuActivationReason: gpuActivationReason,
    npuDispatch: npuDispatch,
    nativeLogLevel: nativeLogLevel,
  );

  /// Whether the model at [path] keeps linear attention state; null when the
  /// file cannot be read to tell.
  Future<bool?> linearAttentionState(String path) async {
    Object cause;
    try {
      return await readLiteRtLmHasLinearAttentionState(path);
    } on LiteRtLmBundleException catch (e) {
      cause = e;
    } on FileSystemException catch (e) {
      cause = e;
    }
    // ignore: avoid_print
    print(
      '[litertlm_dart] could not read whether this model keeps linear '
      'attention state ($cause): its conversations are rebuilt from full '
      'messages after a stop or a full context, never rewound.',
    );
    return null;
  }
}

EngineHost _host = const EngineHost();

/// The host loads go through: [debugEngineHost]'s value, for this package.
@internal
EngineHost get currentEngineHost => _host;

/// The host every [Engine.create] goes through; a test replaces it.
@visibleForTesting
EngineHost get debugEngineHost => _host;

@visibleForTesting
set debugEngineHost(EngineHost? host) => _host = host ?? const EngineHost();

/// The native log level [Engine.create] sets before every engine; null
/// leaves the process's (LiteRT-LM's default until one is set). The level is
/// process-wide, as LiteRT-LM's is.
LiteRtLmLogLevel? liteRtLmNativeLogLevel;

/// One `.litertlm` model loaded on one backend.
final class Engine {
  Engine._({
    required this._client,
    required this.backend,
    required this.visionBackend,
    required this.audioBackend,
    required this.maxNumTokens,
    required this.activationDataType,
    required this._npuVendor,
    required this.bundleInfo,
    required this._backing,
    required this._linearAttentionState,
    this._toolCallsOf = nativeToolCalls,
    this._constraintRefusal,
  });

  /// Why a response format is refused on this engine's host and backend
  /// ([liteRtLmConstrainedDecodingRefusal]), or null where it was qualified.
  final String? _constraintRefusal;

  final LiteRtLmFfiClient _client;
  final ToolCallReader _toolCallsOf;
  final OpenSessionBacking _backing;
  final bool? _linearAttentionState;

  /// The text model's backend.
  final Backend backend;

  /// Where the vision and audio encoders run; null when not loaded.
  final Backend? visionBackend;
  final Backend? audioBackend;

  /// The context window the engine was created with, after the CPU/GPU
  /// floor.
  final int maxNumTokens;

  /// The activation type sent to the GPU executor; null left the bundle's.
  final ActivationDataType? activationDataType;

  final NpuStack? _npuVendor;

  /// Every turn runs in a fresh native conversation that replays the history
  /// where a conversation answers its second message empty (the MediaTek NPU,
  /// LiteRT-LM #4256; [liteRtLmFreshConversationEachTurn]).
  bool get _freshConversationEachTurn => liteRtLmFreshConversationEachTurn(
    backend: backendKindOf(backend),
    npuVendor: _npuVendor,
  );

  /// What the file says about itself; null for a file the reader does not
  /// understand (a `.task`, a newer container), which loads by the rules that
  /// need no file.
  final BundleInfo? bundleInfo;

  bool _closed = false;
  bool _channelWarned = false;

  /// Loads [config.modelPath] on [config.backend]: one attempt, no fallback.
  ///
  /// Throws [LiteRtLmBundleException] when the file is incomplete or cannot
  /// run as asked, [NpuDispatchUnavailableException] when the NPU cannot be
  /// reached (both before any engine exists), and
  /// [LiteRtLmEngineCreateException] when LiteRT-LM refuses the engine, and
  /// [LiteRtLmLibraryException] when libLiteRtLm did not load or is not a
  /// build this release drives. A bad argument is an [ArgumentError].
  /// Creations run one at a time in the process: what one touches is
  /// process-wide (the Qualcomm dispatch's environment, the cache files).
  static Future<Engine> create(EngineConfig config) {
    // Read when the caller asks, not when the create's turn comes: a caller
    // that sets the level and then creates gets its own level.
    final nativeLevel = liteRtLmNativeLogLevel;
    return _oneCreateAtATime(
      () => _create(config, _host, nativeLevel, null),
    ).catchError(
      (Object error, StackTrace stack) => Error.throwWithStackTrace(
        LiteRtLmLibraryException((error as LibraryLoadFailure).loadMessage),
        stack,
      ),
      // What the load path marked: libLiteRtLm or a library it needs did not
      // load or is not a build this release drives. A setter LiteRT-LM
      // refused, an isolate that did not spawn and a bad argument keep their
      // own types.
      test: (error) => error is LibraryLoadFailure,
    );
  }

  static Future<Engine> _create(
    EngineConfig config,
    EngineHost host,
    LiteRtLmLogLevel? nativeLevel,
    EngineBundle? read, {
    ToolCallReader toolCallsOf = nativeToolCalls,
    GpuActivationDecision? gpuActivation,
  }) async {
    if (config.backend case CpuBackend(
      :final threadCount?,
    ) when threadCount < 1) {
      throw ArgumentError.value(
        threadCount,
        'threadCount',
        'must be 1 or more',
      );
    }
    final kind = backendKindOf(config.backend);
    final path = config.modelPath;
    final platform =
        npuPlatformOf(config.backend) ??
        npuPlatformOf(config.visionBackend) ??
        npuPlatformOf(config.audioBackend);
    final npuHost = npuHostWithDispatchDir(
      host.npuHost(platform),
      switch (config.backend) {
        NpuBackend(:final dispatchDir) => dispatchDir,
        _ => null,
      },
    );
    final abi = host.abi;
    final supportImage = config.visionBackend != null;
    final supportAudio = config.audioBackend != null;
    final bundle = (read ?? await readEngineBundle(path)).info;
    // An encoder asked for where its file wants it is the file's choice: the
    // plan checks a request against the file, and the file's own default
    // passes by definition (its declared constraint, even without a stamp).
    BackendKind? requested(Backend? asked, BundleSection? encoder) =>
        asked == null ||
            (encoder != null &&
                encoderDefaultBackend(encoder) == backendKindOf(asked))
        ? null
        : backendKindOf(asked);
    final visionRequest = requested(
      config.visionBackend,
      bundle?.visionEncoder,
    );
    final audioRequest = requested(config.audioBackend, bundle?.audioEncoder);

    final npuMayRun =
        kind == BackendKind.npu ||
        liteRtLmEncoderOnNpu(
          bundle: bundle,
          supportImage: supportImage,
          supportAudio: supportAudio,
          preferredVisionBackend: visionRequest,
          preferredAudioBackend: audioRequest,
        );
    final npu = npuMayRun
        ? await chooseNpuVendor(
            target: liteRtLmLoadNpuTarget(
              path: path,
              bundle: bundle,
              supportImage: supportImage,
              supportAudio: supportAudio,
              abi: abi,
            ),
            host: npuHost,
          )
        : null;
    final plan = planLiteRtLmLoad(
      path: path,
      bundle: bundle,
      preferredBackend: kind,
      backendFallback: false,
      supportImage: supportImage,
      supportAudio: supportAudio,
      preferredVisionBackend: visionRequest,
      preferredAudioBackend: audioRequest,
      npuAvailable: () => npu is NpuChosen,
      npuUnavailableReason: () => switch (npu) {
        NpuRefused(:final reason) => reason,
        _ => npuNoVendorReason(abi),
      },
      abi: abi,
    );
    final vendor = switch (npu) {
      NpuChosen(:final vendor) => vendor,
      _ => null,
    };

    final maxTokens = contextTokensFor(config.maxNumTokens ?? 2048, kind);

    // Only the GPU executor reads the activation type: the caller's wins, else
    // the engine's rule for a GPU load.
    var activation = config.activationDataType;
    GpuActivationReason? reason;
    if (activation == null &&
        kind == BackendKind.gpu &&
        gpuActivation != null) {
      // The caller decided by its own rule (the Flutter adapter, by the model
      // type the app declared): the bundle's model type is not consulted.
      activation = gpuActivation.type;
      reason = gpuActivation.reason;
    } else if (activation == null && kind == BackendKind.gpu) {
      final family = await _readFamily(path);
      final declares = family == LlmModelFamily.functionGemma
          ? await _readActivationDeclaration(path)
          : null;
      final chosen = gpuActivationFor(
        family: family,
        declaresActivation: declares,
        maxNumTokens: maxTokens,
      );
      activation = chosen.type;
      reason = chosen.reason;
    }
    switch (reason) {
      case GpuActivationReason.functionGemmaWithoutKey:
        runtimeLog(
          '[LiteRtLmEngine] this FunctionGemma bundle declares no '
          'prefer_activation_type, and at the GPU default of float16 such '
          'a bundle answers with <pad> only: a GPU attempt uses float32. '
          'Pass activationDataType: ActivationDataType.float16 to keep the '
          'default.',
        );
      case GpuActivationReason.gemma4LongContext:
        runtimeLog(
          '[LiteRtLmEngine] Gemma 4 with maxTokens $maxTokens, above '
          '$gemma4Fp16MaxContextTokens: at float16 its rotary positions '
          'past ~2,048 tokens stop being distinct and a long prompt '
          'degrades (LiteRT-LM #4001), so a GPU attempt uses float32. Pass '
          'activationDataType: ActivationDataType.float16 to keep the '
          "bundle's float16.",
        );
      case null:
        break;
    }
    if (config.activationDataType != null && kind != BackendKind.gpu) {
      runtimeLog(
        '[LiteRtLmEngine] activationDataType '
        '(${config.activationDataType!.name}) has no effect: the model runs on '
        '${kind.name}, and only the GPU executor reads it.',
      );
    }

    final NpuDispatch? dispatch = kind != BackendKind.npu
        ? null
        : switch (vendor) {
            final vendor? => (
              dir: switch (config.backend) {
                NpuBackend(:final dispatchDir?) => dispatchDir,
                _ => await npuHost.prepareDispatchDir(vendor),
              },
              useHwMasking: await npuHwMasking(
                vendor,
                bundle,
                path: path,
                broken: brokenNpuMaskAuxInUse,
              ),
              stagesWeightBanks: npuStagesWeightBanks(vendor),
            ),
            null => throw StateError('an NPU load without an NPU vendor'),
          };

    final speculative = config.speculativeDecoding;
    final client = host.createClient();
    try {
      await host.initializeClient(
        client,
        modelPath: path,
        backend: ffiBackendWireName(kind),
        maxTokens: maxTokens,
        cacheDir: config.cacheDir,
        enableVision: supportImage,
        // The plan's choice, else the request (a file that was not read).
        visionBackend: encoderBackendWireName(
          plan.visionBackend ??
              switch (config.visionBackend) {
                final b? => backendKindOf(b),
                null => null,
              },
        ),
        maxNumImages: supportImage ? (config.maxNumImages ?? 1) : 0,
        enableAudio: supportAudio,
        audioBackend: encoderBackendWireName(
          plan.audioBackend ??
              switch (config.audioBackend) {
                final b? => backendKindOf(b),
                null => null,
              },
        ),
        // Off and on keep the boolean setter they always used; adaptive has
        // none and goes through a speculative decoding config.
        enableSpeculativeDecoding: switch (speculative) {
          SpeculativeDecodingMode.off => false,
          SpeculativeDecodingMode.on => true,
          _ => null,
        },
        speculativeDecodingMode: speculative == SpeculativeDecodingMode.adaptive
            ? speculative!.index
            : null,
        numThreads: switch (config.backend) {
          CpuBackend(:final threadCount) => threadCount,
          _ => null,
        },
        activationDataType: activationDataTypeWireValue(activation),
        gpuActivationReason: reason,
        npuDispatch: dispatch,
        nativeLogLevel: nativeLevel,
      );
    } on LiteRtLmEngineCreateException catch (e, st) {
      await _shutdownAfterFailure(client);
      final target = plan.npuTarget;
      if (kind != BackendKind.npu || target == null) rethrow;
      // The device's SoC is not read before the load, so a bundle for another
      // SoC fails here; other causes fail here too, so it is named as a
      // possible cause.
      Error.throwWithStackTrace(
        LiteRtLmEngineCreateException(
          '${e.message}. The bundle is compiled for the $target NPU; if this '
          'device is not a $target, that is the cause.',
          nativeCode: e.nativeCode,
          nativeMessage: e.nativeMessage,
        ),
        st,
      );
    } catch (_) {
      await _shutdownAfterFailure(client);
      rethrow;
    }

    try {
      final linearAttentionState = await host.linearAttentionState(path);
      final androidGpu = kind == BackendKind.gpu
          ? host.androidGpuFamily()
          : null;
      final backing = liteRtLmOpenSessionBacking(
        abi: abi,
        backend: kind,
        npuVendor: vendor,
        androidGpu: androidGpu,
      );
      runtimeLog(
        '[LiteRtLmEngine] open sessions: ${backing.name} conversations on '
        '${kind.name} ($abi); linear attention state: '
        '${linearAttentionState ?? 'unread'}',
      );
      return Engine._(
        client: client,
        backend: config.backend,
        visionBackend: switch (plan.visionBackend) {
          final k? => backendOf(k, platform: platform),
          null => null,
        },
        audioBackend: switch (plan.audioBackend) {
          final k? => backendOf(k, platform: platform),
          null => null,
        },
        maxNumTokens: maxTokens,
        activationDataType: kind == BackendKind.gpu ? activation : null,
        npuVendor: kind == BackendKind.npu ? vendor : null,
        bundleInfo: bundle,
        backing: backing,
        linearAttentionState: linearAttentionState,
        toolCallsOf: toolCallsOf,
        constraintRefusal: liteRtLmConstrainedDecodingRefusal(
          abi: abi,
          backend: kind,
          androidGpu: androidGpu,
          npuVendor: kind == BackendKind.npu ? vendor : null,
        ),
      );
    } catch (_) {
      // The engine exists: it is deleted before the failure reaches the
      // caller.
      await _shutdownAfterFailure(client);
      rethrow;
    }
  }

  static Future<LlmModelFamily?> _readFamily(String path) async {
    try {
      return await readLlmModelFamily(path);
    } on Object catch (e) {
      if (e is! FileSystemException &&
          e is! FormatException &&
          e is! RangeError) {
        rethrow;
      }
      // A release build is where a degraded GPU load gets reported, and
      // runtimeLog is silent there.
      // ignore: avoid_print
      print(
        '[litertlm_dart] WARNING: could not read which model family this '
        ".litertlm names ($e), so a GPU load runs at the bundle's activation "
        'type: Gemma 4 above 2,048 tokens and a FunctionGemma without a '
        'declared type need ActivationDataType.float32; set it if this is '
        'one.',
      );
      return null;
    }
  }

  static Future<bool?> _readActivationDeclaration(String path) async {
    final read = await tryReadBundleActivationDeclaration(path);
    final error = read.error;
    if (error != null) {
      // ignore: avoid_print
      print(
        '[litertlm_dart] WARNING: could not read which activation type this '
        'FunctionGemma .litertlm declares, so a GPU load runs at the engine '
        'default (float16), where a bundle without one can answer with '
        'nothing. Pass activationDataType: ActivationDataType.float32 to be '
        'sure. ${error.split('\n').first}',
      );
    }
    return read.declaresKey;
  }

  static Future<void> _createTail = Future.value();

  static Future<T> _oneCreateAtATime<T>(Future<T> Function() body) {
    final previous = _createTail;
    final done = Completer<void>();
    _createTail = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }

  /// Why a conversation of this engine is rebuilt from its messages instead
  /// of being rewound after a stopped turn or a full context; null when it
  /// rewinds.
  String? get _noRewindReason => backendKindOf(backend) == BackendKind.npu
      ? 'the NPU executor rolls back one token at most'
      : _linearAttentionState == true
      ? 'this model keeps linear attention state, which a rewind cannot '
            'restore'
      : _linearAttentionState == null
      ? 'whether this model keeps linear attention state could not be read '
            'from its file'
      : null;

  /// Whether LiteRT-LM may strip a finished reply's thought from the KV
  /// cache, which it does by rewinding over the reply: only where every
  /// conversation is known to rewind (not on the NPU, not on a model with
  /// linear attention state or one whose state could not be read).
  bool get _filtersChannelContent => liteRtLmFiltersChannelContent(
    npu: backendKindOf(backend) == BackendKind.npu,
    linearAttentionState: _linearAttentionState,
  );

  /// Starts a conversation. On the backends where several live native
  /// conversations were measured to work, it has its own. Elsewhere the
  /// engine's conversations share one native conversation and replay their
  /// messages when they take it over. Either way a stopped, refused or failed
  /// turn is recovered before the next one (see [Conversation]).
  Future<Conversation> createConversation([ConversationConfig? config]) =>
      _createConversation(config, own: _backing == OpenSessionBacking.native);

  Future<Conversation> _createConversation(
    ConversationConfig? config, {
    required bool own,
    SamplerConfig? defaultSamplerConfig,
  }) async {
    if (_closed) throw StateError('The engine is closed.');
    final c = config ?? ConversationConfig();
    final format = c.responseFormat;
    final refusal = _constraintRefusal;
    if (format != null && refusal != null) {
      throw ConstraintUnsupportedException(refusal);
    }
    final constraint = switch (format) {
      JsonResponseFormat(:final schemaJson) => Constraint.jsonSchema(
        schemaJson,
      ),
      RegexResponseFormat(:final pattern) => Constraint.regex(pattern),
      null => null,
    };
    final sampling = samplerFor(
      c.samplerConfig ?? defaultSamplerConfig,
      _client.bundleSampler,
    );
    final explicit = c.samplerConfig != null;
    final tools = toolsJson(c.tools);
    final initial = [for (final m in c.initialMessages) messageJson(m)];
    final extras = ConversationExtras(
      extraContext: c.extraContext,
      speculativeDecoding: c.speculativeDecoding,
    );
    final filter = _filtersChannelContent;
    final ConversationHandle handle;
    switch (own) {
      case true:
        Future<LiteRtLmConversationHandle> open(String? historyJson) =>
            _client.createConversationHandle(
              systemMessage: c.systemInstruction,
              toolsJson: tools,
              messagesJson: _withInitial(initial, historyJson),
              sampling: sampling,
              samplingExplicit: explicit,
              maxOutputTokens: c.maxOutputTokens,
              multimodalOrder: MediaOrder.imagesAudioText,
              constraint: constraint,
              filterChannelContent: filter,
              extras: extras,
            );
        final first = await open(null);
        if (_closed) {
          first.close();
          throw StateError(
            'The engine was closed while a conversation opened.',
          );
        }
        handle = RecoveringConversationHandle(
          first,
          reopen: open,
          toolCallsOf: _toolCallsOf,
          noRewindReason: _noRewindReason,
          freshConversationEachTurn: _freshConversationEachTurn,
        );
      case false:
        handle = VirtualConversationHandle(
          client: _client,
          systemMessage: c.systemInstruction,
          toolsJson: tools,
          sampling: sampling,
          samplingExplicit: explicit,
          multimodalOrder: MediaOrder.imagesAudioText,
          filterChannelContent: filter,
          toolCallsOf: _toolCallsOf,
          maxOutputTokens: c.maxOutputTokens,
          constraint: constraint,
          extras: extras,
          initialHistory: initial,
          freshConversationEachTurn: _freshConversationEachTurn,
        );
    }
    return newConversation(
      handle,
      config: c,
      thinkingTokenBudgetCapsNothing: _budgetCapsNothing,
      engineClosed: () => _closed,
    );
  }

  /// Said once per engine: a thinking budget on a bundle that declares no
  /// output channel caps nothing.
  void _budgetCapsNothing() {
    if (_channelWarned || _client.bundleDeclaresChannel != false) return;
    _channelWarned = true;
    // ignore: avoid_print
    print(
      '[litertlm_dart] WARNING: this model declares no output channel, so '
      'a thinking token budget caps nothing: a turn with thinking on can '
      'still think until maxOutputTokens.',
    );
  }

  static String? _withInitial(
    List<Map<String, Object?>> initial,
    String? historyJson,
  ) {
    if (initial.isEmpty) return historyJson;
    if (historyJson == null) return jsonEncode(initial);
    // The rebuild's history follows the initial messages.
    return '${jsonEncode(initial).substring(0, jsonEncode(initial).length - 1)},'
        '${historyJson.substring(1)}';
  }

  /// The token ids of [text], from the model's own tokenizer.
  Future<List<int>> tokenize(String text) {
    if (_closed) throw StateError('The engine is closed.');
    return _client.tokenIds(text);
  }

  /// The text of [ids].
  Future<String> detokenize(List<int> ids) {
    if (_closed) throw StateError('The engine is closed.');
    return _client.detokenizeIds(ids);
  }

  /// The exact log-probability of each of [targets] as a continuation of
  /// [prompt], scored in one session with a rewind between targets. [cancel]
  /// stops it between targets with [ScoringCancelledException].
  ///
  /// On an engine whose text model runs on the NPU it is an
  /// [UnsupportedError]: the NPU executor rolls back one token, not a
  /// target. Whether a rewind on this LiteRT-LM build scores a target as a
  /// fresh session would (LiteRT-LM #3561) is for the caller to check before
  /// trusting the scores; flutter_edge_ai_litertlm runs that check once per
  /// model.
  Future<ScoringRun> scoreTargets(
    String prompt,
    List<String> targets, {
    CancelSignal? cancel,
  }) {
    if (_closed) throw StateError('The engine is closed.');
    if (backend is NpuBackend) {
      throw UnsupportedError(
        'Option scoring does not run on the NPU: its executor rolls back one '
        'token, not a target. Load the generic bundle on the CPU or the GPU.',
      );
    }
    return _client.scoreTargets(prompt, targets, cancelSignal: cancel);
  }

  /// Closes every conversation and deletes the engine. Waits for a
  /// conversation create still in flight. A reply still streaming ends with
  /// [ConversationClosedException]; a later send on any of its conversations,
  /// and every other call on the engine, is a [StateError].
  Future<void> close() async {
    _closed = true;
    await _client.shutdown();
  }
}

/// What [Engine.create] reads of [path] before any engine exists: its bundle
/// info, or null when the file is not one this package reads; an incomplete
/// file is refused.
Future<EngineBundle> readEngineBundle(String path) async {
  try {
    return EngineBundle._(path, await readBundleInfo(path));
  } on LiteRtLmBundleException catch (e) {
    if (e.problem == LiteRtLmBundleProblem.incomplete) rethrow;
    runtimeLog('[LiteRtLmEngine] $e; loading without reading the file');
  } on FileSystemException catch (e) {
    runtimeLog('[LiteRtLmEngine] $e; loading without reading the file');
  }
  return EngineBundle._(path, null);
}

/// A model file as [readEngineBundle] read it.
final class EngineBundle {
  const EngineBundle._(this.path, this.info);

  final String path;

  /// Null when the file is not one this package reads.
  final BundleInfo? info;
}

/// [Engine.create] with the file already read: a caller that reads it to plan
/// its attempts does not pay for the read again in each one (an in-app read
/// took ~0.57 s on a Linux VM). [bundle] must be [config.modelPath]'s.
///
/// [toolCallsOf] reads the tool calls of a model reply when a conversation
/// replays its history (shared conversations, a rebuild after a stop): a
/// call the model wrote as text is replayed as that call only if it reads
/// it. The default reads the calls native converted; the Flutter adapter
/// passes core's parser, which also reads text-form calls.
Future<Engine> createEngineWithBundle(
  EngineConfig config,
  EngineBundle bundle, {
  ToolCallReader toolCallsOf = nativeToolCalls,
  LiteRtLmLogLevel? nativeLevel,
  GpuActivationDecision? gpuActivation,
}) {
  if (bundle.path != config.modelPath) {
    throw ArgumentError.value(
      bundle.path,
      'bundle',
      'was read from another file than ${config.modelPath}',
    );
  }
  // The caller's level for this engine, else the one LiteRtLmLog set.
  final level = nativeLevel ?? liteRtLmNativeLogLevel;
  return Engine._oneCreateAtATime(
    () => Engine._create(
      config,
      _host,
      level,
      bundle,
      toolCallsOf: toolCallsOf,
      gpuActivation: gpuActivation,
    ),
  );
}

/// A conversation of [engine] with a native conversation of its own whatever
/// the engine's backing: what `flutter_edge_ai_litertlm`'s singleton
/// `createSession` always had, also where the engine's other conversations
/// share one (one live conversation runs on every backend).
///
/// [defaultSamplerConfig] is as [createConversationWithDefault]'s.
Future<Conversation> createOwnConversation(
  Engine engine, [
  ConversationConfig? config,
  SamplerConfig? defaultSamplerConfig,
]) => engine._createConversation(
  config,
  own: true,
  defaultSamplerConfig: defaultSamplerConfig,
);

/// [Engine.createConversation] with the model's own sampler default when the
/// config sets none: the values flutter_edge_ai_litertlm resolves (the file's
/// sampler, then the family's published defaults, then the fallback), which
/// never count as the caller's choice (LiteRT-LM#2080's one-time warning
/// fires only for a sampler the caller set). Null takes the file's sampler,
/// then 0.8 / 40 / 0.95 / seed 1.
Future<Conversation> createConversationWithDefault(
  Engine engine,
  ConversationConfig config,
  SamplerConfig? defaultSamplerConfig,
) => engine._createConversation(
  config,
  own: engine._backing == OpenSessionBacking.native,
  defaultSamplerConfig: defaultSamplerConfig,
);

/// The NPU vendor [engine] loaded on; null off the NPU.
NpuStack? engineNpuVendor(Engine engine) => engine._npuVendor;

/// The sampler [engine]'s model file carries.
BundleSampler engineBundleSampler(Engine engine) =>
    engine._client.bundleSampler;

/// [content] rendered as a user message by [engine]'s prompt template, with
/// the turn's generation prompt: what option scoring continues.
Future<String> engineRenderUserMessage(Engine engine, String content) {
  if (engine._closed) throw StateError('The engine is closed.');
  return engine._client.renderUserMessage(content);
}

/// An engine over [client], for tests that drive conversations with a fake
/// client.
Engine engineForTest(
  LiteRtLmFfiClient client, {
  Backend backend = const Backend.cpu(),
  int maxNumTokens = 4096,
  OpenSessionBacking backing = OpenSessionBacking.virtual,
  bool? linearAttentionState = false,
  NpuStack? npuVendor,
  String? constraintRefusal,
}) => Engine._(
  client: client,
  backend: backend,
  visionBackend: null,
  audioBackend: null,
  maxNumTokens: maxNumTokens,
  activationDataType: null,
  npuVendor: npuVendor,
  bundleInfo: null,
  backing: backing,
  linearAttentionState: linearAttentionState,
  constraintRefusal: constraintRefusal,
);

/// The client under [engine].
LiteRtLmFfiClient engineClient(Engine engine) => engine._client;

/// Whether [engine]'s conversations have a native conversation each, or share
/// one by replaying their messages.
OpenSessionBacking engineConversationBacking(Engine engine) => engine._backing;

/// Why [engine]'s conversations are rebuilt instead of rewound after a stop
/// or a full context; null when they rewind.
String? engineNoRewindReason(Engine engine) => engine._noRewindReason;

/// Whether LiteRT-LM may strip a finished reply's thought from the KV cache
/// of [engine]'s conversations.
bool engineFiltersChannelContent(Engine engine) =>
    engine._filtersChannelContent;

/// Deletes the engine a failed create made, without letting a failure of the
/// delete replace the create's own error, which is what the caller sees.
Future<void> _shutdownAfterFailure(LiteRtLmFfiClient client) async {
  try {
    await client.shutdown();
  } on Object catch (e) {
    runtimeLog('[LiteRtLmEngine] deleting the failed engine failed too: $e');
  }
}
