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

  test('awaited TTS activation sets activeTtsModel in memory', () async {
    final m = MobileModelManager();
    await m.activateInstalledModel(_spec());
    expect(m.activeTtsModel, isA<TtsModelSpec>());
    expect(
      (m.activeTtsModel as TtsModelSpec).ttsModelType,
      TtsModelType.matcha,
    );
  });

  test('awaited TTS activation persists the 2 identity keys', () async {
    final m = MobileModelManager();
    await m.activateInstalledModel(_spec());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PreferencesKeys.activeTtsName), 'matcha');
    expect(
      prefs.getString(PreferencesKeys.activeTtsModelType),
      TtsModelType.matcha.name,
    );
  });
}
