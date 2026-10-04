// clearActiveInferenceIdentity (#304/#338) — the inverse of active-model
// auto-restore (#227, see active_model_restore_test.dart).
//
// Verifies that clearing the active identity removes BOTH the in-memory spec
// AND the persisted prefs, so a subsequent `FlutterEdgeAi.initialize()`
// ("second app launch") does NOT rehydrate the cleared model.
//
//   1. Test 1: installModel() → active set + identity keys in prefs →
//      clearActiveInferenceIdentity() → hasActiveModel() false + all four
//      identity keys gone from SharedPreferences.
//   2. Test 2: reset ServiceRegistry + initialize() again (fresh manager) →
//      hasActiveModel() STILL false (nothing to restore — clear persisted).

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelName = 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';

const _inferenceKeys = <String>[
  'active_inference_model_type',
  'active_inference_file_type',
  'active_inference_filename',
  'active_inference_source',
];

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

  testWidgets(
    'clearActiveInferenceIdentity removes active model + persisted prefs',
    (_) async {
      await registerTestEngines();

      final modelPath = await _docsPath(_modelName);
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();

      expect(FlutterEdgeAi.hasActiveModel(), isTrue);

      // Let the fire-and-forget persistence land before clearing.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final stored = await SharedPreferences.getInstance();
      expect(
        stored.getString('active_inference_filename'),
        _modelName,
        reason: 'precondition: identity persisted before clear',
      );

      // The operation under test.
      await FlutterEdgeAi.clearActiveInferenceIdentity();

      // In-memory state cleared.
      expect(
        FlutterEdgeAi.hasActiveModel(),
        isFalse,
        reason: 'hasActiveModel() must be false right after clear',
      );

      // Persisted prefs cleared — all four identity keys gone.
      final after = await SharedPreferences.getInstance();
      for (final k in _inferenceKeys) {
        expect(after.getString(k), isNull, reason: 'pref "$k" must be removed');
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'second initialize() does NOT rehydrate a cleared model',
    (_) async {
      // Simulate "app relaunched" after a clear: fresh ServiceRegistry +
      // initialize(). With the persisted identity gone, there is nothing to
      // restore — hasActiveModel() must stay false.
      ServiceRegistry.reset();
      await registerTestEngines();

      expect(
        FlutterEdgeAi.hasActiveModel(),
        isFalse,
        reason:
            'a cleared identity must not be auto-restored on second initialize()',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
