// What CommonEmbeddingModel talks to: an engine's pass, built, loaded and
// served one request at a time — in a worker isolate on native
// (embedding_host_io.dart), inline on the page on web (embedding_host_web.dart).
// Both run the same RequestPump, load check and failure encoding, so a model
// behaves the same on every platform.

import 'dart:async';

import 'embedding_exceptions.dart';
import 'embedding_input.dart';
import 'embedding_modality.dart';
import 'embedding_pass.dart';
import 'task_type.dart';

/// A running embedding pass.
abstract interface class EmbeddingHost {
  /// What the loaded pass reported.
  EmbeddingPassInfo get info;

  /// The model's modalities: the declared media plus text when the engine has
  /// a text tower (`checkLoadedPass`).
  Set<EmbeddingModality> get modalities;

  /// Sends one request. Text requests are served before media requests, FIFO
  /// within each; one runs at a time. Fails with an `EmbeddingException`:
  /// `EmbedderClosedException` (closed before it ran),
  /// `EmbeddingInputTooLongException`, or `EmbeddingEngineException`.
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType);

  /// Completes, with the reason, only when the host dies without being closed
  /// (a worker that crashed). Every request pending then has already failed.
  /// Never completes after a clean [close].
  Future<String> get unexpectedExit;

  /// Fails every request that has not started with `EmbedderClosedException`,
  /// lets the one in flight finish, then closes the pass. Idempotent; every
  /// caller gets the same teardown. Waits as long as that takes — nothing is
  /// ever killed, because a killed worker never frees its native model.
  Future<void> close();
}

/// Whether [input] goes to the media lane.
bool isMediaRequest(EmbeddingInput input) =>
    input.images.isNotEmpty || input.audio != null;

/// `print`, not `edgeAiLog`: edgeAiLog is silent in release, and release is
/// where a leaked native model or a hung close gets debugged. Used only for
/// abnormal states, so it costs nothing in the normal case.
void warnEmbeddingHost(String message) {
  // ignore: avoid_print
  print('[flutter_edge_ai] WARNING: $message');
}

/// "30 s", or "200 ms" for the short durations tests inject.
String describeHostDuration(Duration d) => d.inMilliseconds % 1000 == 0
    ? '${d.inSeconds} s'
    : '${d.inMilliseconds} ms';

/// Closes [pass], returning a failure as text — error and stack, since across
/// an isolate the stack is all the main side will ever see of it — instead of
/// throwing, so the caller still finishes its own teardown. Null means it
/// closed cleanly.
///
/// Reports nothing itself: every caller prints the text once, with what it
/// knows (engine, model, which close), where a release build shows it.
Future<String?> closePassReportingFailure(EmbeddingPass pass) async {
  try {
    await pass.close();
    return null;
  } catch (e, st) {
    return '$e\n$st';
  }
}

/// What a request that never ran fails with.
const closedBeforeRun = EmbedderClosedException(
  'The embedding model was closed before this request ran.',
);

/// Runs every step of a teardown, each in its own try/catch: a step that
/// throws never skips the ones after it. The first error reaches the caller
/// with its own stack; every later one is printed, so none is lost or
/// swapped in for the first. [what] names the teardown in those lines.
Future<void> runTeardown(
  String what,
  List<FutureOr<void> Function()> steps,
) async {
  Object? first;
  StackTrace? firstStack;
  for (final step in steps) {
    try {
      await step();
    } catch (e, st) {
      if (first == null) {
        first = e;
        firstStack = st;
      } else {
        warnEmbeddingHost('$what: a later step also failed: $e\n$st');
      }
    }
  }
  if (first != null) Error.throwWithStackTrace(first, firstStack!);
}
