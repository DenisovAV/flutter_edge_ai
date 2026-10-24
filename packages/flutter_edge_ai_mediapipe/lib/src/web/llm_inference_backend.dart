// [WebLlmBackend] over `@mediapipe/tasks-genai`'s `LlmInference`.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_edge_ai/engine.dart' show edgeAiLog;

import 'llm_inference_web.dart';
import 'web_model_session.dart';
import 'web_prompt.dart';

class LlmInferenceBackend implements WebLlmBackend {
  LlmInferenceBackend(this._llm);

  final LlmInference _llm;

  /// Settles when the last call has ended. MediaPipe refuses a call while the
  /// one before it is still ending ("Previous invocation or loading is still
  /// ongoing"), and a stopped call ends a moment after the stop, also for the
  /// session that comes next.
  Future<void> _idle = Future<void>.value();

  Future<void> _untilIdle() => _idle.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      edgeAiLog('[MediaPipe Web] the previous call did not end in 30 s');
    },
  );

  Future<T> _track<T extends JSAny?>(JSPromise<T> reply) {
    final settled = reply.toDart;
    _idle = settled.then<void>((_) {}, onError: (Object _) {});
    return settled;
  }

  @override
  Future<int> sizeInTokens(String text) async =>
      _llm.sizeInTokens(text.toJS).toDartInt;

  @override
  Future<String> generate(List<PromptPart> prompt) async {
    await _untilIdle();
    final jsPrompt = _jsPrompt(prompt);
    final reply = jsPrompt.isA<JSString>()
        ? _llm.generateResponse(jsPrompt as JSString, null)
        : _llm.generateResponseMultimodal(jsPrompt, null);
    return (await _track(reply)).toDart;
  }

  @override
  Stream<String> generateStream(List<PromptPart> prompt) {
    final controller = StreamController<String>();
    void onPiece(JSString partial, JSAny complete) {
      if (controller.isClosed) return;
      try {
        // The stream ends when the call settles, below: MediaPipe refuses a
        // new call until then, and `complete` comes first.
        controller.add(partial.toDart);
      } catch (e, st) {
        controller
          ..addError(e, st)
          ..close();
      }
    }

    unawaited(() async {
      try {
        await _untilIdle();
        if (controller.isClosed) return;
        final jsPrompt = _jsPrompt(prompt);
        final reply = jsPrompt.isA<JSString>()
            ? _llm.generateResponse(jsPrompt as JSString, onPiece.toJS)
            : _llm.generateResponseMultimodal(jsPrompt, onPiece.toJS);
        // The call settles once, after the last piece: a failure surfaces
        // here.
        await _track(reply);
        if (!controller.isClosed) controller.close();
      } catch (e, st) {
        if (controller.isClosed) return;
        controller
          ..addError(e, st)
          ..close();
      }
    }());
    return controller.stream;
  }

  @override
  void cancel() => _llm.cancelProcessing();

  /// A text-only prompt is one string; one with an image or audio is the array
  /// MediaPipe documents, the strings and the media in reading order.
  JSAny _jsPrompt(List<PromptPart> prompt) {
    if (prompt.every((part) => part is TextPromptPart)) {
      return prompt.cast<TextPromptPart>().map((p) => p.text).join().toJS;
    }
    return [
      for (final part in prompt)
        switch (part) {
          TextPromptPart(:final text) => text.toJS,
          ImagePromptPart(:final dataUrl) => <String, String>{
            'imageSource': dataUrl,
          }.jsify()!,
          // Raw PCM bytes (16 kHz, 16-bit, mono).
          AudioPromptPart(:final audioBytes) => <String, Object>{
            'audioSource': audioBytes.buffer.asUint8List(),
          }.jsify()!,
          _ => throw StateError('Unsupported prompt part type: $part'),
        },
    ].toJS;
  }
}
