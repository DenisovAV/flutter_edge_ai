// [WebLlmBackend] over `@mediapipe/tasks-genai`'s `LlmInference`.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'llm_inference_web.dart';
import 'web_llm_lane.dart';
import 'web_model_session.dart';
import 'web_prompt.dart';

class LlmInferenceBackend implements WebLlmBackend {
  LlmInferenceBackend(this._llm);

  final LlmInference _llm;

  /// The calls of every session of the model, one at a time.
  final WebLlmLane _lane = WebLlmLane();

  /// Set by [close]: no call reaches the `LlmInference` after it.
  bool _closed = false;

  /// The token counts that wait in the lane: they belong to no session, so
  /// no session close cancels them.
  final Set<WebLlmCall> _counts = {};

  void _requireOpen() {
    if (_closed) throw StateError('The model is closed.');
  }

  /// Refuses every later call, and cancels the token counts that wait: the
  /// model is about to close its `LlmInference`. The sessions' own calls are
  /// cancelled by their sessions, which the model closes first.
  void close() {
    _closed = true;
    for (final count in [..._counts]) {
      _lane.cancel(count);
    }
  }

  /// The token counts of the last replies, counted inside their own call.
  final Map<String, int> _replySizes = <String, int>{};
  static const int _replySizesKept = 16;

  /// Counts [reply] while its call still holds the lane: core's chat counts
  /// each reply right after its stream, when another session's call may
  /// already run, and a count then would wait for that whole generation.
  void _countReply(String reply) {
    if (reply.isEmpty || _closed) return;
    try {
      _replySizes.remove(reply);
      _replySizes[reply] = _llm.sizeInTokens(reply.toJS).toDartInt;
      if (_replySizes.length > _replySizesKept) {
        _replySizes.remove(_replySizes.keys.first);
      }
    } catch (_) {
      // Not counted here; sizeInTokens counts it in the lane.
    }
  }

  /// MediaPipe refuses a count while a generation runs, so it is a call of
  /// the lane (a priority one), except for an empty text and a reply just
  /// generated, whose count its own call took.
  @override
  Future<int> sizeInTokens(String text) async {
    if (text.isEmpty) return 0;
    if (_replySizes[text] case final size?) return size;
    _requireOpen();
    // Right after the call in MediaPipe, ahead of the generations that wait:
    // a reply cut by a stop, or one the chat changed (thinking stripped),
    // is counted when that call ends, not after every other session's turn.
    final call = WebLlmCall(owner: 'sizeInTokens');
    _counts.add(call);
    try {
      final size = await _lane.run(call, () async {
        _requireOpen();
        return _llm.sizeInTokens(text.toJS).toDartInt;
      }, priority: true);
      // Cancelled only by [close].
      if (size == null) throw StateError('The model was closed.');
      return size;
    } finally {
      _counts.remove(call);
    }
  }

  @override
  Future<String?> generate(List<PromptPart> prompt, WebLlmCall call) =>
      _lane.run(call, () async {
        _requireOpen();
        final jsPrompt = _jsPrompt(prompt);
        final reply = jsPrompt.isA<JSString>()
            ? _llm.generateResponse(jsPrompt as JSString, null)
            : _llm.generateResponseMultimodal(jsPrompt, null);
        final text = (await reply.toDart).toDart;
        _countReply(text);
        return text;
      });

  @override
  Stream<String> generateStream(List<PromptPart> prompt, WebLlmCall call) {
    final controller = StreamController<String>();
    // What the consumer was sent: the text core's chat counts.
    final sent = StringBuffer();
    void onPiece(JSString partial, JSAny complete) {
      if (controller.isClosed) return;
      try {
        // The stream ends when the call settles, below: MediaPipe refuses a
        // new call until then, and `complete` comes first.
        final piece = partial.toDart;
        sent.write(piece);
        controller.add(piece);
      } catch (e, st) {
        controller
          ..addError(e, st)
          ..close();
      }
    }

    unawaited(() async {
      try {
        // The call settles once, after the last piece: a failure surfaces
        // here. Stopped while it waited, it never starts, and its stream
        // ends.
        await _lane.run(call, () async {
          _requireOpen();
          final jsPrompt = _jsPrompt(prompt);
          final reply = jsPrompt.isA<JSString>()
              ? _llm.generateResponse(jsPrompt as JSString, onPiece.toJS)
              : _llm.generateResponseMultimodal(jsPrompt, onPiece.toJS);
          await reply.toDart;
          _countReply(sent.toString());
        });
        if (!controller.isClosed) await controller.close();
      } catch (e, st) {
        if (controller.isClosed) return;
        controller
          ..addError(e, st)
          ..close();
      }
    }());
    return controller.stream;
  }

  /// Cancels in MediaPipe only when [call] is the one running there: the
  /// running call may be another session's.
  @override
  void cancel(WebLlmCall call) {
    if (_lane.cancel(call) && !_closed) _llm.cancelProcessing();
  }

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
          // Raw PCM bytes (16 kHz, 16-bit, mono), in a buffer of their own:
          // a view goes to JS as a Uint8Array whose `.buffer` is the whole
          // buffer behind it, so a reader of that would get the rest too.
          AudioPromptPart(:final audioBytes) => <String, Object>{
            'audioSource': _ownBuffer(audioBytes),
          }.jsify()!,
          _ => throw StateError('Unsupported prompt part type: $part'),
        },
    ].toJS;
  }
}

/// [bytes], or a copy of them when they are a view of a larger buffer.
Uint8List _ownBuffer(Uint8List bytes) =>
    bytes.offsetInBytes == 0 &&
        bytes.lengthInBytes == bytes.buffer.lengthInBytes
    ? bytes
    : Uint8List.fromList(bytes);
