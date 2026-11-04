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
/// keeps decoding). The next turn starts only once this one has ended and
/// that stop has returned, so a stop never lands on the next turn. A turn
/// cancelled while it still waits for the previous one never reaches the
/// engine.
@internal
final class StructuredSession extends InferenceModelSession {
  StructuredSession(this.engineSession, this.format, {required this.engine});

  /// The engine's own session.
  final InferenceModelSession engineSession;

  /// What every reply must be.
  final JsonSchemaResponseFormat format;

  /// The model's type, named when the engine breaks its contract.
  final Type engine;

  /// Completes when the last turn started here has settled: ended, and its
  /// stop (if it was cancelled) returned.
  Future<void> _lastTurn = Future<void>.value();

  /// A turn whose [EngineTurn.end] is the engine's end. A turn that ends
  /// without one — cancelled before it reached the engine: [TurnEnd.stopped];
  /// the engine failed to start it, gave no end, or its end failed:
  /// [TurnEnd.closed], with the error on the text.
  @override
  EngineTurn startTurn() {
    final reported = Completer<TurnEnd>();
    final settled = Completer<void>();
    late final StreamController<String> controller;
    StreamSubscription<String>? subscription;
    Future<TurnEnd>? engineEnd;
    var cancelled = false;
    var stopping = false;
    var textDone = false;
    var engineEnded = false;

    void report(TurnEnd end) {
      if (!reported.isCompleted) reported.complete(end);
    }

    void settle() {
      if (!settled.isCompleted) settled.complete();
    }

    Future<void> fail(Object error, [StackTrace? stack]) async {
      report(TurnEnd.closed);
      settle();
      controller.addError(error, stack);
      await controller.close();
    }

    controller = StreamController<String>(
      onListen: () async {
        final previous = _lastTurn;
        _lastTurn = settled.future;
        await previous;
        if (cancelled) {
          report(TurnEnd.stopped);
          settle();
          return;
        }
        final EngineTurn turn;
        try {
          turn = startEngineTurn(engineSession);
        } catch (error, stack) {
          await fail(error, stack);
          return;
        }
        final end = engineEnd = turn.end;
        if (end == null) {
          await fail(
            StateError(
              '$engine accepted a response format but cannot say how its '
              'turns end (EngineTurn.end is null): it must keep '
              'StructuredOutputSupport.none.',
            ),
          );
          return;
        }
        // The turn has ended once [end] completes; it has settled once a
        // stop asked for on cancel has returned too.
        unawaited(
          end.then(
            (value) {
              engineEnded = true;
              report(value);
              if (!stopping) settle();
            },
            onError: (Object _) {
              engineEnded = true;
              report(TurnEnd.closed);
              if (!stopping) settle();
            },
          ),
        );
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
            final TurnEnd turnEnd;
            try {
              turnEnd = await end;
            } catch (error, stack) {
              controller.addError(
                StateError(
                  '$engine broke the EngineTurn contract: its end completed '
                  'with an error ($error).',
                ),
                stack,
              );
              await controller.close();
              return;
            }
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
        // Still waiting for the previous turn: onListen sees [cancelled].
        if (active == null) return;
        stopping = !textDone && !engineEnded;
        await active.cancel();
        if (!stopping) return;
        // A stop: on most engines cancelling the text only detaches Dart.
        try {
          await engineSession.stopGeneration();
        } catch (error) {
          // There is no listener left to take it; a release build is where
          // a failed stop shows, and edgeAiLog is silent there.
          // ignore: avoid_print
          print(
            '[flutter_edge_ai] WARNING: stopping a cancelled structured turn '
            'failed ($error).',
          );
        }
        try {
          await engineEnd;
        } catch (_) {
          // Reported as closed above.
        }
        settle();
      },
    );
    return EngineTurn(text: controller.stream, end: reported.future);
  }

  @override
  Stream<String> getResponseAsync() => startTurn().text;

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
