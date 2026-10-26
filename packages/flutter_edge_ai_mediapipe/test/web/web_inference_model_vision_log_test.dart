// MediaPipe web takes images. The switch is the model's supportImage, which
// sets maxNumImages on the LlmInference; createSession's enableVisionModality
// does not turn vision on. So the debug log warns only when vision is
// requested on a model created without supportImage, and says what will
// happen: an image message throws ArgumentError. It used to say "Vision
// modality is not yet implemented for web platform" on every
// createSession(enableVisionModality: true), including the Gemma 4
// `-web.task` path the docs recommend for web images.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/web_inference_model_vision_log_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/web_inference_model.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/web_model_session.dart';
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

/// Answers with a Blob URL, so createSession goes on to build the LlmInference.
final class _BlobResolver implements WebModelSourceResolver {
  @override
  Future<InferenceModelSpec> activeInferenceSpec() =>
      Completer<InferenceModelSpec>().future;

  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async =>
      (model: const BlobUrlModelSource('blob:fake-model'), loraPath: null);
}

WebInferenceModel _model({
  required bool supportImage,
  WebModelSourceResolver? resolver,
}) => WebInferenceModel(
  modelType: ModelType.gemma4,
  onClose: () {},
  maxTokens: 4096,
  sourceResolver: resolver ?? _PendingResolver(),
  supportImage: supportImage,
  maxNumImages: supportImage ? 4 : null,
);

/// What createSession logs before its first await, which is where the
/// modality checks are.
List<String> _visionLogs(
  WebInferenceModel model, {
  bool? enableVisionModality = true,
}) {
  final logged = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) logged.add(message);
  };
  try {
    unawaited(model.createSession(enableVisionModality: enableVisionModality));
  } finally {
    debugPrint = original;
  }
  return logged.where((line) => line.toLowerCase().contains('vision')).toList();
}

/// Stands in for the page's MediaPipe globals for the rest of the test.
/// `created` gets the options of each LlmInference.createFromOptions call;
/// the LlmInference it creates answers generateResponse with 'ok' and adds
/// each prompt it is given to `prompts`.
({List<JSObject> created, List<JSAny> prompts}) _fakeMediaPipe() {
  final created = <JSObject>[];
  final prompts = <JSAny>[];
  final instance = JSObject()
    ..setProperty(
      'generateResponse'.toJS,
      ((JSAny prompt, JSAny? _) {
        prompts.add(prompt);
        return Future<JSString>.value('ok'.toJS).toJS;
      }).toJS,
    );
  _replaceGlobal(
    'FilesetResolver',
    JSObject()..setProperty(
      'forGenAiTasks'.toJS,
      ((JSString _) => Future<JSObject>.value(JSObject()).toJS).toJS,
    ),
  );
  _replaceGlobal(
    'LlmInference',
    JSObject()..setProperty(
      'createFromOptions'.toJS,
      ((JSObject _, JSObject options) {
        created.add(options);
        return Future<JSObject>.value(instance).toJS;
      }).toJS,
    ),
  );
  return (created: created, prompts: prompts);
}

/// Sets globalThis[name] for the rest of the test, then puts back what was
/// there, or removes the key if there was nothing.
void _replaceGlobal(String name, JSObject value) {
  final existed = globalContext.has(name);
  final saved = globalContext.getProperty<JSAny?>(name.toJS);
  globalContext.setProperty(name.toJS, value);
  addTearDown(() {
    if (existed) {
      globalContext.setProperty(name.toJS, saved);
    } else {
      globalContext.delete(name.toJS);
    }
  });
}

int? _maxNumImages(JSObject options) =>
    options.getProperty<JSNumber?>('maxNumImages'.toJS)?.toDartInt;

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);

Message _imageMessage() =>
    Message.withImage(text: 'What is this?', imageBytes: _jpeg, isUser: true);

void main() {
  test('a model created with supportImage: no vision warning', () {
    expect(_visionLogs(_model(supportImage: true)), isEmpty);
  });

  test('vision requested on a model created without supportImage: the warning '
      'names the engine and the ArgumentError an image will throw', () {
    expect(_visionLogs(_model(supportImage: false)), [
      allOf(
        startsWith('[MediaPipe Web]'),
        contains('supportImage: true'),
        contains('ArgumentError'),
      ),
    ]);
  });

  test('vision not requested on a model without supportImage: no warning', () {
    expect(
      _visionLogs(_model(supportImage: false), enableVisionModality: false),
      isEmpty,
    );
    expect(
      _visionLogs(_model(supportImage: false), enableVisionModality: null),
      isEmpty,
    );
  });

  test(
    'which is what an image does on a session without supportImage',
    () async {
      final session = WebModelSession(
        backend: _NoBackend(),
        onClose: () {},
        modelType: ModelType.gemma4,
      );

      await expectLater(
        session.addQueryChunk(_imageMessage()),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'This model does not support images',
          ),
        ),
      );
    },
  );

  test('a model created with supportImage gives the LlmInference '
      'maxNumImages, and an image reaches its prompt', () async {
    final fake = _fakeMediaPipe();
    final model = _model(supportImage: true, resolver: _BlobResolver());

    final session = await model.createSession();
    expect(fake.created, hasLength(1));
    expect(_maxNumImages(fake.created.single), 4);

    await session.addQueryChunk(_imageMessage());
    expect(await session.getResponse(), 'ok');

    // The multimodal prompt MediaPipe documents: strings and
    // {imageSource: <data URL>} parts in one array.
    final prompt = fake.prompts.single.dartify()! as List<Object?>;
    expect(
      prompt,
      contains(
        isA<Map<Object?, Object?>>().having(
          (part) => part['imageSource'],
          'imageSource',
          startsWith('data:image/jpeg;base64,'),
        ),
      ),
    );
  });

  test('a model created without supportImage gives the LlmInference no '
      'maxNumImages', () async {
    final fake = _fakeMediaPipe();
    final model = _model(supportImage: false, resolver: _BlobResolver());

    await model.createSession();

    expect(fake.created, hasLength(1));
    expect(_maxNumImages(fake.created.single), isNull);
  });
}

/// A backend for a session that is never asked to generate.
class _NoBackend implements WebLlmBackend {
  @override
  Future<int> sizeInTokens(String text) => throw UnimplementedError();
  @override
  Future<String> generate(List<PromptPart> prompt) =>
      throw UnimplementedError();
  @override
  Stream<String> generateStream(List<PromptPart> prompt) =>
      throw UnimplementedError();
  @override
  void cancel() {}
}
