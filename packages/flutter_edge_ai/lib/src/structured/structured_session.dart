import 'dart:async';

import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_edge_ai/src/message.dart';
import 'package:meta/meta.dart' show internal;

import 'reply_validation.dart';
import 'response_format.dart';

/// Core's session around an engine session opened with a [format]: every
/// reply is checked before the caller sees it end.
///
/// Each turn runs over the engine's `startTurn`. After the last chunk it
/// waits for the turn's end: anything but [TurnEnd.endOfSequence] is an
/// `IncompleteStructuredOutputException`, a complete reply that is not a
/// value of [format] a `NonConformingStructuredOutputException`; either is
/// the stream's last event. An error of the engine's own is passed on as it
/// is, and the reply is not checked after it.
///
/// A cancelled subscription is a stop: the engine's [stopGeneration] is
/// called (on most engines a cancel alone only detaches Dart while native
/// keeps decoding), and the next turn starts only once this one has ended.
@internal
final class StructuredSession extends InferenceModelSession {
  StructuredSession(this.engineSession, this.format, {required this.engine});

  /// The engine's own session.
  final InferenceModelSession engineSession;

  /// What every reply must be.
  final JsonSchemaResponseFormat format;

  /// The model's type, named when the engine breaks its contract.
  final Type engine;

  /// Completes when the last turn started here has ended.
  Future<void> _lastTurn = Future<void>.value();

  @override
  Stream<String> getResponseAsync() {
    late final StreamController<String> controller;
    StreamSubscription<String>? subscription;
    Future<TurnEnd>? end;
    var cancelled = false;
    var textDone = false;
    final ended = Completer<void>();

    void finish() {
      if (!ended.isCompleted) ended.complete();
    }

    controller = StreamController<String>(
      onListen: () async {
        final previous = _lastTurn;
        _lastTurn = ended.future;
        await previous;
        if (cancelled) {
          finish();
          return;
        }
        final EngineTurn turn;
        try {
          turn = startEngineTurn(engineSession);
        } catch (error, stack) {
          finish();
          controller.addError(error, stack);
          await controller.close();
          return;
        }
        end = turn.end;
        if (end == null) {
          finish();
          controller.addError(
            StateError(
              '$engine accepted a response format but cannot say how its '
              'turns end (EngineTurn.end is null): it must keep '
              'StructuredOutputSupport.none.',
            ),
          );
          await controller.close();
          return;
        }
        // The turn has ended once [end] completes, whatever the consumer does.
        unawaited(end!.then((_) => finish(), onError: (_) => finish()));
        final text = StringBuffer();
        var failed = false;
        subscription = turn.text.listen(
          (chunk) {
            text.write(chunk);
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            failed = true;
            controller.addError(error, stack);
          },
          onDone: () async {
            textDone = true;
            final turnEnd = await end!;
            if (!failed) {
              final failure = structuredReplyFailure(
                format,
                text.toString(),
                turnEnd,
              );
              if (failure != null) controller.addError(failure);
            }
            await controller.close();
          },
        );
        if (controller.isPaused) subscription!.pause();
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        cancelled = true;
        final active = subscription;
        if (active == null) return;
        await active.cancel();
        if (textDone) return;
        // A stop: on most engines cancelling the text only detaches Dart.
        try {
          await engineSession.stopGeneration();
        } finally {
          await end;
        }
      },
    );
    return controller.stream;
  }

  @override
  Future<String> getResponse() => getResponseAsync().join();

  @override
  Future<int> sizeInTokens(String text) => engineSession.sizeInTokens(text);

  @override
  Future<void> addQueryChunk(Message message) =>
      engineSession.addQueryChunk(message);

  @override
  Future<void> stopGeneration() => engineSession.stopGeneration();

  @override
  SessionMetrics getSessionMetrics() => engineSession.getSessionMetrics();

  @override
  Future<void> close() => engineSession.close();
}

/// The engine's own session behind [session]: [session] itself unless it is
/// core's [StructuredSession].
@internal
InferenceModelSession engineSessionOf(InferenceModelSession session) =>
    session is StructuredSession ? session.engineSession : session;

/// The format [session] enforces, or null for a plain session.
@internal
JsonSchemaResponseFormat? responseFormatOf(InferenceModelSession session) =>
    session is StructuredSession ? session.format : null;
