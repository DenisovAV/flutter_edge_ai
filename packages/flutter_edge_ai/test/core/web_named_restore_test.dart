@TestOn('browser')
library;

// An LLM installed on the web under a name of its own
// (`fromNetwork(filename:)`, every catalog install) is the active model again
// after a page reload: the restore keeps the name it was recorded under
// instead of re-deriving the URL's.
//
// Run: flutter test --platform chrome test/core/web_named_restore_test.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(ServiceRegistry.reset);
  tearDown(ServiceRegistry.reset);

  test('the active model keeps its install name across a reload', () async {
    const url = 'https://example.com/repo/model.litertlm';
    SharedPreferences.setMockInitialValues({
      'active_inference_model_type': 'phi',
      'active_inference_file_type': 'litertlm',
      'active_inference_filename': 'phi-4-mini-reasoning.litertlm',
      'active_inference_source': 'network|$url',
    });
    await ServiceRegistry.initialize();
    await ServiceRegistry.instance.modelRepository.saveModel(
      repo.ModelInfo(
        id: 'phi-4-mini-reasoning.litertlm',
        source: ModelSource.network(url),
        installedAt: DateTime(2026),
        sizeBytes: 1,
        type: repo.ModelType.inference,
        hasLoraWeights: false,
      ),
    );

    final manager = WebModelManager();
    await manager.ensureInitialized();

    final spec = manager.activeInferenceModel as InferenceModelSpec?;
    expect(spec, isNotNull);
    expect(spec!.files.single.filename, 'phi-4-mini-reasoning.litertlm');
  });

  test(
    'a name its URL gives is restored, even one that is not portable',
    () async {
      const url = 'https://example.com/repo/gemma%3A2b.litertlm';
      SharedPreferences.setMockInitialValues({
        'active_inference_model_type': 'gemma4',
        'active_inference_file_type': 'litertlm',
        'active_inference_filename': 'gemma:2b.litertlm',
        'active_inference_source': 'network|$url',
      });
      await ServiceRegistry.initialize();
      await ServiceRegistry.instance.modelRepository.saveModel(
        repo.ModelInfo(
          id: 'gemma:2b.litertlm',
          source: ModelSource.network(url),
          installedAt: DateTime(2026),
          sizeBytes: 1,
          type: repo.ModelType.inference,
          hasLoraWeights: false,
        ),
      );
      final manager = WebModelManager();
      await manager.ensureInitialized();
      final spec = manager.activeInferenceModel as InferenceModelSpec?;
      expect(spec?.files.single.filename, 'gemma:2b.litertlm');
    },
  );

  group('restore notices, through the log sink', () {
    late List<String> said;
    final sink = debugPrint;
    setUp(() {
      said = [];
      debugPrint = (message, {wrapWidth}) => said.add(message ?? '');
    });
    tearDown(() {
      debugPrint = sink;
      edgeAiLogLevel = EdgeAiLogLevel.info;
    });

    /// An active inference model with no record of its file.
    final unrecorded = {
      PreferencesKeys.activeInferenceModelType: 'phi',
      PreferencesKeys.activeInferenceFileType: 'litertlm',
      PreferencesKeys.activeInferenceFilename: 'gone.litertlm',
      PreferencesKeys.activeInferenceSource:
          'network|https://example.com/gone.litertlm',
    };

    test('a restore that throws is said, and the start goes on', () async {
      // Not a string: reading the record throws.
      SharedPreferences.setMockInitialValues({
        PreferencesKeys.activeInferenceIdentity: 5,
      });
      await ServiceRegistry.initialize();
      final manager = WebModelManager();
      await manager.ensureInitialized();
      expect(manager.activeInferenceModel, isNull);
      expect(
        said,
        contains(
          startsWith(
            'flutter_edge_ai: the active inference model was not restored',
          ),
        ),
      );
    });

    test('a skip is said in the default storage', () async {
      SharedPreferences.setMockInitialValues(unrecorded);
      await ServiceRegistry.initialize();
      await WebModelManager().ensureInitialized();
      expect(said, contains(contains('gone.litertlm not in repository')));
    });

    test(
      'WebStorageMode.none, where nothing outlives a load, says no skip',
      () async {
        SharedPreferences.setMockInitialValues(unrecorded);
        await ServiceRegistry.initialize(webStorageMode: WebStorageMode.none);
        await WebModelManager().ensureInitialized();
        expect(said.where((m) => m.startsWith('flutter_edge_ai: ')), isEmpty);
      },
    );

    test('EdgeAiLogLevel.none silences it', () async {
      edgeAiLogLevel = EdgeAiLogLevel.none;
      SharedPreferences.setMockInitialValues({
        PreferencesKeys.activeInferenceIdentity: 5,
      });
      await ServiceRegistry.initialize();
      await WebModelManager().ensureInitialized();
      expect(said, isEmpty);
    });
  });
}
