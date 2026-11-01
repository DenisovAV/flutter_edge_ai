// What `LiteRtLmEngine.createModel` reaches outside Dart — the app's support
// directory, the platform, the NPU stack and hardware probes, the FFI client —
// behind one object, so a VM test can drive the whole load (the bundle read,
// the load plan, the backends and encoders handed to the client) without
// path_provider, a native library or a device. Not exported.

import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'ffi/litert_lm_client.dart';
import 'ffi/npu_stack_manifest.dart';
import 'ffi/npu_vendor_host.dart';
import 'litert_lm_log_level.dart';
import 'npu_stacks.dart';

/// What a native `.litertlm` LLM load reaches outside Dart. Its NPU answers
/// are the same [LiteRtLmNpuHost] the EmbeddingGemma 2 placement asks, so
/// [chooseNpuVendor] runs over either.
class LiteRtLmEngineHost implements LiteRtLmNpuHost {
  const LiteRtLmEngineHost();

  static const _npu = LiteRtLmPlatformNpuHost();

  /// The directory LiteRT-LM keeps its caches in.
  Future<String> cacheDir() async =>
      (await getApplicationSupportDirectory()).path;

  @override
  String get operatingSystem => Platform.operatingSystem;

  @override
  String get abi => '${Abi.current()}';

  @override
  Future<NpuStackCheck> stack(NpuStack vendor) => _npu.stack(vendor);

  /// On Android it opens a vendor library.
  @override
  String? unreachable(NpuStack vendor) => _npu.unreachable(vendor);

  /// On Android it extracts the vendor's libraries out of the APK when the
  /// installer did not.
  @override
  Future<String> prepareDispatchDir(NpuStack vendor) =>
      _npu.prepareDispatchDir(vendor);

  /// A client for one backend attempt.
  LiteRtLmFfiClient createClient() => LiteRtLmFfiClient();

  /// Creates the engine in [client]: [LiteRtLmFfiClient.initialize].
  Future<void> initializeClient(
    LiteRtLmFfiClient client, {
    required String modelPath,
    required String backend,
    required int maxTokens,
    required String cacheDir,
    required bool enableVision,
    required String visionBackend,
    required int maxNumImages,
    required bool enableAudio,
    required String audioBackend,
    required bool? enableSpeculativeDecoding,
    required int? activationDataType,
    required NpuDispatch? npuDispatch,
    LiteRtLmLogLevel? nativeLogLevel,
    required int? thinkingTokenBudget,
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
    activationDataType: activationDataType,
    npuDispatch: npuDispatch,
    nativeLogLevel: nativeLogLevel,
    thinkingTokenBudget: thinkingTokenBudget,
  );
}

LiteRtLmEngineHost _host = const LiteRtLmEngineHost();

/// The host every native `.litertlm` LLM load goes through.
LiteRtLmEngineHost get liteRtLmEngineHost => _host;

/// Replaces [liteRtLmEngineHost]; null restores the real one.
@visibleForTesting
set debugLiteRtLmEngineHost(LiteRtLmEngineHost? host) =>
    _host = host ?? const LiteRtLmEngineHost();
