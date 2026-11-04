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
import 'package:flutter_local_ai/flutter_local_ai.dart'
    show LocalAiGenerationException, LocalAiSession;
import 'package:meta/meta.dart' show experimental, internal;

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
  /// OS 27 and OS 26.
  static const _contextLimitCodes = {
    'contextSizeExceeded',
    'exceededContextWindowSize',
  };

  @override
  EngineTurn startTurn() {
    final turn = _turn = _StructuredTurn();
    turn.text.onListen = () {
      Future<String> reply;
      try {
        reply = _session.getStructuredResponse(format.schema);
      } catch (error, stack) {
        // A closed session throws synchronously (B82).
        reply = Future.error(error, stack);
      }
      reply.then(
        (text) => turn.finish(
          turn.stopRequested ? TurnEnd.stopped : TurnEnd.endOfSequence,
          text,
        ),
        onError: (Object error, StackTrace stack) {
          if (turn.stopRequested) {
            turn.finish(TurnEnd.stopped);
          } else if (error is LocalAiGenerationException &&
              _contextLimitCodes.contains(error.errorCode)) {
            turn.finish(TurnEnd.contextLimit);
          } else {
            turn.fail(error, stack);
          }
        },
      );
    };
    // A cancelled subscription is a stop, at the model too.
    turn.text.onCancel = () async {
      if (!turn.ended) await stopGeneration();
    };
    return EngineTurn(text: turn.text.stream, end: turn.end.future);
  }

  @override
  Stream<String> getResponseAsync() => startTurn().text;

  @override
  Future<String> getResponse() => getResponseAsync().join();

  /// Stops the turn at the model and ends it as [TurnEnd.stopped], whatever
  /// the platform then answers (Apple fails a cancelled request, Chrome
  /// returns '').
  @override
  Future<void> stopGeneration() async {
    final turn = _turn;
    if (turn != null && !turn.ended) turn.stopRequested = true;
    await super.stopGeneration();
    turn?.finish(TurnEnd.stopped);
  }

  @override
  Future<void> close() async {
    _turn?.finish(TurnEnd.closed);
    await super.close();
  }

  /// The model closed under this session: a turn still running ends as
  /// [TurnEnd.closed].
  void modelClosed() => _turn?.finish(TurnEnd.closed);
}

/// One structured turn: its text and how it ended, each settled once.
final class _StructuredTurn {
  final text = StreamController<String>();
  final end = Completer<TurnEnd>();
  bool stopRequested = false;

  bool get ended => end.isCompleted;

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
