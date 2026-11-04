import 'dart:async';
import 'dart:typed_data' show Uint8List;

import 'package:flutter_edge_ai/engine.dart'
    show
        EngineTurn,
        InferenceModelSession,
        JsonSchemaResponseFormat,
        Message,
        MessageExtension,
        ModelFileType,
        ModelType,
        SessionMetrics,
        TurnEnd;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_ai/flutter_local_ai.dart'
    show LocalAiGenerationException, LocalAiSession;
import 'package:meta/meta.dart' show experimental, internal;

import 'structured_output.dart' show builtInWireSchema;

/// A generation session on an OS built-in model, adapting flutter_local_ai's
/// [LocalAiSession] to flutter_edge_ai's [InferenceModelSession].
///
/// Thin by design: buffering, streaming, cancellation, session demultiplexing
/// and token counting all live in flutter_local_ai. This class only translates
/// flutter_edge_ai's [Message] into the text and images the session takes.
class BuiltInAiSession extends InferenceModelSession {
  BuiltInAiSession({
    required this._session,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this._onClose,
    this.maxNumImages,
  });

  final LocalAiSession _session;
  final ModelType modelType;
  final ModelFileType fileType;
  final bool supportImage;
  final int? maxNumImages;
  final void Function() _onClose;

  /// The underlying flutter_local_ai session.
  ///
  /// This is the supported escape hatch for the capabilities flutter_edge_ai's
  /// [InferenceModelSession] has no slot for — native tool calling, and
  /// schema-constrained output (`getStructuredResponse`) where
  /// `responseFormat` is not enabled yet. It is the same
  /// native session this adapter drives, so anything read or generated through
  /// it shares this session's context.
  ///
  /// Experimental: this is a `flutter_local_ai` type, so it may change with
  /// that package's next major release independently of this one.
  @experimental
  LocalAiSession get localAiSession => _session;

  @override
  Future<void> addQueryChunk(Message message) async {
    if (message.hasAudio) {
      throw UnsupportedError('Audio is not supported by built-in OS models');
    }
    if (message.hasImage && !supportImage) {
      throw UnsupportedError('Enable vision before adding an image.');
    }
    final imageCount = message.images.isNotEmpty
        ? message.images.length
        : (message.hasImage ? 1 : 0);
    if (maxNumImages != null && imageCount > maxNumImages!) {
      throw ArgumentError('Message exceeds maxNumImages ($maxNumImages).');
    }
    final prompt = message.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    // Images first, so the host has them buffered before the text that refers
    // to them — the ordering the native multimodal requests expect.
    if (message.hasImage && supportImage) {
      final images = message.images.isNotEmpty
          ? message.images
          : (message.imageBytes != null
                ? <Uint8List>[message.imageBytes!]
                : const <Uint8List>[]);
      for (final image in images) {
        await _session.addImage(image);
      }
    }
    await _session.addQueryChunk(prompt);
  }

  // flutter_local_ai checks that the session is open before it returns, so a
  // closed session throws synchronously; here the failure is the future's
  // and the stream's, as on every other engine (B82).
  @override
  Future<String> getResponse() => Future.sync(_session.getResponse);

  @override
  Stream<String> getResponseAsync() {
    try {
      return _session.getResponseAsync();
    } catch (error, stack) {
      return Stream.error(error, stack);
    }
  }

  @override
  Future<int> sizeInTokens(String text) => _session.sizeInTokens(text);

  @override
  Future<void> stopGeneration() => _session.stopGeneration();

  /// Built-in OS models expose no benchmark counters, so there is nothing
  /// truthful to report here. Empty metrics beat invented ones; use
  /// [sizeInTokens] for the one number that is real.
  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {
    // Only once the native session is gone: a failed close leaves it open and
    // owned by the model, so it can be retried.
    await _session.close();
    _onClose();
  }
}

/// A built-in session opened with a response format: every turn sends the
/// format's schema and reports how it ended.
///
/// Not exported: an app holds core's structured session around this one,
/// and core checks every reply. The reply arrives as one chunk
/// (`StructuredDelivery.buffered`): flutter_local_ai has no streamed
/// structured call.
@internal
final class StructuredBuiltInAiSession extends BuiltInAiSession {
  StructuredBuiltInAiSession({
    required super.session,
    required super.modelType,
    required super.fileType,
    required super.supportImage,
    required super.onClose,
    required this.format,
    super.maxNumImages,
  });

  /// What every reply must be; its schema is sent with each turn.
  final JsonSchemaResponseFormat format;

  _StructuredTurn? _turn;

  /// The OS's codes for a full context window: the FoundationModels names on
  /// OS 27 and OS 26 (a `GENERATION_ERROR` detail).
  static const _contextLimitCodes = {
    'contextSizeExceeded',
    'exceededContextWindowSize',
  };

  @override
  EngineTurn startTurn() {
    final turn = _turn = _StructuredTurn();
    turn.text.onListen = () {
      // Ended before anyone listened (a close, a stop): nothing to send.
      if (turn.ended) return;
      Future<String> reply;
      try {
        reply = _session.getStructuredResponse(builtInWireSchema(format));
      } catch (error, stack) {
        // A closed session throws synchronously (B82).
        reply = Future.error(error, stack);
      }
      reply.then(
        (text) => turn.finish(turn.askedEnd ?? TurnEnd.endOfSequence, text),
        onError: (Object error, StackTrace stack) {
          final asked = turn.askedEnd;
          if (asked != null) {
            turn.finish(asked);
          } else if (_isContextLimit(error)) {
            turn.finish(TurnEnd.contextLimit);
          } else if (error is PlatformException &&
              error.code == 'PROMPT_TOO_LONG') {
            // Windows keeps the prompt that overflowed in its native
            // transcript (one string it only appends to), and
            // flutter_local_ai can neither trim it nor rebuild the session
            // without it. Every later turn would overflow again, so the
            // session is not usable as contextLimit promises: closed.
            turn.finish(TurnEnd.closed);
          } else if (error is PlatformException &&
              error.code == 'STRUCTURED_OUTPUT_INVALID' &&
              error.details is String) {
            // Windows finished a reply that strayed from the schema and sends
            // it in the details: handed to core as the reply, so core's check
            // reports it (NonConformingStructuredOutputException).
            turn.finish(TurnEnd.endOfSequence, error.details as String);
          } else {
            turn.fail(error, stack);
          }
        },
      );
    };
    // A cancelled subscription is a stop, at the model too. A stop that fails
    // here has no listener left to take it; the turn still ends when the
    // platform call settles.
    turn.text.onCancel = () async {
      if (turn.ended) return;
      try {
        await stopGeneration();
      } catch (error) {
        // ignore: avoid_print
        print(
          '[flutter_edge_ai_builtin_ai] WARNING: stopping a cancelled '
          'structured turn failed ($error).',
        );
      }
    };
    return EngineTurn(text: turn.text.stream, end: turn.end.future);
  }

  /// A full context window on Apple (the FoundationModels codes). Windows's
  /// overflow ends the turn as closed (see [startTurn]); Chrome's is a JS
  /// error the platform passes through unclassified.
  static bool _isContextLimit(Object error) =>
      error is LocalAiGenerationException &&
      _contextLimitCodes.contains(error.errorCode);

  @override
  Stream<String> getResponseAsync() => startTurn().text;

  @override
  Future<String> getResponse() => getResponseAsync().join();

  /// Stops the turn at the model. The turn stays open until the platform
  /// call has settled, so the next turn never meets a busy session; it then
  /// ends as [TurnEnd.stopped], whatever the platform answered (Apple fails a
  /// cancelled request, Chrome returns '', Windows fails it as cancelled). A
  /// second stop of the same turn does not reach the model again.
  @override
  Future<void> stopGeneration() async {
    final turn = _turn;
    if (turn != null && !turn.ended) {
      if (turn.stopRequested) return;
      turn.stopRequested = true;
    }
    await super.stopGeneration();
  }

  /// Closes the native session first: a close that fails can be retried, and
  /// the turn keeps running until one succeeds. Then a turn still running
  /// ends as [TurnEnd.closed].
  @override
  Future<void> close() async {
    final turn = _turn;
    turn?.closing = true;
    try {
      await super.close();
    } catch (_) {
      turn?.closing = false;
      rethrow;
    }
    turn?.finish(TurnEnd.closed);
  }

  /// The model is closing under this session: a turn whose platform call
  /// fails from now on ends as [TurnEnd.closed].
  void modelClosing() => _turn?.closing = true;

  /// The model has closed: a turn still running ends as [TurnEnd.closed].
  void modelClosed() => _turn?.finish(TurnEnd.closed);
}

/// One structured turn: its text and how it ended, each settled once.
final class _StructuredTurn {
  final text = StreamController<String>();
  final end = Completer<TurnEnd>();
  bool stopRequested = false;
  bool closing = false;

  bool get ended => end.isCompleted;

  /// The end the consumer caused (a close before a stop), or null.
  TurnEnd? get askedEnd => closing
      ? TurnEnd.closed
      : stopRequested
      ? TurnEnd.stopped
      : null;

  /// Delivers [reply] (if any), closes the text, then reports [how].
  void finish(TurnEnd how, [String reply = '']) {
    if (ended) return;
    if (reply.isNotEmpty) text.add(reply);
    unawaited(text.close());
    end.complete(how);
  }

  /// Puts [error] on the text. A failed turn has no end of its own, and
  /// core's structured session reads none after an error; it is reported as
  /// [TurnEnd.closed], as core reports a turn that failed to start.
  void fail(Object error, StackTrace stack) {
    if (ended) return;
    text.addError(error, stack);
    unawaited(text.close());
    end.complete(TurnEnd.closed);
  }
}
