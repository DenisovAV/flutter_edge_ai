// `getActiveEmbedder`, `getActiveStt` and `getActiveTts` take
// `defaults: ModelRuntimeDefaults` as `getActiveModel` does: an explicit
// argument wins over the matching default, which wins over the SDK default,
// and each call reads only the fields of its role. Driven through the public
// calls with a plugin that records what reached it, so nothing loads.
//
// Run: flutter test test/core/api/role_runtime_defaults_test.dart

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../catalog/catalog_fixtures.dart';

void main() {
  late FlutterEdgeAiPlugin previous;
  late _RecordingPlugin plugin;

  setUp(() {
    previous = FlutterEdgeAiPlugin.instance;
    plugin = _RecordingPlugin(_ActiveModels());
    FlutterEdgeAiPlugin.instance = plugin;
  });

  tearDown(() => FlutterEdgeAiPlugin.instance = previous);

  const defaults = ModelRuntimeDefaults(
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: true,
    language: 'de',
    maxTokens: 4096,
  );

  group('getActiveEmbedder', () {
    test('defaults apply where no argument is given', () async {
      await expectLater(
        FlutterEdgeAi.getActiveEmbedder(defaults: defaults),
        throwsA(isA<_Reached>()),
      );
      expect(plugin.calls.single, {
        'preferredBackend': PreferredBackend.gpu,
        'supportImage': true,
        'supportAudio': true,
      });
    });

    test('an explicit argument wins over the default', () async {
      await expectLater(
        FlutterEdgeAi.getActiveEmbedder(
          defaults: defaults,
          preferredBackend: PreferredBackend.cpu,
          supportImage: false,
          supportAudio: false,
        ),
        throwsA(isA<_Reached>()),
      );
      expect(plugin.calls.single, {
        'preferredBackend': PreferredBackend.cpu,
        'supportImage': false,
        'supportAudio': false,
      });
    });

    test('without defaults the SDK defaults hold', () async {
      await expectLater(
        FlutterEdgeAi.getActiveEmbedder(),
        throwsA(isA<_Reached>()),
      );
      expect(plugin.calls.single, {
        'preferredBackend': null,
        'supportImage': false,
        'supportAudio': false,
      });
    });
  });

  group('getActiveStt', () {
    test('defaults apply where no argument is given', () async {
      await expectLater(
        FlutterEdgeAi.getActiveStt(defaults: defaults),
        throwsA(isA<_Reached>()),
      );
      expect(plugin.calls.single, {
        'preferredBackend': PreferredBackend.gpu,
        'language': 'de',
      });
    });

    test('an explicit argument wins over the default', () async {
      await expectLater(
        FlutterEdgeAi.getActiveStt(
          defaults: defaults,
          preferredBackend: PreferredBackend.cpu,
          language: 'fr',
        ),
        throwsA(isA<_Reached>()),
      );
      expect(plugin.calls.single, {
        'preferredBackend': PreferredBackend.cpu,
        'language': 'fr',
      });
    });
  });

  group('getActiveTts', () {
    test('defaults apply where no argument is given', () async {
      await expectLater(
        FlutterEdgeAi.getActiveTts(defaults: defaults),
        throwsA(isA<_Reached>()),
      );
      expect(plugin.calls.single, {
        'preferredBackend': PreferredBackend.gpu,
        'language': 'de',
      });
    });

    test('an explicit argument wins over the default', () async {
      await expectLater(
        FlutterEdgeAi.getActiveTts(
          defaults: defaults,
          preferredBackend: PreferredBackend.cpu,
          language: 'english',
        ),
        throwsA(isA<_Reached>()),
      );
      expect(plugin.calls.single, {
        'preferredBackend': PreferredBackend.cpu,
        'language': 'english',
      });
    });
  });

  group('catalog variants', () {
    test('an embedder variant opens on its own backend by default', () {
      final variant = TestEmbedder(model: artifact('tiny.tflite'));
      expect(variant.runtimeDefaults.preferredBackend, isNull);
      final npu = _NpuEmbedder(model: artifact('tiny_npu.tflite'));
      expect(npu.runtimeDefaults.preferredBackend, PreferredBackend.npu);
    });

    test('STT and TTS variants carry the SDK defaults by default', () {
      for (final d in [TestStt().runtimeDefaults, TestTts().runtimeDefaults]) {
        expect(d.preferredBackend, isNull);
        expect(d.language, isNull);
      }
    });
  });
}

/// What [_RecordingPlugin] throws once it has recorded a call.
final class _Reached implements Exception {}

/// A plugin whose model manager has an active model of every kind, and whose
/// create calls record their arguments, then throw [_Reached].
final class _RecordingPlugin extends FlutterEdgeAiPlugin {
  _RecordingPlugin(this.modelManager);

  @override
  final ModelFileManager modelManager;

  final calls = <Map<String, Object?>>[];

  @override
  Future<EmbeddingModel> createEmbeddingModel({
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    bool supportAudio = false,
  }) async {
    calls.add({
      'preferredBackend': preferredBackend,
      'supportImage': supportImage,
      'supportAudio': supportAudio,
    });
    throw _Reached();
  }

  @override
  Future<SpeechRecognizer> createSttModel({
    String? modelPath,
    String? tokenizerPath,
    PreferredBackend? preferredBackend,
    String? language,
  }) async {
    calls.add({'preferredBackend': preferredBackend, 'language': language});
    throw _Reached();
  }

  @override
  Future<SpeechSynthesizer> createTtsModel({
    PreferredBackend? preferredBackend,
    String? language,
  }) async {
    calls.add({'preferredBackend': preferredBackend, 'language': language});
    throw _Reached();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A model manager with an active embedder, STT and TTS model.
final class _ActiveModels extends ModelFileManager {
  @override
  ModelSpec? get activeEmbeddingModel => EmbeddingModelSpec(
    name: 'eg2',
    modelSource: ModelSource.network('https://example.com/eg2.litertlm'),
  );

  @override
  ModelSpec? get activeSttModel => SttModelSpec(
    name: 'whisper',
    modelSource: ModelSource.network('https://example.com/whisper.tflite'),
    tokenizerSource: ModelSource.network('https://example.com/vocab.json'),
    sttModelType: SttModelType.whisper,
  );

  @override
  ModelSpec? get activeTtsModel => TtsModelSpec.fromManifest(
    name: 'qwen3',
    ttsModelType: TtsModelType.qwen3,
    sourceFor: (f) => ModelSource.network('https://example.com/$f'),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An embedder variant compiled for an NPU.
final class _NpuEmbedder extends EmbedderVariant {
  _NpuEmbedder({required this.model});

  @override
  final ModelArtifact model;

  @override
  ModelArtifact? get tokenizer => null;

  @override
  PreferredBackend? get preferredBackend => PreferredBackend.npu;

  @override
  String get ragProfileId => 'tiny-embedder-npu-v1';

  @override
  String get id => 'tiny-embedder/npu';

  @override
  String get modelId => 'tiny-embedder';

  @override
  String get catalogName => 'test_catalog';

  @override
  Set<PreferredBackend> get backendsHere => const {PreferredBackend.npu};

  @override
  int get dimension => 768;

  @override
  int get maxInputTokens => 256;

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};
}
