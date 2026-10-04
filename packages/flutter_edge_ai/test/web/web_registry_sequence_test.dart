// Verifies the web engine-registration probe (host VM, no browser): with both
// opt-in web engines registered (as the example does via
// inferenceEngines: [LiteRtLmEngine(), MediaPipeEngine()]), the registry routes
// .litertlm → the litertlm engine and .task → MediaPipe, neither throwing.
//
// NOTE: core registers NO default engine (fully opt-in as of 1.0). There is no
// "suppress the core default" one-shot flag anymore — both engines are
// explicitly registered, and findFor just probes by fileType.

import 'package:flutter_edge_ai/core/model.dart' show ModelFileType, ModelType;
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart' show InferenceModel;
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show InferenceModelSpec;
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the FIXED web litertlm engine: canHandle(.litertlm) true + builds
/// (here records via a sentinel instead of a real JS model).
class _RealLiteRtLmWebEngine implements InferenceEngineProvider {
  const _RealLiteRtLmWebEngine();
  @override
  String get name => 'LiteRT-LM';
  @override
  int get priority => 0;
  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.litertlm;
  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async => throw _LiteRtLmReached();
}

class _LiteRtLmReached implements Exception {}

class _CoreMediaPipe implements InferenceEngineProvider {
  const _CoreMediaPipe();
  @override
  String get name => 'MediaPipe';
  @override
  int get priority => 0;
  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.task ||
      spec.fileType == ModelFileType.binary;
  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async => throw _MediaPipeReached();
}

class _MediaPipeReached implements Exception {}

InferenceModelSpec _spec(ModelFileType ft) => InferenceModelSpec(
  name: 'web',
  modelSource: AssetSource('models/active.bin'),
  modelType: ModelType.general,
  fileType: ft,
);

void main() {
  setUp(() => EngineRegistry.instance.reset());

  test('with both web engines registered, .task resolves to MediaPipe '
      '(and the litertlm engine does not capture it)', () async {
    // The example registers both opt-in web engines:
    //   initialize(inferenceEngines: [LiteRtLmEngine(), MediaPipeEngine()]).
    EngineRegistry.instance.registerAll(const [
      _RealLiteRtLmWebEngine(),
      _CoreMediaPipe(),
    ]);
    // .task probe → MediaPipe (the litertlm engine only handles .litertlm).
    final taskEngine = EngineRegistry.instance.findFor(
      _spec(ModelFileType.task),
    );
    expect(
      taskEngine,
      isNotNull,
      reason: 'MediaPipe must be selected for .task',
    );
    await expectLater(
      () => taskEngine!.createModel(
        _spec(ModelFileType.task),
        const RuntimeConfig(maxTokens: 1, modelPath: ''),
      ),
      throwsA(isA<_MediaPipeReached>()),
      reason: '.task routes to MediaPipe',
    );
  });

  test('.litertlm resolves to the REAL litertlm engine (builds, does not '
      'throw UnsupportedError)', () async {
    EngineRegistry.instance.registerAll(const [_RealLiteRtLmWebEngine()]);
    final engine = EngineRegistry.instance.findFor(
      _spec(ModelFileType.litertlm),
    );
    expect(engine, isNotNull);
    expect(engine!.name, 'LiteRT-LM');
    await expectLater(
      () => engine.createModel(
        _spec(ModelFileType.litertlm),
        const RuntimeConfig(maxTokens: 1, modelPath: ''),
      ),
      throwsA(
        isA<_LiteRtLmReached>(),
      ), // reaches the real build path (sentinel), NOT UnsupportedError
      reason:
          '.litertlm routes to the real litertlm engine, which builds (not throws-unsupported)',
    );
  });
}
