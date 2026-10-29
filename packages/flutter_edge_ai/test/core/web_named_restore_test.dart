@TestOn('browser')
library;

// An LLM installed on the web under a name of its own
// (`fromNetwork(filename:)`, every catalog install) is the active model again
// after a page reload: the restore keeps the name it was recorded under
// instead of re-deriving the URL's.
//
// Run: flutter test --platform chrome test/core/web_named_restore_test.dart

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
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
}
