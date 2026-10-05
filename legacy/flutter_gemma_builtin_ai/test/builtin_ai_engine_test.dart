// The engine is the part core talks to: it decides which specs it claims, it
// refuses what the OS model cannot do, and it builds the model. Everything
// below the factory now belongs to flutter_local_ai, so these tests assert the
// routing and the refusals rather than any channel traffic.

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_gemma/core/domain/model_source.dart' show ModelSource;
import 'package:flutter_gemma/core/model.dart' show ModelFileType, ModelType;
import 'package:flutter_gemma/core/registry/runtime_config.dart'
    show RuntimeConfig;
import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart';
import 'package:flutter_local_ai/flutter_local_ai.dart' show debugLocalAiHost;
import 'package:flutter_local_ai/testing.dart' show FakeLocalAiHost;
import 'package:flutter_test/flutter_test.dart';

import 'adapter_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLocalAiHost host;

  setUp(() {
    host = FakeLocalAiHost();
    debugLocalAiHost = host;
  });

  tearDown(() async {
    debugLocalAiHost = null;
    await host.dispose();
  });

  test('engine identity', () {
    const engine = BuiltInAiEngine();
    expect(engine.name, 'BuiltInAI');
    expect(engine.priority, 0);
  });

  test('engine carries the built-in HuggingFace resolver', () {
    // Auto-registered by `FlutterGemma.initialize(inferenceEngines: …)`,
    // which is what reserves the `.builtIn` Hugging Face slot.
    expect(
      const BuiltInAiEngine().huggingFaceResolver,
      isA<BuiltInAiHuggingFaceResolver>(),
    );
  });

  test('canHandle matches only builtIn specs', () {
    const engine = BuiltInAiEngine();
    expect(engine.canHandle(BuiltInAiModels.geminiNano), isTrue);
    expect(engine.canHandle(BuiltInAiModels.appleFoundationModels), isTrue);
    // Core routes by canHandle, so declining every other declared file type IS
    // how the engine refuses a spec that belongs elsewhere. Iterating
    // ModelFileType.values keeps this exhaustive if a new value is added.
    for (final fileType in ModelFileType.values) {
      if (fileType == ModelFileType.builtIn) continue;
      expect(
        engine.canHandle(builtInSpec(fileType: fileType)),
        isFalse,
        reason: '$fileType belongs to another engine',
      );
    }
  });

  test('specs carry inert bundled source', () {
    expect(
      BuiltInAiModels.geminiNano.modelSource,
      ModelSource.bundled('gemini-nano'),
    );
    expect(BuiltInAiModels.geminiNano.fileType, ModelFileType.builtIn);
    expect(BuiltInAiModels.geminiNano.name, 'gemini-nano');
    expect(BuiltInAiModels.geminiNano.modelType, ModelType.general);
    expect(
      BuiltInAiModels.appleFoundationModels.name,
      'apple-foundation-models',
    );
    expect(
      BuiltInAiModels.appleFoundationModels.modelSource,
      ModelSource.bundled('apple-foundation-models'),
    );
    expect(
      BuiltInAiModels.appleFoundationModels.fileType,
      ModelFileType.builtIn,
    );
  });

  group('createModel', () {
    test('refuses audio before touching the host', () async {
      await expectLater(
        const BuiltInAiEngine().createModel(
          builtInSpec(),
          const RuntimeConfig(
            maxTokens: 4096,
            modelPath: '',
            supportAudio: true,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(host.calls, isEmpty);
    });

    test('refuses LoRA ranks before touching the host', () async {
      await expectLater(
        const BuiltInAiEngine().createModel(
          builtInSpec(),
          const RuntimeConfig(
            maxTokens: 4096,
            modelPath: '',
            loraRanks: [4, 8],
          ),
        ),
        throwsUnsupportedError,
      );
      expect(host.calls, isEmpty);
    });

    // Linux has no OS model; createModel must fail with the package's own
    // exception and the true reason, without asking the host to build one.
    test('refuses to build a model on Linux', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await expectLater(
        const BuiltInAiEngine().createModel(builtInSpec(), builtInConfig),
        throwsA(
          isA<BuiltInAiUnavailableException>().having(
            (e) => e.status,
            'status',
            BuiltInAiAvailability.unavailableDeviceUnsupported,
          ),
        ),
      );
      expect(host.calls, isNot(contains('createModel')));
    });

    test('refuses to build a model the OS is not ready to run', () async {
      host.availability = BuiltInAiAvailability.unavailableDisabled;

      await expectLater(
        const BuiltInAiEngine().createModel(builtInSpec(), builtInConfig),
        throwsA(
          isA<BuiltInAiUnavailableException>().having(
            (e) => e.status,
            'status',
            BuiltInAiAvailability.unavailableDisabled,
          ),
        ),
      );
      // Readiness is a hard precondition, not something to wait out here.
      expect(host.calls, isNot(contains('createModel')));
    });

    test('builds a model carrying the runtime config', () async {
      final model = await const BuiltInAiEngine().createModel(
        builtInSpec(),
        builtInConfig,
      );
      addTearDown(model.close);

      expect(model.maxTokens, 4096);
      expect(model.fileType, ModelFileType.builtIn);
      // The OS picks its own accelerator and does not report which.
      expect(model.activeBackend, isNull);
      expect(host.modelSupportsImage, isFalse);
    });

    test('asks the host for the multimodal path only when images are '
        'configured', () async {
      final model = await const BuiltInAiEngine().createModel(
        builtInSpec(),
        const RuntimeConfig(maxTokens: 4096, modelPath: '', supportImage: true),
      );
      addTearDown(model.close);

      expect(host.modelSupportsImage, isTrue);
    });
  });
}
