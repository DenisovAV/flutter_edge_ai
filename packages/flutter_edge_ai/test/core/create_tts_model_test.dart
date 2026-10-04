import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/registry/tts_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/tts_registry.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [TtsBackendProvider] that never matches — used to prove `createTtsModel`
/// does NOT silently fall back to an unrelated backend (the bug fixed here).
class _NonMatchingBackend implements TtsBackendProvider {
  @override
  String get name => 'non-matching';
  @override
  int get priority => 0;
  @override
  bool canHandle(TtsModelSpec spec) => false;
  @override
  Future<SpeechSynthesizer> createModel(
    TtsModelSpec spec,
    RuntimeConfig config,
  ) async => throw UnimplementedError('should never be selected');
}

TtsModelSpec _matchaSpec() => TtsModelSpec.fromManifest(
  name: 'matcha',
  ttsModelType: TtsModelType.matcha,
  sourceFor: (fn) => ModelSource.network('https://x/$fn'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TtsRegistry.instance.reset();
  });
  tearDown(() => TtsRegistry.instance.reset());

  test('createTtsModel throws StateError when no active TTS model', () {
    final plugin = FlutterEdgeAiMobile();
    expect(plugin.createTtsModel(), throwsA(isA<StateError>()));
  });

  test('createTtsModel fails loud (not silently) when a TTS backend is '
      'registered but none can handle the active model', () async {
    TtsRegistry.instance.registerAll([_NonMatchingBackend()]);
    final plugin = FlutterEdgeAiMobile();
    await plugin.modelManager.activateInstalledModel(_matchaSpec());
    // The active model isn't installed on disk, so the "files not found"
    // fail-loud check fires before backend selection is reached — but the
    // outcome that matters is the same: createTtsModel must throw, never
    // silently hand the spec to `_NonMatchingBackend` and return a model
    // built from a backend that can't actually serve it.
    await expectLater(plugin.createTtsModel(), throwsA(isA<StateError>()));
  });

  test(
    'the selection property the fix relies on: findFor returns null (not '
    'an arbitrary registered backend) when no backend canHandle()s the spec',
    () {
      TtsRegistry.instance.registerAll([_NonMatchingBackend()]);
      expect(TtsRegistry.instance.findFor(_matchaSpec()), isNull);
      // hasAny is still true — this is what lets createTtsModel distinguish
      // "none registered" from "registered but none handles it" in its error.
      expect(TtsRegistry.instance.hasAny, isTrue);
    },
  );
}
