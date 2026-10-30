// The MediaPipe-web session: the conversation, and the calls that run it.
// Platform-neutral: the JS call sits behind [WebLlmBackend], so VM tests drive
// the session with a fake.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';

import 'web_prompt.dart';

/// What the session needs from `LlmInference`: a stateless call that takes
/// the whole prompt.
abstract interface class WebLlmBackend {
  /// The number of tokens in [text].
  Future<int> sizeInTokens(String text);

  /// Runs [prompt] and returns the reply; a call stopped before it started
  /// returns an empty one.
  Future<String> generate(List<PromptPart> prompt);

  /// Runs [prompt] and streams the reply, in pieces that add up to it. A
  /// failure is an error on the stream.
  Stream<String> generateStream(List<PromptPart> prompt);

  /// Asks a running generation to stop.
  void cancel();
}

/// One generation: what it has produced so far, and whether it is over.
class _Run {
  final StringBuffer text = StringBuffer();
  bool done = false;

  /// Completes when the backend call has ended, whatever way: after a stop
  /// that is later than the stop.
  final Completer<void> ended = Completer<void>();
  void end() {
    if (!ended.isCompleted) ended.complete();
  }
}

class WebModelSession extends InferenceModelSession {
  WebModelSession({
    required WebLlmBackend backend,
    required VoidCallback onClose,
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.task,
    bool supportImage = false,
    bool supportAudio = false,
    String? systemInstruction,
    WebChatTemplate? template,
    int? maxImages,
  }) : this._(
         backend: backend,
         onClose: onClose,
         modelType: modelType,
         fileType: fileType,
         supportImage: supportImage,
         supportAudio: supportAudio,
         systemInstruction: systemInstruction,
         template: template,
         maxImages: maxImages,
         preformatted: _formatsByHand(modelType, fileType),
       );

  WebModelSession._({
    required WebLlmBackend backend,
    required this.onClose,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this.supportAudio,
    required this.systemInstruction,
    required WebChatTemplate? template,
    required int? maxImages,
    required bool preformatted,
  }) : _backend = backend,
       _preformatted = preformatted,
       _conversation = WebConversation(
         // A message core wrote the markers into carries them already, so the
         // file's template must not add them a second time.
         template: preformatted ? null : template,
         maxImages: maxImages,
         preformatted: preformatted,
       );

  /// Whether core writes the turn markers into the messages itself: a `.bin`
  /// file, and FunctionGemma, whose `.task` has none (`transformToChatPrompt`).
  static bool _formatsByHand(ModelType modelType, ModelFileType fileType) =>
      fileType == ModelFileType.binary ||
      (fileType == ModelFileType.task && modelType == ModelType.functionGemma);

  final bool _preformatted;

  /// Whether the turns are written with the file's template and the model is
  /// Gemma 4, whose chat template trims what the user said and strips the
  /// thinking from a reply, as core does for a `.bin` (`transformToChatPrompt`).
  bool get _gemma4Template => !_preformatted && modelType == ModelType.gemma4;

  String _cleanUser(String text) => _gemma4Template ? text.trim() : text;

  /// The template's `strip_thinking` macro, then a trim.
  String _cleanReply(String reply) {
    if (!_gemma4Template) return reply;
    final result = StringBuffer();
    for (final part in reply.split('<channel|>')) {
      final open = part.indexOf('<|channel>');
      result.write(open >= 0 ? part.substring(0, open) : part);
    }
    return result.toString().trim();
  }

  /// A reply of the model as the history holds it: the raw text when the
  /// conversation writes the markers, and closed by core's own marker when the
  /// messages are written by hand.
  String _inHistory(String reply) => _preformatted
      ? Message(
          text: reply,
          isUser: false,
        ).transformToChatPrompt(type: modelType, fileType: fileType)
      : _cleanReply(reply);

  final WebLlmBackend _backend;
  final WebConversation _conversation;
  final ModelType modelType;
  final ModelFileType fileType;
  final VoidCallback onClose;
  final bool supportImage; // Enabling image support
  final bool supportAudio; // Enabling audio support (Gemma 3n E4B)
  StreamController<String>? _controller;
  _Run? _run;

  final String? systemInstruction;
  bool _systemInstructionSent = false;

  /// Set by [close]. A closed session must not touch the backend, which the
  /// next session of the model shares.
  bool _closed = false;

  void _requireOpen() {
    if (_closed) throw StateError('This session is closed.');
  }

  @override
  Future<int> sizeInTokens(String text) => _backend.sizeInTokens(text);

  @override
  Future<void> addQueryChunk(Message message) async {
    _requireOpen();
    if (kDebugMode) {
      edgeAiLog(
        'WebModelSession.addQueryChunk() - isUser: ${message.isUser}, '
        'hasImage: ${message.hasImage}, hasAudio: ${message.hasAudio}',
      );
    }

    var messageToSend = message;
    final addsSystemInstruction =
        message.isUser &&
        !_systemInstructionSent &&
        systemInstruction != null &&
        systemInstruction!.isNotEmpty;
    if (addsSystemInstruction) {
      messageToSend = message.copyWith(
        text: '[System: ${systemInstruction!}]\n\n${message.text}',
      );
    }

    final text = messageToSend.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );

    if (!message.isUser) {
      // A reply of the model that the chat replays into a new session. What
      // this session generates itself is recorded when it is generated.
      if (message.type != MessageType.thinking && text.isNotEmpty) {
        _conversation.addModel(_cleanReply(text));
      }
      return;
    }

    final parts = <PromptPart>[];
    // Image parts first, then audio, then text last.
    if (message.hasImage) {
      if (!supportImage) {
        throw ArgumentError('This model does not support images');
      }
      final images = message.images.isNotEmpty
          ? message.images
          : (message.imageBytes != null
                ? [message.imageBytes!]
                : const <Uint8List>[]);
      for (final imageBytes in images) {
        parts.add(ImagePromptPart.fromBytes(imageBytes));
      }
    }
    if (message.hasAudio && message.audioBytes != null) {
      if (!supportAudio) {
        throw ArgumentError('This model does not support audio');
      }
      parts.add(AudioPromptPart(message.audioBytes!));
    }
    // Text last, so a multimodal turn keeps its image/audio context first.
    parts.add(TextPromptPart(_cleanUser(text)));
    _conversation.addUser(parts);
    // Only now: a message the conversation refused must not use up the
    // instruction.
    if (addsSystemInstruction) _systemInstructionSent = true;
  }

  /// MediaPipe refuses a call while the one before it is still ending, which
  /// after a stop is a moment later than the stop itself.
  Future<void> _previousEnded(_Run? run) async {
    if (run == null || run.ended.isCompleted) return;
    await run.ended.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        edgeAiLog('[WebModelSession] the previous call did not end in 30 s');
      },
    );
  }

  /// Ends [run] with the reply the model wrote.
  void _complete(_Run run, String reply) {
    if (run.done) return;
    run.done = true;
    _conversation.completeGeneration(_inHistory(reply));
  }

  /// Ends [run] without a reply: the user's turn stays, to be answered by a
  /// retry.
  void _fail(_Run run) {
    if (run.done) return;
    run.done = true;
    _conversation.failGeneration();
  }

  @override
  Future<String> getResponse() async {
    _requireOpen();
    // The run is this call's from here on, so a stop that comes while it
    // waits for the previous call finds it and ends it before it starts.
    final previous = _run;
    final run = _run = _Run();
    final List<PromptPart> prompt;
    try {
      await _previousEnded(previous);
      // Closed while it waited: it must not start a call on the shared
      // backend.
      _requireOpen();
      // Stopped while it waited: it ends with nothing generated, as a stopped
      // stream does, and the user's turn stays unanswered.
      if (run.done) {
        run.end();
        return '';
      }
      prompt = _conversation.beginGeneration();
    } catch (_) {
      run.done = true;
      run.end();
      // A refused start (the previous call still running past the wait) must
      // leave that call where a stop can find it.
      if (identical(_run, run)) _run = previous;
      rethrow;
    }
    try {
      final response = await _backend.generate(prompt);
      _complete(run, response);
      return response;
    } catch (e, stackTrace) {
      if (kDebugMode) {
        edgeAiLog('getResponse: $e\n$stackTrace');
      }
      _fail(run);
      rethrow;
    } finally {
      run.end();
    }
  }

  @override
  Stream<String> getResponseAsync() {
    _requireOpen();
    // Close previous controller to prevent leak if called again before completion
    _controller?.close();
    final controller = _controller = StreamController<String>();
    unawaited(_stream(controller));
    return controller.stream;
  }

  Future<void> _stream(StreamController<String> controller) async {
    final List<PromptPart> prompt;
    try {
      await _previousEnded(_run);
      if (controller.isClosed) return;
      prompt = _conversation.beginGeneration();
    } catch (e, stackTrace) {
      if (!controller.isClosed) {
        controller
          ..addError(e, stackTrace)
          ..close();
      }
      return;
    }
    final run = _run = _Run();
    _backend
        .generateStream(prompt)
        .listen(
          (piece) {
            if (run.done) return;
            run.text.write(piece);
            // The consumer may have started a newer call, which closed this
            // controller; the reply still ends up in the history.
            if (!controller.isClosed) controller.add(piece);
          },
          onError: (Object e, StackTrace st) {
            run.end();
            if (run.done) return;
            _fail(run);
            if (controller.isClosed) return;
            controller
              ..addError(e, st)
              ..close();
          },
          onDone: () {
            run.end();
            if (run.done) return;
            _complete(run, run.text.toString());
            controller.close();
          },
        );
  }

  @override
  Future<void> stopGeneration() async {
    final run = _run;
    // The backend is shared with the other sessions of the model, so only a
    // run of this session is cancelled: a stop on an idle or closed session
    // must not end the generation of the live one.
    if (run != null && !run.done) {
      // What was generated until now stays, as in a native session's cache.
      // A call that is not streaming has produced nothing the session can
      // see, so the user's turn stays unanswered.
      run.done = true;
      final generated = run.text.toString();
      _conversation.stopGeneration(
        generated.isEmpty ? generated : _inHistory(generated),
      );
      try {
        _backend.cancel();
      } catch (e) {
        if (kDebugMode) {
          edgeAiLog('[WebModelSession] cancel error: $e');
        }
      }
    }
    _controller?.close();
    _controller = null;
  }

  @override
  SessionMetrics getSessionMetrics() {
    // Web MediaPipe implementation doesn't expose detailed token metrics.
    // Users can estimate using sizeInTokens() before/after generation.
    return SessionMetrics();
  }

  /// The number of images the conversation holds.
  @visibleForTesting
  int get imageCount => _conversation.imageCount;

  @override
  Future<void> close() async {
    _closed = true;
    // The loaded model belongs to the model, not to a session: closing a
    // session ends its conversation, and the next session reuses the model.
    final run = _run;
    if (run != null && !run.done) {
      run.done = true;
      try {
        _backend.cancel();
      } catch (e) {
        if (kDebugMode) {
          edgeAiLog('[WebModelSession] cancel error: $e');
        }
      }
    }
    _conversation.clear();
    _controller?.close();
    _controller = null;
    onClose();
  }
}
