// The active-identity writes must land as one uninterruptible burst (#468).
//
// WebModelManager pulls in dart:js_interop and cannot load on the VM, so this
// runs in a browser and `tool/test_all.sh` (VM only) does not pick it up:
//   flutter test test/web/web_identity_write_atomicity_test.dart --platform chrome
@TestOn('browser')
library;

import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

InferenceModelSpec _spec(String name) => InferenceModelSpec(
  name: name,
  modelSource: ModelSource.network('https://x/$name.litertlm'),
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a reader right after setActiveModel sees the whole identity', () async {
    // The #468 shape: every web engine builds a FRESH manager per createModel
    // via WebModelSourceResolver.forActiveModel(), which rehydrates from prefs.
    // setActiveModel is `void` and can only start the writes, so a reader in a
    // later microtask used to catch them half-done -- measured, one key of four
    // -- and threw "No active inference model set" over a model that had just
    // installed successfully.
    //
    // Asserted on prefs rather than on `activeInferenceModel`, which also needs
    // the model FILE present; the four identity keys are what the writes own.
    WebModelManager().setActiveModel(_spec('gemma'));

    await WebModelManager().ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PreferencesKeys.activeInferenceModelType), isNotNull);
    expect(prefs.getString(PreferencesKeys.activeInferenceFileType), isNotNull);
    expect(prefs.getString(PreferencesKeys.activeInferenceFilename), isNotNull);
    expect(prefs.getString(PreferencesKeys.activeInferenceSource), isNotNull);
  });

  test('a re-install is never observable half-applied', () async {
    // The variant the issue never reported and the one that is worse: on a
    // switch, prefs hold the previous identity until each key is overwritten.
    // A reader catching the write half-done sees the NEW filename against the
    // OLD source -- a complete, well-formed identity that passes isInstalled,
    // so the engine loads the wrong weights with nothing thrown.
    WebModelManager().setActiveModel(_spec('first'));
    await WebModelManager().ensureInitialized();

    WebModelManager().setActiveModel(_spec('second'));
    await WebModelManager().ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final filename = prefs.getString(PreferencesKeys.activeInferenceFilename);
    final source = prefs.getString(PreferencesKeys.activeInferenceSource);

    // Both keys must describe the SAME model, whichever one won.
    final fromFilename = filename!.contains('second') ? 'second' : 'first';
    final fromSource = source!.contains('second') ? 'second' : 'first';
    expect(
      fromSource,
      fromFilename,
      reason: 'filename says $fromFilename but source says $fromSource — '
          'that mixed identity is what loads the wrong weights',
    );
  });
}
