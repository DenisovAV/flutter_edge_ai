import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

TtsModelSpec _spec() => TtsModelSpec.fromManifest(
  name: 'matcha',
  ttsModelType: TtsModelType.matcha,
  sourceFor: (fn) => ModelSource.network('https://x/$fn'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'setActiveModel(TtsModelSpec) sets activeTtsModel in memory (no throw)',
    () {
      final m = MobileModelManager();
      m.setActiveModel(_spec()); // must NOT throw ArgumentError
      expect(m.activeTtsModel, isA<TtsModelSpec>());
      expect(
        (m.activeTtsModel as TtsModelSpec).ttsModelType,
        TtsModelType.matcha,
      );
    },
  );

  test('setActiveModel persists the 2 TTS identity keys', () async {
    final m = MobileModelManager();
    m.setActiveModel(_spec());
    // fire-and-forget persist — let the microtask/IO settle
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PreferencesKeys.activeTtsName), 'matcha');
    expect(
      prefs.getString(PreferencesKeys.activeTtsModelType),
      TtsModelType.matcha.name,
    );
  });
}
