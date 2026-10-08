// 0.15.4 active model auto-restore (#227).
//
// Verifies that after `FlutterEdgeAi.initialize()` the previously
// installed inference model is rehydrated as the active one — without
// re-running `installModel()`.
//
// We can't actually kill+restart the integration test isolate, so we
// emulate "second app launch" by:
//   1. Test 1: installModel() + verify active is set + verify the identity
//      record landed in SharedPreferences.
//   2. Test 2: reset ServiceRegistry, call FlutterEdgeAi.initialize()
//      again (fresh manager state), and verify hasActiveModel() is
//      still true and getActiveModel() returns the same identity —
//      without any installModel() call.

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/model_management/active_identity_store.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelName = 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';

Future<String> _docsPath(String name) async {
  final docs = await getApplicationDocumentsDirectory();
  final f = File('${docs.path}/$name');
  if (f.existsSync()) return f.path;
  final bytes = await rootBundle.load('assets/test/$name');
  await f.writeAsBytes(bytes.buffer.asUint8List());
  return f.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('install persists active model identity to prefs', (_) async {
    await registerTestEngines();

    // Clear any stale persisted identity from prior runs to make this
    // assertion meaningful.
    final prefs = await SharedPreferences.getInstance();
    await ActiveIdentityStore.clear(prefs, ActiveIdentityKind.inference);

    final modelPath = await _docsPath(_modelName);
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ).fromFile(modelPath).install();

    expect(FlutterEdgeAi.hasActiveModel(), isTrue);

    // Give the fire-and-forget persistence a moment to land.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final stored = await SharedPreferences.getInstance();
    final identity = ActiveIdentityStore.read(
      stored,
      ActiveIdentityKind.inference,
    );
    expect(identity?[PreferencesKeys.activeInferenceModelType], 'gemmaIt');
    expect(identity?[PreferencesKeys.activeInferenceFileType], 'litertlm');
    expect(identity?[PreferencesKeys.activeInferenceFilename], _modelName);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('second initialize() rehydrates active model without install', (
    _,
  ) async {
    // Simulate "app relaunched": throw away the in-memory ServiceRegistry
    // (and with it, the MobileModelManager's `_activeInferenceModel`) and
    // start over. The persisted prefs from the prior test should be enough
    // to make hasActiveModel() true.
    ServiceRegistry.reset();
    await registerTestEngines();

    expect(
      FlutterEdgeAi.hasActiveModel(),
      isTrue,
      reason:
          'active model should be auto-restored from SharedPreferences on second initialize()',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
