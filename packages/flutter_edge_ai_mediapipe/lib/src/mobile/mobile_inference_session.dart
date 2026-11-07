import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mutex/mutex.dart';

import 'package:flutter_edge_ai_mediapipe/pigeon.g.dart';

import '../reported_engine_turn.dart';
import 'native_turn_log.dart';

/// Shared MediaPipe pigeon client. Library-level (non-private) so the engine
/// (`mediapipe_engine.dart`) and both session classes use the SAME channel
/// instance — its own `flutter_edge_ai`-domain pigeon channel, distinct from
/// core's removed `PlatformService`.
final platformService = PlatformService();

@visibleForTesting
const eventChannel = EventChannel('flutter_gemma_stream');

class MobileInferenceModelSession extends InferenceModelSession {
  final ModelType modelType;
  final ModelFileType fileType;
  final VoidCallback onClose;
  final bool supportImage;
  final bool supportAudio; // Enabling audio support (Gemma 3n E4B)
  bool _isClosed = false;

  /// [stopGeneration] was called during the current turn.
  bool _stopAsked = false;

  /// What the native session holds, so a turn can be taken back (rule A).
  final NativeTurnLog _log = NativeTurnLog();

  /// Builds the native session again, as the model first built it. Null in
  /// a session made for a test without one: a take-back then only forgets.
  final Future<void> Function()? recreateNative;

  Completer<void>? _responseCompleter;
  StreamController<String>? _asyncResponseController;
  StreamSubscription? _eventSubscription;

  final String? systemInstruction;
  bool _systemInstructionSent = false;

  bool get _isNativeSystemInstruction =>
      fileType == ModelFileType.litertlm &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  MobileInferenceModelSession({
    required this.onClose,
    required this.modelType,
    this.fileType = ModelFileType.task,
    this.supportImage = false,
    this.supportAudio = false,
    this.systemInstruction,
    this.recreateNative,
  });

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    _assertRebuilt();
  }

  void _assertRebuilt() {
    if (_rebuildFailure case final failure?) {
      throw StateError(
        'This session could not be rebuilt after a turn was taken back '
        '($failure); create a new session.',
      );
    }
  }

  Future<void> _awaitLastResponse() async {
    if (_responseCompleter case Completer<void> completer) {
      await completer.future;
    }
  }

  @override
  Future<int> sizeInTokens(String text) => platformService.sizeInTokens(text);

  @override
  Future<void> addQueryChunk(Message message) async {
    _assertRebuilt();
    var messageToSend = message;
    if (message.isUser &&
        !_systemInstructionSent &&
        systemInstruction != null &&
        systemInstruction!.isNotEmpty &&
        !_isNativeSystemInstruction) {
      _systemInstructionSent = true;
      _log.stagedSystemInstruction();
      messageToSend = message.copyWith(
        text: '[System: ${systemInstruction!}]\n\n${message.text}',
      );
    }
    edgeAiLog(
      '[MobileSession.addQueryChunk] modelType=$modelType, fileType=$fileType, msgType=${message.type}',
      level: EdgeAiLogLevel.verbose,
    );
    final finalPrompt = messageToSend.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    edgeAiLog(
      '[MobileSession.addQueryChunk] finalPrompt length=${finalPrompt.length}',
      level: EdgeAiLogLevel.verbose,
    );
    if (message.hasImage && supportImage) {
      final images = message.images.isNotEmpty
          ? message.images
          : (message.imageBytes != null
                ? [message.imageBytes!]
                : const <Uint8List>[]);
      for (final image in images) {
        await _addImage(image);
      }
    }
    if (message.hasAudio && message.audioBytes != null && supportAudio) {
      await _addAudio(message.audioBytes!);
    }
    await platformService.addQueryChunk(finalPrompt);
    _log.stage(NativeText(finalPrompt));
  }

  /// The model's reply as a prompt chunk, for a replay.
  String _replyChunk(String text) => Message(
    text: text,
  ).transformToChatPrompt(type: modelType, fileType: fileType);

  /// Records how a turn ended in [_log]: kept with what the model wrote, or
  /// taken back when it failed or was stopped before any text. A take-back
  /// builds the native session again and replays what it held before the
  /// turn: MediaPipe cannot drop queued input.
  Future<void> _endTurn(String text, {required bool failed}) async {
    if (_isClosed) return;
    final takeBack = failed && !_stopAsked || _stopAsked && text.isEmpty;
    if (!takeBack) {
      _log.kept(text.isEmpty ? null : _replyChunk(text));
      return;
    }
    final before = _log.takeBack();
    if (before == null) return;
    if (before.systemInstruction) _systemInstructionSent = false;
    final recreate = recreateNative;
    if (recreate == null) return;
    _rebuildFailure = await rebuildNativeSession(
      before: before.before,
      recreate: recreate,
      closeRebuilt: platformService.closeSession,
      isClosed: () => _isClosed,
      send: (input) => switch (input) {
        NativeText(:final prompt) => platformService.addQueryChunk(prompt),
        NativeImage(:final bytes) => platformService.addImage(bytes),
        NativeAudio(:final bytes) => platformService.addAudio(bytes),
      },
    );
  }

  /// Why the native session could not be rebuilt after a take-back; the
  /// session refuses every call from then on.
  Object? _rebuildFailure;

  Future<void> _addImage(Uint8List imageBytes) async {
    _assertNotClosed();
    if (!supportImage) {
      throw ArgumentError('This model does not support images');
    }
    await platformService.addImage(imageBytes);
    _log.stage(NativeImage(imageBytes));
  }

  Future<void> _addAudio(Uint8List audioBytes) async {
    _assertNotClosed();
    if (!supportAudio) {
      throw ArgumentError('This model does not support audio');
    }
    await platformService.addAudio(audioBytes);
    _log.stage(NativeAudio(audioBytes));
  }

  @override
  Future<String> getResponse({Message? message}) async {
    _assertNotClosed();
    _stopAsked = false;
    await _awaitLastResponse();
    final completer = _responseCompleter = Completer<void>();
    try {
      if (message != null) {
        await addQueryChunk(message);
      }
      final String reply;
      try {
        reply = await platformService.generateResponse();
      } catch (_) {
        await _endTurn('', failed: true);
        rethrow;
      }
      await _endTurn(reply, failed: false);
      return reply;
    } finally {
      completer.complete();
    }
  }

  @override
  Stream<String> getResponseAsync({Message? message}) async* {
    _assertNotClosed();
    // A stop while it waits for the previous turn still counts.
    _stopAsked = false;
    await _awaitLastResponse();
    final completer = _responseCompleter = Completer<void>();
    try {
      final controller = _asyncResponseController = StreamController<String>();

      // Store subscription for proper cleanup
      _eventSubscription = eventChannel.receiveBroadcastStream().listen(
        (event) {
          // Check if controller is still open before adding events
          if (!controller.isClosed) {
            if (event is Map && event.containsKey('sessionId')) {
              // Tagged event belongs to a concurrent openSession() session —
              // ignore it on the legacy singleton listener (it's demuxed by
              // MultiSessionMobileInferenceModelSession).
            } else if (event is Map &&
                event.containsKey('code') &&
                event['code'] == "ERROR") {
              controller.addError(
                Exception(event['message'] ?? 'Unknown async error occurred'),
              );
              // A failed generation is over: no end follows it.
              controller.close();
            } else if (event is Map && event.containsKey('partialResult')) {
              final partial = event['partialResult'] as String;
              controller.add(partial);
            } else {
              controller.addError(Exception('Unknown event type: $event'));
            }
          }
        },
        onError: (error, st) {
          if (!controller.isClosed) {
            controller.addError(error, st);
            // A failed or cancelled generation is over: neither Android's
            // error path nor an older iOS plugin sends an end after it.
            controller.close();
          }
        },
        onDone: () {
          if (!controller.isClosed) {
            controller.close();
          }
        },
      );

      if (message != null) {
        await addQueryChunk(message);
      }
      // A start the native side refuses (a previous generation still
      // running, no session) fails this turn; unheard, the turn would wait
      // forever for events that never come.
      unawaited(
        platformService.generateResponseAsync().then<void>(
          (_) {},
          onError: (Object e, StackTrace st) {
            if (controller.isClosed) return;
            controller.addError(e, st);
            controller.close();
          },
        ),
      );

      final text = StringBuffer();
      var ended = false;
      try {
        await for (final chunk in controller.stream) {
          text.write(chunk);
          yield chunk;
        }
      } catch (_) {
        ended = true;
        await _endTurn(text.toString(), failed: true);
        rethrow;
      } finally {
        // Run to its end, or cancelled by the consumer, which this async*
        // stream sees only at a chunk: a turn with text is kept either way.
        if (!ended) await _endTurn(text.toString(), failed: false);
      }
    } finally {
      completer.complete();
      _asyncResponseController = null;
    }
  }

  /// How the turn ended, for core's chat: a stop is [TurnEnd.stopped] (the
  /// cancel's own error, iOS's among them, is not the turn's), a close the
  /// consumer did not ask for [TurnEnd.closed], so the chat keeps the
  /// partial reply (decision H). MediaPipe has no output cap here.
  @override
  EngineTurn startTurn() {
    _stopAsked = false;
    return reportedEngineTurn(
      getResponseAsync(),
      stopped: () => _stopAsked,
      closed: () => _isClosed,
      completed: () => TurnEnd.endOfSequence,
    );
  }

  @override
  Future<void> stopGeneration() async {
    _stopAsked = true;
    try {
      await platformService.stopGeneration();
    } catch (e) {
      if (e.toString().contains('stop_not_supported')) {
        throw PlatformException(
          code: 'stop_not_supported',
          message: 'Stop generation is not supported on this platform',
        );
      }
      rethrow;
    }
  }

  @override
  SessionMetrics getSessionMetrics() {
    // MediaPipe doesn't expose detailed token metrics via the current platform channel.
    // To get metrics on mobile, you would need to:
    // 1. Add a new platform method to fetch metrics from native side
    // 2. Or track tokens manually using sizeInTokens() before/after generation
    //
    // For now, return empty metrics. Users can estimate using:
    //   final inputTokens = await session.sizeInTokens(prompt);
    //   final outputTokens = await session.sizeInTokens(responseText);
    return SessionMetrics();
  }

  @override
  Future<void> close() async {
    // Idempotent: a second close must not run native `closeSession()`
    // again. With the singleton-session lifecycle (a fresh createSession
    // supersedes the prior wrapper), a superseded wrapper and the live
    // one can both be closed by a caller; without this guard the stale
    // close would tear down the *current* native session (closeSession
    // is argument-less and closes whatever session is active). See the
    // createSession comment and issue #308.
    if (_isClosed) return;
    _isClosed = true;

    // Cancel event subscription first to stop receiving events
    await _eventSubscription?.cancel();
    _eventSubscription = null;

    // Try to stop generation if possible (ignore errors on unsupported platforms)
    try {
      await platformService.stopGeneration();
    } on PlatformException catch (e) {
      // Ignore "not supported" errors, but rethrow others
      if (e.code != 'stop_not_supported') {
        if (kDebugMode) {
          edgeAiLog('Warning: Failed to stop generation: ${e.message}');
        }
      }
    } catch (e) {
      // Ignore other errors during cleanup
      if (kDebugMode) {
        edgeAiLog('Warning: Unexpected error during stop generation: $e');
      }
    }

    // Close controller after stopping subscription
    _asyncResponseController?.close();

    onClose();
    await platformService.closeSession();
  }
}

/// A concurrent MediaPipe `.task` session opened via
/// [MobileInferenceModel.openSession]. Independent of the legacy singleton
/// [MobileInferenceModelSession]: it routes every call through the
/// session-scoped `*ForSession` pigeon methods keyed by [sessionId], so N of
/// these can be live at once (MediaPipe holds N real `LlmInferenceSession`).
///
/// Generation is serialized across all sessions by the model's shared
/// [_generationMutex] — concurrent contexts, serialized inference, identical
/// to the `.litertlm` FFI path. Because only one session generates at a time,
/// the single `flutter_gemma_stream` EventChannel is unambiguous; this session
/// demuxes by filtering events whose `sessionId` matches its own.
class MultiSessionMobileInferenceModelSession extends InferenceModelSession {
  final int sessionId;
  final ModelType modelType;
  final ModelFileType fileType;
  final bool supportImage;
  final bool supportAudio;
  final String? systemInstruction;
  final Mutex generationMutex;
  final VoidCallback onClose;

  bool _isClosed = false;
  bool _systemInstructionSent = false;

  /// [stopGeneration] was called during the current turn.
  bool _stopAsked = false;

  /// Ends the turn that is running, if any; [close] calls it.
  void Function()? _endRunningTurn;

  /// What the native session holds, so a turn can be taken back (rule A).
  final NativeTurnLog _log = NativeTurnLog();

  /// Builds this native session again (same id), as the model first built
  /// it. Null in a session made for a test without one: a take-back then
  /// only forgets.
  final Future<void> Function()? recreateNative;

  MultiSessionMobileInferenceModelSession({
    required this.sessionId,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this.supportAudio,
    required this.generationMutex,
    required this.onClose,
    this.systemInstruction,
    this.recreateNative,
  });

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError('Session is closed');
    }
    if (_rebuildFailure case final failure?) {
      throw StateError(
        'This session could not be rebuilt after a turn was taken back '
        '($failure); open a new session.',
      );
    }
  }

  @override
  Future<int> sizeInTokens(String text) =>
      platformService.sizeInTokensForSession(sessionId, text);

  @override
  Future<void> addQueryChunk(Message message) async {
    _assertNotClosed();
    var messageToSend = message;
    if (message.isUser &&
        !_systemInstructionSent &&
        systemInstruction != null &&
        systemInstruction!.isNotEmpty) {
      _systemInstructionSent = true;
      _log.stagedSystemInstruction();
      messageToSend = message.copyWith(
        text: '[System: ${systemInstruction!}]\n\n${message.text}',
      );
    }
    final finalPrompt = messageToSend.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    if (message.hasImage && supportImage) {
      final images = message.images.isNotEmpty
          ? message.images
          : (message.imageBytes != null
                ? [message.imageBytes!]
                : const <Uint8List>[]);
      for (final image in images) {
        await platformService.addImageToSession(sessionId, image);
        _log.stage(NativeImage(image));
      }
    }
    if (message.hasAudio && message.audioBytes != null && supportAudio) {
      await platformService.addAudioToSession(sessionId, message.audioBytes!);
      _log.stage(NativeAudio(message.audioBytes!));
    }
    await platformService.addQueryChunkToSession(sessionId, finalPrompt);
    _log.stage(NativeText(finalPrompt));
  }

  /// See [MobileInferenceModelSession._endTurn].
  Future<void> _endTurn(String text, {required bool failed}) async {
    if (_isClosed) return;
    final takeBack = failed && !_stopAsked || _stopAsked && text.isEmpty;
    if (!takeBack) {
      _log.kept(
        text.isEmpty
            ? null
            : Message(
                text: text,
              ).transformToChatPrompt(type: modelType, fileType: fileType),
      );
      return;
    }
    final before = _log.takeBack();
    if (before == null) return;
    if (before.systemInstruction) _systemInstructionSent = false;
    final recreate = recreateNative;
    if (recreate == null) return;
    _rebuildFailure = await rebuildNativeSession(
      before: before.before,
      recreate: recreate,
      closeRebuilt: () => platformService.closeSessionId(sessionId),
      isClosed: () => _isClosed,
      send: (input) => switch (input) {
        NativeText(:final prompt) => platformService.addQueryChunkToSession(
          sessionId,
          prompt,
        ),
        NativeImage(:final bytes) => platformService.addImageToSession(
          sessionId,
          bytes,
        ),
        NativeAudio(:final bytes) => platformService.addAudioToSession(
          sessionId,
          bytes,
        ),
      },
    );
  }

  /// See [MobileInferenceModelSession._rebuildFailure].
  Object? _rebuildFailure;

  @override
  Future<String> getResponse({Message? message}) async {
    _assertNotClosed();
    _stopAsked = false;
    if (message != null) await addQueryChunk(message);
    // Serialize generation across sessions (mobile can't afford parallel
    // generations; also keeps the shared event channel unambiguous).
    return generationMutex.protect(() async {
      final String reply;
      try {
        reply = await platformService.generateResponseForSession(sessionId);
      } catch (_) {
        await _endTurn('', failed: true);
        rethrow;
      }
      await _endTurn(reply, failed: false);
      return reply;
    });
  }

  @override
  Stream<String> getResponseAsync({Message? message}) {
    _assertNotClosed();
    _stopAsked = false;

    // StreamController (not async*/yield*) so the mutex release is tied to the
    // controller lifecycle — it fires on done, error, AND consumer cancel /
    // abandon. With async*+yield* an abandoned stream would never run the
    // finally and would hold the generation mutex forever, deadlocking every
    // other session.
    final controller = StreamController<String>();
    StreamSubscription? subscription;
    var mutexHeld = false;
    var finished = false;
    final text = StringBuffer();

    /// Ends the turn once: records it in [_log] (kept, or taken back from the
    /// native session) before the generation lock goes, then delivers
    /// [error], if any, and the end.
    Future<void> endTurn({
      (Object, StackTrace)? error,
      bool cancelled = false,
    }) async {
      if (finished) return;
      finished = true;
      await subscription?.cancel();
      if (cancelled) _stopAsked = true;
      try {
        // Never throws: a failed rebuild is kept by the session, and the turn
        // keeps the engine's own error.
        await _endTurn(text.toString(), failed: error != null);
      } finally {
        if (mutexHeld) {
          mutexHeld = false;
          generationMutex.release();
        }
        if (error != null && !controller.isClosed) {
          controller.addError(error.$1, error.$2);
        }
        if (!controller.isClosed) await controller.close();
      }
    }

    // A close ends this turn: the native session it ran on is gone, and no
    // tagged done will come.
    _endRunningTurn = () => unawaited(endTurn());

    controller.onListen = () async {
      try {
        if (message != null) await addQueryChunk(message);
        await generationMutex.acquire();
        // Closed or cancelled while it waited: the turn has ended already and
        // would not release a lock taken after it.
        if (finished) {
          generationMutex.release();
          return;
        }
        mutexHeld = true;
        subscription = eventChannel.receiveBroadcastStream().listen(
          (event) {
            if (event is! Map) return;
            // Only consume events tagged for THIS session.
            if (event['sessionId'] != sessionId) return;
            if (finished) return;
            // Native emits generation errors as a TAGGED DATA event
            // {code: ERROR, sessionId, message} (not an EventChannel error,
            // which would be broadcast to every session and lose the id).
            if (event['code'] == 'ERROR') {
              unawaited(
                endTurn(
                  error: (
                    Exception(
                      event['message'] ?? 'Unknown async error occurred',
                    ),
                    StackTrace.current,
                  ),
                ),
              );
              return;
            }
            final partial = event['partialResult'] as String? ?? '';
            if (partial.isNotEmpty) {
              text.write(partial);
              controller.add(partial);
            }
            // Tagged completion (native sends done:true with our sessionId
            // rather than closing the whole channel via endOfStream).
            if (event['done'] == true) unawaited(endTurn());
          },
          onError: (Object error, StackTrace st) =>
              unawaited(endTurn(error: (error, st))),
        );
        unawaited(
          platformService
              .generateResponseAsyncForSession(sessionId)
              .then<void>(
                (_) {},
                // A synchronous native failure (before any event) must surface
                // and release the mutex, not hang the controller.
                onError: (Object e, StackTrace st) =>
                    unawaited(endTurn(error: (e, st))),
              ),
        );
      } catch (e, st) {
        await endTurn(error: (e, st));
      }
    };

    // Consumer cancelled / abandoned the stream: a stop. The mutex goes.
    controller.onCancel = () => endTurn(cancelled: true);

    return controller.stream;
  }

  /// How the turn ended, for core's chat: a stop is [TurnEnd.stopped] (the
  /// cancel's own error, iOS's among them, is not the turn's), a close the
  /// consumer did not ask for [TurnEnd.closed], so the chat keeps the
  /// partial reply (decision H). MediaPipe has no output cap here.
  @override
  EngineTurn startTurn() {
    _stopAsked = false;
    return reportedEngineTurn(
      getResponseAsync(),
      stopped: () => _stopAsked,
      closed: () => _isClosed,
      completed: () => TurnEnd.endOfSequence,
    );
  }

  @override
  Future<void> stopGeneration() async {
    _stopAsked = true;
    await platformService.stopGenerationForSession(sessionId);
  }

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _endRunningTurn?.call();
    _endRunningTurn = null;
    onClose();
    await platformService.closeSessionId(sessionId);
  }
}
