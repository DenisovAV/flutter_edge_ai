// MediaPipe web takes images. The switch is the model's supportImage, which
// sets maxNumImages on the LlmInference; createSession's enableVisionModality
// is not read. So the debug log warns only when vision is requested on a model
// created without supportImage, and says what will happen: an image message
// throws ArgumentError. It used to say "Vision modality is not yet implemented
// for web platform" on every createSession(enableVisionModality: true),
// including the Gemma 4 `-web.task` path the docs recommend for web images.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/web_inference_model_vision_log_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/llm_inference_web.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/web_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Holds createSession at its first await, after the modality checks and
/// before anything loads. It never answers: a resolver that threw would also
/// fail the test, because createSession completes its init completer with the
/// error while nothing listens to it, which surfaces as an uncaught error.
final class _PendingResolver implements WebModelSourceResolver {
  @override
  Future<InferenceModelSpec> activeInferenceSpec() =>
      Completer<InferenceModelSpec>().future;

  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() =>
      Completer<({WebModelSource model, String? loraPath})>().future;
}

WebInferenceModel _model({required bool supportImage}) => WebInferenceModel(
  modelType: ModelType.gemma4,
  onClose: () {},
  maxTokens: 4096,
  sourceResolver: _PendingResolver(),
  supportImage: supportImage,
  maxNumImages: supportImage ? 4 : null,
);

/// What createSession(enableVisionModality: true) logs before its first
/// await, which is where the modality checks are.
List<String> _visionLogs(WebInferenceModel model) {
  final logged = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) logged.add(message);
  };
  try {
    unawaited(model.createSession(enableVisionModality: true));
  } finally {
    debugPrint = original;
  }
  return logged;
}

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

void main() {
  test('a model created with supportImage: no vision warning', () {
    final logged = _visionLogs(_model(supportImage: true));

    expect(
      logged.where((line) => line.toLowerCase().contains('vision')),
      isEmpty,
    );
  });

  test('vision requested on a model created without supportImage: the warning '
      'names the engine and the ArgumentError an image will throw', () {
    final logged = _visionLogs(_model(supportImage: false));

    expect(
      logged.where((line) => line.toLowerCase().contains('vision')).toList(),
      [
        allOf(
          startsWith('[MediaPipe Web]'),
          contains('supportImage: true'),
          contains('ArgumentError'),
        ),
      ],
    );
  });

  test(
    'which is what an image does on a session without supportImage',
    () async {
      final session = WebModelSession(
        llmInference: JSObject() as LlmInference,
        onClose: () {},
        modelType: ModelType.gemma4,
      );

      await expectLater(
        session.addQueryChunk(
          Message.withImage(
            text: 'What is this?',
            imageBytes: _jpeg,
            isUser: true,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );
}
