import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FfiInferenceModel exposes the backend initialized by the runtime', () {
    final model = FfiInferenceModel(
      ffiClient: LiteRtLmFfiClient(),
      maxTokens: 2048,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.gpu,
      onClose: () {},
    );

    expect(model.activeBackend, PreferredBackend.gpu);
  });

  test('isClosed is true from the moment close() starts', () async {
    // Core's getActiveModel cache checks this: its close listener fires only
    // once the teardown has ended.
    final model = FfiInferenceModel(
      ffiClient: LiteRtLmFfiClient(),
      maxTokens: 2048,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
      onClose: () {},
    );
    expect(model.isClosed, isFalse);

    final closing = model.close();
    expect(model.isClosed, isTrue);
    await closing;
  });
}
