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
  int? maxConcurrentSessions,
  List<int>? loraRanks,
}) => WebInferenceModel(
  modelType: ModelType.gemma4,
  onClose: () {},
  maxTokens: 4096,
  sourceResolver: resolver ?? PendingResolver(),
  supportImage: supportImage,
  supportAudio: supportAudio,
  maxNumImages: supportImage ? 4 : null,
  maxConcurrentSessions: maxConcurrentSessions,
  loraRanks: loraRanks,
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
/// so: `calls` holds one completer per call made, in order, `prompts` the
/// prompt of each and `progress` its progress callback, through which a test
/// streams a piece. `cancels` counts the cancelProcessing calls.
({
  List<Completer<String>> calls,
  List<JSAny> prompts,
  JSObject instance,
  List<void> cancels,
  List<JSFunction?> progress,
})
heldMediaPipe({bool streamReplies = false}) {
  final calls = <Completer<String>>[];
  final progresses = <JSFunction?>[];
  final prompts = <JSAny>[];
  final cancels = <void>[];
  final instance = JSObject()
    ..setProperty(
      'generateResponse'.toJS,
      ((JSAny prompt, JSFunction? progress) {
        final call = Completer<String>();
        calls.add(call);
        prompts.add(prompt);
        progresses.add(progress);
        return call.future.then((text) {
          // With [streamReplies], the reply also reaches a stream, as one
          // piece just before the call settles.
          if (streamReplies) {
            progress?.callAsFunction(null, text.toJS, true.toJS);
          }
          return text.toJS;
        }).toJS;
      }).toJS,
    )
    ..setProperty(
      'sizeInTokens'.toJS,
      ((JSString text) {
        if (calls.any((call) => !call.isCompleted)) {
          throw StateError('engine is currently loading or processing');
        }
        return text.toDart.length.toJS;
      }).toJS,
    )
    ..setProperty('cancelProcessing'.toJS, (() => cancels.add(null)).toJS)
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
  return (
    calls: calls,
    prompts: prompts,
    instance: instance,
    cancels: cancels,
    progress: progresses,
  );
}

/// Like [fakeMediaPipe], but as busy as the real one: generateResponse answers
/// 'ok' a moment later, streaming it through the progress callback, and
/// sizeInTokens throws while a call runs, as `@mediapipe/tasks-genai` 0.10.30
/// does ("engine is currently loading or processing").
({List<JSAny> prompts, List<String> errors}) busyMediaPipe() {
  final prompts = <JSAny>[];
  final errors = <String>[];
  var busy = false;
  final instance = JSObject()
    ..setProperty(
      'generateResponse'.toJS,
      ((JSAny prompt, JSFunction? progress) {
        if (busy) {
          errors.add('generateResponse while busy');
          throw StateError('Previous invocation or loading is still ongoing.');
        }
        busy = true;
        prompts.add(prompt);
        return Future<JSString>.delayed(const Duration(milliseconds: 5), () {
          progress?.callAsFunction(null, 'ok'.toJS, true.toJS);
          busy = false;
          return 'ok'.toJS;
        }).toJS;
      }).toJS,
    )
    ..setProperty(
      'sizeInTokens'.toJS,
      ((JSString text) {
        if (busy) {
          errors.add('sizeInTokens while busy');
          throw StateError(
            'Cannot process because LLM inference engine is currently '
            'loading or processing.',
          );
        }
        return text.toDart.length.toJS;
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
  return (prompts: prompts, errors: errors);
}

/// Answers with a Blob URL and an installed LoRA.
final class LoraResolver implements WebModelSourceResolver {
  LoraResolver(this.loraPath);
  final String loraPath;

  @override
  Future<InferenceModelSpec> activeInferenceSpec() =>
      Completer<InferenceModelSpec>().future;

  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async =>
      (model: const BlobUrlModelSource('blob:fake-model'), loraPath: loraPath);
}

/// Answers with a Blob URL, after failing its first [failures] calls.
final class FlakyResolver implements WebModelSourceResolver {
  FlakyResolver(this.failures);
  int failures;

  @override
  Future<InferenceModelSpec> activeInferenceSpec() =>
      Completer<InferenceModelSpec>().future;

  @override
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async {
    if (failures > 0) {
      failures--;
      throw StateError('no model file');
    }
    return (model: const BlobUrlModelSource('blob:fake-model'), loraPath: null);
  }
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
