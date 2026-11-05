import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// No native layer: openSession on the FFI engine makes no native call.
class _Client extends LiteRtLmFfiClient {
  @override
  SamplingParams get bundleSampler => const SamplingParams();
}

FfiInferenceModel _model() => FfiInferenceModel(
  ffiClient: _Client(),
  maxTokens: 1024,
  modelType: ModelType.qwen3,
  activeBackend: PreferredBackend.cpu,
  supportImage: true,
  supportAudio: true,
  onClose: () {},
);

void main() {
  test('openChat takes the model\'s own type and media, as createChat does '
      '(D8)', () async {
    final model = _model();
    final chat = await model.openChat();
    expect(chat.modelType, ModelType.qwen3);
    expect(chat.supportImage, isTrue);
    expect(chat.supportAudio, isTrue);
    expect(model.sessions, [same(chat.session)]);
    await chat.close();
    expect(model.sessions, isEmpty);
  });

  test('openChat keeps what the caller set', () async {
    final chat = await _model().openChat(
      modelType: ModelType.gemmaIt,
      supportImage: false,
      supportAudio: false,
    );
    expect(chat.modelType, ModelType.gemmaIt);
    expect(chat.supportImage, isFalse);
    expect(chat.supportAudio, isFalse);
  });

  test('openSession still counts against maxConcurrentSessions', () async {
    final model = FfiInferenceModel(
      ffiClient: _Client(),
      maxTokens: 1024,
      modelType: ModelType.qwen3,
      activeBackend: PreferredBackend.cpu,
      maxConcurrentSessions: 1,
      onClose: () {},
    );
    await model.openSession();
    await expectLater(model.openSession(), throwsStateError);
  });
}
