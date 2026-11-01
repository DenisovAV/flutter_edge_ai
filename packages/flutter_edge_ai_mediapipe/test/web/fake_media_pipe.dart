// Fakes of the page's MediaPipe globals and a WebInferenceModel built on
// them, shared by the browser tests of the web model.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/web_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Holds createSession at its first await, after the modality checks and
/// before anything loads. It never answers: a resolver that threw would also
/// fail the test, because createSession completes its init completer with the
/// error while nothing listens to it, which surfaces as an uncaught error.
final class PendingResolver implements WebModelSourceResolver {
  @override
  Future<InferenceModelSpec> activeInferenceSpec() =>
      Completer<InferenceModelSpec>().future;

  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() =>
      Completer<({WebModelSource model, String? loraPath})>().future;
}

/// Answers with a Blob URL, so createSession goes on to build the LlmInference.
final class BlobResolver implements WebModelSourceResolver {
  @override
  Future<InferenceModelSpec> activeInferenceSpec() =>
      Completer<InferenceModelSpec>().future;

  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async =>
      (model: const BlobUrlModelSource('blob:fake-model'), loraPath: null);
}

/// Answers with a Blob URL once [gate] completes.
final class GatedResolver implements WebModelSourceResolver {
  GatedResolver(this.gate);
  final Future<void> gate;

  @override
  Future<InferenceModelSpec> activeInferenceSpec() =>
      Completer<InferenceModelSpec>().future;

  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async {
    await gate;
    return (model: const BlobUrlModelSource('blob:fake-model'), loraPath: null);
  }
}

WebInferenceModel testModel({
  required bool supportImage,
  bool supportAudio = false,
  WebModelSourceResolver? resolver,
}) => WebInferenceModel(
  modelType: ModelType.gemma4,
  onClose: () {},
  maxTokens: 4096,
  sourceResolver: resolver ?? PendingResolver(),
  supportImage: supportImage,
  supportAudio: supportAudio,
  maxNumImages: supportImage ? 4 : null,
);

/// Stands in for the page's MediaPipe globals for the rest of the test.
/// `created` gets the options of each LlmInference.createFromOptions call;
/// the LlmInference it creates answers generateResponse with 'ok' and adds
/// each prompt it is given to `prompts`. `closed` gets each LlmInference
/// close() call, so `closed.length == created.length` means every model it
/// made was released.
({List<JSObject> created, List<JSAny> prompts, List<JSObject> closed})
fakeMediaPipe() {
  final created = <JSObject>[];
  final prompts = <JSAny>[];
  final closed = <JSObject>[];
  late final JSObject instance;
  instance = JSObject()
    ..setProperty(
      'generateResponse'.toJS,
      ((JSAny prompt, JSAny? _) {
        prompts.add(prompt);
        return Future<JSString>.value('ok'.toJS).toJS;
      }).toJS,
    )
    ..setProperty('close'.toJS, (() => closed.add(instance)).toJS);
  replaceGlobal(
    'FilesetResolver',
    JSObject()..setProperty(
      'forGenAiTasks'.toJS,
      ((JSString _) => Future<JSObject>.value(JSObject()).toJS).toJS,
    ),
  );
  replaceGlobal(
    'LlmInference',
    JSObject()..setProperty(
      'createFromOptions'.toJS,
      ((JSObject _, JSObject options) {
        created.add(options);
        return Future<JSObject>.value(instance).toJS;
      }).toJS,
    ),
  );
  return (created: created, prompts: prompts, closed: closed);
}

/// Like [fakeMediaPipe], but generateResponse answers only when the test says
/// so: `calls` holds one completer per call made, in order.
({List<Completer<String>> calls, JSObject instance}) heldMediaPipe() {
  final calls = <Completer<String>>[];
  final instance = JSObject()
    ..setProperty(
      'generateResponse'.toJS,
      ((JSAny prompt, JSAny? _) {
        final call = Completer<String>();
        calls.add(call);
        return call.future.then((text) => text.toJS).toJS;
      }).toJS,
    )
    ..setProperty('cancelProcessing'.toJS, (() {}).toJS)
    ..setProperty('close'.toJS, (() {}).toJS);
  replaceGlobal(
    'FilesetResolver',
    JSObject()..setProperty(
      'forGenAiTasks'.toJS,
      ((JSString _) => Future<JSObject>.value(JSObject()).toJS).toJS,
    ),
  );
  replaceGlobal(
    'LlmInference',
    JSObject()..setProperty(
      'createFromOptions'.toJS,
      ((JSObject _, JSObject options) => Future<JSObject>.value(
        instance,
      ).toJS).toJS,
    ),
  );
  return (calls: calls, instance: instance);
}

/// Sets globalThis[name] for the rest of the test, then puts back what was
/// there, or removes the key if there was nothing.
void replaceGlobal(String name, JSObject value) {
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
