import 'dart:async';

import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_edge_ai/src/message.dart';
import 'package:meta/meta.dart' show internal, visibleForTesting;

import 'reply_validation.dart';
import 'response_format.dart';

/// How long a structured turn whose engine text failed waits for that text
/// to close before it ends the turn without it: the same 5 s an
/// `InferenceChat` waits (`chatTurnErrorEndTimeout`), for an app that holds
/// the session from `openSession(responseFormat:)` with no chat around it. An
/// engine that keeps the SPI contract ends its text right after an error.
@visibleForTesting
Duration structuredTurnErrorEndTimeout = const Duration(seconds: 5);

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
/// engine. After an error on the engine's text, the turn waits at most
/// [structuredTurnErrorEndTimeout] for that text to close; then it ends
/// anyway and lets the engine's text go as a cancel does (a stop, and the
/// next turn waits for its end).
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
    var lettingGo = false;
    Timer? bound;

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

    /// Lets the engine's text go, once: on a cancel, or when a failed text
    /// outlived [structuredTurnErrorEndTimeout]. A turn the engine has not
    /// ended is stopped, and settles only when the stop has returned and the
    /// end has come.
    Future<void> letGo() async {
      final active = subscription;
      // Still waiting for the previous turn: onListen sees [cancelled].
      if (active == null || lettingGo) return;
      lettingGo = true;
      stopping = !textDone && !engineEnded;
      await active.cancel();
      if (!stopping) return;
      // A stop: on most engines cancelling the text only detaches Dart.
      try {
        await engineSession.stopGeneration();
      } catch (error) {
        // There is no listener left to take it; a release build is where a
        // failed stop shows, and edgeAiLog is silent there.
        // ignore: avoid_print
        print(
          '[flutter_edge_ai] WARNING: stopping a structured turn that was '
          'cancelled or whose failed text never closed failed ($error).',
        );
      }
      try {
        await engineEnd;
      } catch (_) {
        // Reported as closed above.
      }
      settle();
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
            controller.addError(error, stack);
            if (failed) return;
            failed = true;
            // An engine whose failed text never closes cannot hold the turn.
            bound = Timer(structuredTurnErrorEndTimeout, () {
              unawaited(controller.close());
              unawaited(letGo());
            });
          },
          onDone: () async {
            textDone = true;
            bound?.cancel();
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
        bound?.cancel();
        await letGo();
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
