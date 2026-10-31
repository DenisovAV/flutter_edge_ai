import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmEngineCreateException, LiteRtLmLogLevel;
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// `litert_lm_engine_settings_create` took 81 ms on the calling isolate of an
/// S25 Ultra, just before `initialize` spawned the engine's isolate, and a
/// frame started 98 ms late around it. The settings are now made, applied,
/// used and freed on the engine's isolate, reached through
/// [createEngineOffMainIsolate].
///
/// These tests give the client bindings whose every lookup is recorded and
/// throws, and replace the isolate seam, so what they can see is that
/// `initialize` resolves no native symbol at all on the isolate it is called
/// on, and that everything the settings are made from reaches the other one.
/// What they cannot see is the timing: that needs a phone.
void main() {
  late Future<EngineCreateResult> Function(EngineCreateRequest) originalCreate;
  late EdgeAiLogLevel originalLogLevel;
  late List<String> callingIsolateLookups;
  late List<EngineCreateRequest> requests;

  LiteRtLmFfiClient clientWithoutNativeLibrary() {
    Pointer<T> lookup<T extends NativeType>(String symbol) {
      callingIsolateLookups.add(symbol);
      throw ArgumentError('no native library on the test host: $symbol');
    }

    return LiteRtLmFfiClient()
      ..bindingsForTest = LiteRtLmBindings.fromLookup(lookup);
  }

  EngineCreateResult engineAt(int address) =>
      (address: address, code: 0, message: null, banks: null);

  /// Runs [body] with its prints kept out of the test output: a model path
  /// with no file behind it makes the bundle-sampler read print a warning.
  Future<T> quietly<T>(Future<T> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
  );

  setUp(() {
    originalCreate = createEngineOffMainIsolate;
    originalLogLevel = edgeAiLogLevel;
    callingIsolateLookups = [];
    requests = [];
    createEngineOffMainIsolate = (request) async {
      requests.add(request);
      return engineAt(0xE9E);
    };
  });

  tearDown(() {
    createEngineOffMainIsolate = originalCreate;
    edgeAiLogLevel = originalLogLevel;
  });

  test('initialize makes the engine settings on the engine isolate, and '
      'calls nothing native on its own', () async {
    final client = clientWithoutNativeLibrary();

    await quietly(
      () => client.initialize(
        modelPath: '/models/gemma.litertlm',
        nativeLogLevel: LiteRtLmLogLevel.error,
      ),
    );

    expect(
      callingIsolateLookups,
      isEmpty,
      reason:
          'settings_create, its setters, set_min_log_level, engine_create and '
          'settings_delete all belong to the engine isolate; a symbol resolved '
          'here is a native call on the UI thread',
    );
    expect(requests, hasLength(1));
    expect(client.isInitialized, isTrue);
  });

  test('the request carries every argument initialize was given', () async {
    edgeAiLogLevel = EdgeAiLogLevel.verbose;

    await quietly(
      () => clientWithoutNativeLibrary().initialize(
        modelPath: '/models/gemma.litertlm',
        backend: 'cpu',
        maxTokens: 4096,
        cacheDir: '/cache',
        enableVision: true,
        visionBackend: 'gpu',
        maxNumImages: 2,
        audioBackend: 'gpu',
        enableSpeculativeDecoding: false,
        activationDataType: 0,
        nativeLogLevel: LiteRtLmLogLevel.warning,
      ),
    );

    final request = requests.single;
    expect(request.modelPath, '/models/gemma.litertlm');
    expect(request.backend, 'cpu');
    expect(request.maxTokens, 4096);
    expect(request.cacheDir, '/cache');
    expect(request.visionBackend, 'gpu');
    expect(
      request.audioBackend,
      isNull,
      reason: 'audio was not enabled, so no audio encoder is asked for',
    );
    expect(request.maxNumImages, 2);
    expect(request.enableSpeculativeDecoding, isFalse);
    expect(
      request.activationDataType,
      0,
      reason:
          'float32, the fix for wrong digits on some GPUs; dropped on the way '
          'to the isolate, the engine would silently run float16',
    );
    expect(request.nativeLogLevel, LiteRtLmLogLevel.warning);
    expect(
      request.logLevel,
      EdgeAiLogLevel.verbose,
      reason: "a spawned isolate starts at the default level, not the caller's",
    );
    expect(request.dispatchLibDir, isNull, reason: 'not the NPU');
    expect(request.disableHwMaskingForNpu, isFalse);
    expect(request.listWeightBanks, isFalse);
    expect(request.blockSigprof, isFalse);
    expect(
      request.kernelBatchSize,
      isNull,
      reason: 'set on the Android GPU only, and this is neither',
    );
  });

  test('what was not asked for stays null', () async {
    await quietly(
      () => clientWithoutNativeLibrary().initialize(
        modelPath: '/models/gemma.litertlm',
      ),
    );

    final request = requests.single;
    expect(
      request.activationDataType,
      isNull,
      reason: 'none asked for, so the engine keeps its own choice',
    );
    expect(request.nativeLogLevel, isNull);
    expect(request.enableSpeculativeDecoding, isNull);
    expect(request.cacheDir, isNull);
    expect(request.visionBackend, isNull);
    expect(request.audioBackend, isNull);
    expect(request.maxNumImages, 0);
  });

  test('the NPU vendor\'s dispatch reaches the request', () async {
    await quietly(
      () => clientWithoutNativeLibrary().initialize(
        modelPath: '/models/gemma.litertlm',
        backend: 'npu',
        npuDispatch: (
          dir: '/vendor/dispatch',
          disableHwMasking: true,
          stagesWeightBanks: true,
        ),
      ),
    );

    final request = requests.single;
    expect(request.backend, 'npu');
    expect(request.dispatchLibDir, '/vendor/dispatch');
    expect(request.disableHwMaskingForNpu, isTrue);
    expect(request.listWeightBanks, isTrue);
    expect(
      request.blockSigprof,
      Platform.isLinux,
      reason: "QNN's init fails under the debug VM's SIGPROF on Linux only",
    );
  });

  test('a NULL engine fails initialize with the model path, and nothing is '
      'freed on the calling isolate', () async {
    createEngineOffMainIsolate = (request) async => engineAt(0);
    final client = clientWithoutNativeLibrary();

    await expectLater(
      quietly(() => client.initialize(modelPath: '/models/broken.litertlm')),
      throwsA(
        isA<LiteRtLmEngineCreateException>().having(
          (e) => e.message,
          'message',
          contains('Model: /models/broken.litertlm'),
        ),
      ),
    );
    expect(
      callingIsolateLookups,
      isEmpty,
      reason:
          'the settings used to be deleted here after the engine isolate '
          'returned; they are freed on that isolate now, success or not',
    );
    expect(client.isInitialized, isFalse);
  });

  test('the request crosses to a spawned isolate intact', () async {
    const request = EngineCreateRequest(
      modelPath: '/models/gemma.litertlm',
      backend: 'npu',
      maxTokens: 1024,
      logLevel: EdgeAiLogLevel.none,
      visionBackend: 'cpu',
      audioBackend: 'gpu',
      cacheDir: '/cache',
      maxNumImages: 3,
      enableSpeculativeDecoding: true,
      activationDataType: 1,
      nativeLogLevel: LiteRtLmLogLevel.silent,
      dispatchLibDir: '/lib/arm64',
      disableHwMaskingForNpu: true,
      kernelBatchSize: 2,
      blockSigprof: true,
      listWeightBanks: true,
    );

    final copy = await Isolate.run(() => request);

    expect(copy.modelPath, request.modelPath);
    expect(copy.backend, request.backend);
    expect(copy.maxTokens, request.maxTokens);
    expect(copy.logLevel, request.logLevel);
    expect(copy.visionBackend, request.visionBackend);
    expect(copy.audioBackend, request.audioBackend);
    expect(copy.cacheDir, request.cacheDir);
    expect(copy.maxNumImages, request.maxNumImages);
    expect(copy.enableSpeculativeDecoding, request.enableSpeculativeDecoding);
    expect(copy.activationDataType, request.activationDataType);
    expect(copy.nativeLogLevel, request.nativeLogLevel);
    expect(copy.dispatchLibDir, request.dispatchLibDir);
    expect(copy.disableHwMaskingForNpu, request.disableHwMaskingForNpu);
    expect(copy.kernelBatchSize, request.kernelBatchSize);
    expect(copy.blockSigprof, request.blockSigprof);
    expect(copy.listWeightBanks, request.listWeightBanks);
  });
}
