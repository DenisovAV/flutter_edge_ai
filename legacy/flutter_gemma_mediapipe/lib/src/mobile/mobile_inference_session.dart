import 'dart:async';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mutex/mutex.dart';

import 'package:flutter_gemma/core/extensions.dart';
import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show InferenceModelSession, SessionMetrics;

import 'package:flutter_gemma_mediapipe/pigeon.g.dart';

/// Shared MediaPipe pigeon client. Library-level (non-private) so the engine
/// (`mediapipe_engine.dart`) and both session classes use the SAME channel
/// instance — its own `flutter_gemma`-domain pigeon channel, distinct from
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
  });

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
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
    var messageToSend = message;
    if (message.isUser &&
        !_systemInstructionSent &&
        systemInstruction != null &&
        systemInstruction!.isNotEmpty &&
        !_isNativeSystemInstruction) {
      _systemInstructionSent = true;
      messageToSend = message.copyWith(
        text: '[System: ${systemInstruction!}]\n\n${message.text}',
      );
    }
    gemmaLog(
      '[MobileSession.addQueryChunk] modelType=$modelType, fileType=$fileType, msgType=${message.type}',
      level: GemmaLogLevel.verbose,
    );
    final finalPrompt = messageToSend.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    gemmaLog(
      '[MobileSession.addQueryChunk] finalPrompt length=${finalPrompt.length}',
      level: GemmaLogLevel.verbose,
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
  }

  Future<void> _addImage(Uint8List imageBytes) async {
    _assertNotClosed();
    if (!supportImage) {
      throw ArgumentError('This model does not support images');
    }
    await platformService.addImage(imageBytes);
  }

  Future<void> _addAudio(Uint8List audioBytes) async {
    _assertNotClosed();
    if (!supportAudio) {
      throw ArgumentError('This model does not support audio');
    }
    await platformService.addAudio(audioBytes);
  }

  @override
  Future<String> getResponse({Message? message}) async {
    _assertNotClosed();
    await _awaitLastResponse();
    final completer = _responseCompleter = Completer<void>();
    try {
      if (message != null) {
        await addQueryChunk(message);
      }
      return await platformService.generateResponse();
    } finally {
      completer.complete();
    }
  }

  @override
  Stream<String> getResponseAsync({Message? message}) async* {
    _assertNotClosed();
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
      unawaited(platformService.generateResponseAsync());

      yield* controller.stream;
    } finally {
      completer.complete();
      _asyncResponseController = null;
    }
  }

  @override
  Future<void> stopGeneration() async {
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
          gemmaLog('Warning: Failed to stop generation: ${e.message}');
        }
      }
    } catch (e) {
      // Ignore other errors during cleanup
      if (kDebugMode) {
        gemmaLog('Warning: Unexpected error during stop generation: $e');
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

  MultiSessionMobileInferenceModelSession({
    required this.sessionId,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this.supportAudio,
    required this.generationMutex,
    required this.onClose,
    this.systemInstruction,
  });

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError('Session is closed');
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
      }
    }
    if (message.hasAudio && message.audioBytes != null && supportAudio) {
      await platformService.addAudioToSession(sessionId, message.audioBytes!);
    }
    await platformService.addQueryChunkToSession(sessionId, finalPrompt);
  }

  @override
  Future<String> getResponse({Message? message}) async {
    _assertNotClosed();
    if (message != null) await addQueryChunk(message);
    // Serialize generation across sessions (mobile can't afford parallel
    // generations; also keeps the shared event channel unambiguous).
    return generationMutex.protect(
      () => platformService.generateResponseForSession(sessionId),
    );
  }

  @override
  Stream<String> getResponseAsync({Message? message}) {
    _assertNotClosed();

    // StreamController (not async*/yield*) so the mutex release is tied to the
    // controller lifecycle — it fires on done, error, AND consumer cancel /
    // abandon. With async*+yield* an abandoned stream would never run the
    // finally and would hold the generation mutex forever, deadlocking every
    // other session.
    final controller = StreamController<String>();
    StreamSubscription? subscription;
    var mutexHeld = false;
    var finished = false;

    Future<void> cleanup() async {
      if (finished) return;
      finished = true;
      await subscription?.cancel();
      if (mutexHeld) {
        mutexHeld = false;
        generationMutex.release();
      }
    }

    controller.onListen = () async {
      try {
        if (message != null) await addQueryChunk(message);
        await generationMutex.acquire();
        mutexHeld = true;
        subscription = eventChannel.receiveBroadcastStream().listen(
          (event) {
            if (event is! Map) return;
            // Only consume events tagged for THIS session.
            if (event['sessionId'] != sessionId) return;
            if (controller.isClosed) return;
            // Native emits generation errors as a TAGGED DATA event
            // {code: ERROR, sessionId, message} (not an EventChannel error,
            // which would be broadcast to every session and lose the id).
            if (event['code'] == 'ERROR') {
              controller.addError(
                Exception(event['message'] ?? 'Unknown async error occurred'),
              );
              cleanup();
              controller.close();
              return;
            }
            final partial = event['partialResult'] as String? ?? '';
            if (partial.isNotEmpty) controller.add(partial);
            // Tagged completion (native sends done:true with our sessionId
            // rather than closing the whole channel via endOfStream).
            if (event['done'] == true) {
              cleanup();
              controller.close();
            }
          },
          onError: (error, st) {
            if (!controller.isClosed) controller.addError(error, st);
            cleanup();
            if (!controller.isClosed) controller.close();
          },
        );
        unawaited(
          platformService.generateResponseAsyncForSession(sessionId).catchError((
            Object e,
            StackTrace st,
          ) {
            // A synchronous native failure (before any event) must surface and
            // release the mutex, not hang the controller.
            if (!controller.isClosed) controller.addError(e, st);
            cleanup();
            if (!controller.isClosed) controller.close();
          }),
        );
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
        await cleanup();
        if (!controller.isClosed) await controller.close();
      }
    };

    // Consumer cancelled / abandoned the stream — release the mutex.
    controller.onCancel = () async {
      await cleanup();
    };

    return controller.stream;
  }

  @override
  Future<void> stopGeneration() async {
    await platformService.stopGenerationForSession(sessionId);
  }

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    onClose();
    await platformService.closeSessionId(sessionId);
  }
}
