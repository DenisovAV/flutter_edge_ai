// The registration contract `FlutterEdgeAi.initialize()` makes to every engine
// package: an engine that implements HuggingFaceResolverSource has its resolver
// registered without a `huggingFaceResolvers:` entry; the explicit list is
// registered FIRST, so an app-supplied resolver wins the equal-priority tie and
// `resolveHuggingFace` reaches it; a `const` resolver passed both ways
// registers once. Driven through the full published `initialize()` path with a
// fake engine and fake resolvers, so it pins the contract rather than one
// engine. Each engine package checks only that its engine hands over its own
// resolver (flutter_edge_ai_litertlm: test/manifest/engine_carried_resolver_test.dart).
//
// Reproduction notes (each is the kind of thing the next person loses an
// hour to):
// - `initialize()` ends in the model manager's restore, which reads
//   shared_preferences. Under `flutter test` that plugin has no host, so the
//   call throws MissingPluginException — unless
//   `SharedPreferences.setMockInitialValues({})` runs first, which swaps in
//   the in-memory store and lets the whole init path complete headless.
// - `resolveHuggingFace` derives the platform key from
//   `defaultTargetPlatform`, so pin it (`debugDefaultTargetPlatformOverride`)
//   or the key the resolver sees depends on whichever host runs the suite.

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_edge_ai/src/api/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/src/model.dart' show ModelFileType;
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart'
    show EmbeddingPassDescriptor;
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show
        EmbeddingModelSpec,
        InferenceModelSpec,
        ModelManagementType,
        SttModelSpec,
        TtsModelSpec;
import 'package:flutter_edge_ai/src/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/stt_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/stt_registry.dart';
import 'package:flutter_edge_ai/src/registry/tts_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/tts_registry.dart';
import 'package:flutter_edge_ai/src/registry/engine_registry.dart';
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver.dart';
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver_source.dart';
import 'package:flutter_edge_ai/src/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/interface.dart'
    show InferenceModel, SpeechRecognizer, SpeechSynthesizer;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repo = 'org/repo';

/// Const-constructible fake resolver. Accepts every repo at priority 0 — the
/// tie every engine-carried resolver sits at — and answers with a row that
/// names itself and echoes the platform key it was handed, so a test can tell
/// which resolver `resolveHuggingFace` reached without a mutable counter (which
/// the `const` instance in the dedup case could not carry).
class _FakeResolver implements HuggingFaceResolver {
  const _FakeResolver(this.name, {this.type = ModelManagementType.inference});
  @override
  final String name;
  @override
  final ModelManagementType type;
  @override
  int get priority => 0;
  @override
  bool canResolve(String repo, {ModelFileType? fileType}) => true;
  @override
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  }) async => ResolvedHfModel(
    file: '$name.litertlm',
    url: 'fake://$name/$repo/$platform',
    fileType: ModelFileType.litertlm,
  );
}

/// Engine that opts into [HuggingFaceResolverSource] and contributes
/// [huggingFaceResolver] — the shape LiteRtLmEngine, OnnxEngine and
/// BuiltInAiEngine share.
class _FakeEngine
    implements InferenceEngineProvider, HuggingFaceResolverSource {
  const _FakeEngine(this.huggingFaceResolver);
  @override
  final HuggingFaceResolver huggingFaceResolver;
  @override
  String get name => 'fake-engine';
  @override
  int get priority => 0;
  @override
  bool canHandle(InferenceModelSpec spec) => false;
  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
}

/// Embedding backend that carries [huggingFaceResolver].
final class _FakeEmbeddingBackend extends EmbeddingBackendProvider
    implements HuggingFaceResolverSource {
  const _FakeEmbeddingBackend(this.huggingFaceResolver);
  @override
  final HuggingFaceResolver huggingFaceResolver;
  @override
  String get name => 'fake-embedding-backend';
  @override
  bool canHandle(EmbeddingModelSpec spec) => false;
  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
}

/// STT backend that carries [huggingFaceResolver].
class _FakeSttBackend implements SttBackendProvider, HuggingFaceResolverSource {
  const _FakeSttBackend(this.huggingFaceResolver);
  @override
  final HuggingFaceResolver huggingFaceResolver;
  @override
  String get name => 'fake-stt-backend';
  @override
  int get priority => 0;
  @override
  bool canHandle(SttModelSpec spec) => false;
  @override
  Future<SpeechRecognizer> createModel(
    SttModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
}

/// TTS backend that carries [huggingFaceResolver].
class _FakeTtsBackend implements TtsBackendProvider, HuggingFaceResolverSource {
  const _FakeTtsBackend(this.huggingFaceResolver);
  @override
  final HuggingFaceResolver huggingFaceResolver;
  @override
  String get name => 'fake-tts-backend';
  @override
  int get priority => 0;
  @override
  bool canHandle(TtsModelSpec spec) => false;
  @override
  Future<SpeechSynthesizer> createModel(
    TtsModelSpec spec,
    RuntimeConfig config,
  ) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    EngineRegistry.instance.reset();
    EmbeddingRegistry.instance.reset();
    SttRegistry.instance.reset();
    TtsRegistry.instance.reset();
    HuggingFaceResolverRegistry.instance.reset();
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    HuggingFaceResolverRegistry.instance.reset();
    EngineRegistry.instance.reset();
    EmbeddingRegistry.instance.reset();
    SttRegistry.instance.reset();
    TtsRegistry.instance.reset();
    ServiceRegistry.reset();
  });

  test(
    'registering an engine auto-registers the resolver it carries',
    () async {
      const carried = _FakeResolver('engine');
      await FlutterEdgeAi.initialize(
        inferenceEngines: const [_FakeEngine(carried)],
      );
      final registered = HuggingFaceResolverRegistry.instance.registered;
      expect(registered, hasLength(1));
      expect(registered.single, same(carried));
      expect(
        HuggingFaceResolverRegistry.instance.findFor(
          _repo,
          type: ModelManagementType.inference,
          fileType: ModelFileType.litertlm,
        ),
        same(carried),
      );
    },
  );

  test('an explicit resolver wins the equal-priority tie over the '
      'engine-carried one, and resolveHuggingFace reaches it', () async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [_FakeEngine(_FakeResolver('engine'))],
      huggingFaceResolvers: const [_FakeResolver('explicit')],
    );
    expect(HuggingFaceResolverRegistry.instance.registered.map((r) => r.name), [
      'explicit',
      'engine',
    ], reason: 'explicit list first, engine-carried second');

    final r = await FlutterEdgeAi.resolveHuggingFace(
      _repo,
      fileType: ModelFileType.litertlm,
    );
    expect(r.file, 'explicit.litertlm');
    // The platform key comes from defaultTargetPlatform, pinned in setUp.
    expect(r.url, 'fake://explicit/$_repo/macos');
  });

  test('a const resolver passed both explicitly and via the engine registers '
      'once', () async {
    const shared = _FakeResolver('shared');
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [_FakeEngine(shared)],
      huggingFaceResolvers: const [shared],
    );
    final registered = HuggingFaceResolverRegistry.instance.registered;
    expect(registered, hasLength(1));
    expect(registered.single, same(shared));
  });

  test('an embedding backend auto-registers the resolver it carries, which '
      'resolveHuggingFace reaches only for the embedding role', () async {
    const carried = _FakeResolver(
      'embedder',
      type: ModelManagementType.embedding,
    );
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [_FakeEngine(_FakeResolver('llm'))],
      embeddingBackends: const [_FakeEmbeddingBackend(carried)],
    );
    expect(HuggingFaceResolverRegistry.instance.registered.map((r) => r.name), [
      'llm',
      'embedder',
    ]);
    final asEmbedder = await FlutterEdgeAi.resolveHuggingFace(
      _repo,
      type: ModelManagementType.embedding,
      fileType: ModelFileType.litertlm,
    );
    expect(asEmbedder.file, 'embedder.litertlm');
    final asLlm = await FlutterEdgeAi.resolveHuggingFace(
      _repo,
      fileType: ModelFileType.litertlm,
    );
    expect(asLlm.file, 'llm.litertlm');
  });

  test('an explicit resolver wins the tie within its role over a '
      'backend-carried one', () async {
    await FlutterEdgeAi.initialize(
      embeddingBackends: const [
        _FakeEmbeddingBackend(
          _FakeResolver('carried', type: ModelManagementType.embedding),
        ),
      ],
      huggingFaceResolvers: const [
        _FakeResolver('explicit', type: ModelManagementType.embedding),
      ],
    );
    final r = await FlutterEdgeAi.resolveHuggingFace(
      _repo,
      type: ModelManagementType.embedding,
      fileType: ModelFileType.litertlm,
    );
    expect(r.file, 'explicit.litertlm');
  });

  test('a provider whose resolver serves another role is refused, naming '
      'the provider, and nothing is registered', () async {
    await expectLater(
      FlutterEdgeAi.initialize(
        huggingFaceResolvers: const [_FakeResolver('explicit')],
        sttBackends: const [_FakeSttBackend(_FakeResolver('wrong-role'))],
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('_FakeSttBackend'), contains('sttBackends')),
        ),
      ),
    );
    expect(HuggingFaceResolverRegistry.instance.registered, isEmpty);
    expect(SttRegistry.instance.hasAny, isFalse);
  });

  test('a TTS backend carrying a tts resolver registers it; one carrying '
      'another role is refused, naming ttsBackends', () async {
    const tts = _FakeResolver('voice', type: ModelManagementType.tts);
    await FlutterEdgeAi.initialize(ttsBackends: const [_FakeTtsBackend(tts)]);
    expect(HuggingFaceResolverRegistry.instance.registered.single, same(tts));
    final r = await FlutterEdgeAi.resolveHuggingFace(
      _repo,
      type: ModelManagementType.tts,
      fileType: ModelFileType.litertlm,
    );
    expect(r.file, 'voice.litertlm');

    HuggingFaceResolverRegistry.instance.reset();
    TtsRegistry.instance.reset();
    ServiceRegistry.reset();
    for (final role in [
      ModelManagementType.inference,
      ModelManagementType.embedding,
      ModelManagementType.stt,
    ]) {
      await expectLater(
        FlutterEdgeAi.initialize(
          ttsBackends: [_FakeTtsBackend(_FakeResolver('wrong', type: role))],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('_FakeTtsBackend'), contains('ttsBackends')),
          ),
        ),
        reason: '$role',
      );
      expect(HuggingFaceResolverRegistry.instance.registered, isEmpty);
      expect(TtsRegistry.instance.hasAny, isFalse);
    }
  });

  test('an embedding backend carrying a resolver of another role is '
      'refused, naming embeddingBackends', () async {
    for (final role in [
      ModelManagementType.inference,
      ModelManagementType.stt,
      ModelManagementType.tts,
    ]) {
      await expectLater(
        FlutterEdgeAi.initialize(
          embeddingBackends: [
            _FakeEmbeddingBackend(_FakeResolver('wrong', type: role)),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('_FakeEmbeddingBackend'),
              contains('embeddingBackends'),
            ),
          ),
        ),
        reason: '$role',
      );
      expect(HuggingFaceResolverRegistry.instance.registered, isEmpty);
      expect(EmbeddingRegistry.instance.hasAny, isFalse);
    }
  });

  test('an engine whose resolver is not an inference one is refused', () {
    expect(
      () => FlutterEdgeAi.engineHuggingFaceResolvers(const [
        _FakeEngine(
          _FakeResolver('embedder', type: ModelManagementType.embedding),
        ),
      ]),
      throwsStateError,
    );
  });
}
