import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/stt_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/stt_registry.dart';
import 'package:flutter_edge_ai/core/registry/tts_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/tts_registry.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _resetAll();
  });

  tearDown(_resetAll);

  test('dispose resets core services', () async {
    await ServiceRegistry.initialize();
    expect(ServiceRegistry.instance, isNotNull);

    await FlutterEdgeAi.dispose();

    expect(() => ServiceRegistry.instance, throwsStateError);
  });

  test('dispose clears every provider registry', () async {
    EngineRegistry.instance.registerAll([_MockInferenceEngine()]);
    EmbeddingRegistry.instance.registerAll([_MockEmbeddingBackend()]);
    EmbeddingTokenizerRegistry.instance.registerAll([_MockTokenizer()]);
    SttRegistry.instance.registerAll([_MockSttBackend()]);
    TtsRegistry.instance.registerAll([_MockTtsBackend()]);
    SkillExecutorRegistry.instance.registerAll([_MockSkillExecutor()]);
    HuggingFaceResolverRegistry.instance.registerAll([_MockResolver()]);

    await FlutterEdgeAi.dispose();

    expect(EngineRegistry.instance.registered, isEmpty);
    expect(EmbeddingRegistry.instance.registered, isEmpty);
    expect(EmbeddingTokenizerRegistry.instance.registered, isEmpty);
    expect(SttRegistry.instance.registered, isEmpty);
    expect(TtsRegistry.instance.registered, isEmpty);
    expect(SkillExecutorRegistry.instance.registered, isEmpty);
    expect(HuggingFaceResolverRegistry.instance.registered, isEmpty);
  });
}

void _resetAll() {
  ServiceRegistry.reset();
  EngineRegistry.instance.reset();
  EmbeddingRegistry.instance.reset();
  EmbeddingTokenizerRegistry.instance.reset();
  SttRegistry.instance.reset();
  TtsRegistry.instance.reset();
  SkillExecutorRegistry.instance.reset();
  HuggingFaceResolverRegistry.instance.reset();
}

class _MockInferenceEngine extends Mock implements InferenceEngineProvider {}

class _MockEmbeddingBackend extends Mock implements EmbeddingBackendProvider {}

class _MockTokenizer extends Mock implements EmbeddingTokenizerProvider {}

class _MockSttBackend extends Mock implements SttBackendProvider {}

class _MockTtsBackend extends Mock implements TtsBackendProvider {}

class _MockSkillExecutor extends Mock implements SkillExecutorProvider {}

class _MockResolver extends Mock implements HuggingFaceResolver {}
