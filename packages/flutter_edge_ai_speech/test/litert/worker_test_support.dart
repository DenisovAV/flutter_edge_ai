// Helpers shared by `stt_worker_test.dart` and `tts_worker_test.dart`.
//
// The fake engines in those tests run INSIDE the worker isolate, so the test
// on the main isolate cannot read their state. Each fake appends one line per
// call to a log file instead; the writes are synchronous and flushed, so a
// line is on disk before the call returns — and a worker that was killed
// never writes the lines that come after the kill.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Splits a fake's configuration string `<mode>@<log path>` (the log part is
/// optional) into its two halves.
(String mode, String? logPath) parseFakeConfig(String config) {
  final at = config.indexOf('@');
  return at < 0
      ? (config, null)
      : (config.substring(0, at), config.substring(at + 1));
}

/// Appends [line] to the log at [path]; a null path logs nothing.
void appendLogLine(String? path, String line) {
  if (path == null) return;
  File(path).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// Every line written to [log] so far.
List<String> linesOf(File log) =>
    log.existsSync() ? log.readAsLinesSync() : const <String>[];

/// Waits until [log] contains [line], failing the test after 10 s.
Future<void> waitForLine(File log, String line) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!linesOf(log).contains(line)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the worker never logged "$line"');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Settles [future] into its value or its error, so a request that fails
/// before the test looks at it is never reported as unhandled.
Future<Object?> outcomeOf<T>(Future<T> future) =>
    future.then<Object?>((v) => v, onError: (Object e) => e);

/// Runs [body] and returns every line it — and everything it started —
/// printed. The worker handles print from callbacks registered while it was
/// spawned, so the spawn must happen inside [body].
Future<List<String>> capturePrints(Future<void> Function() body) async {
  final printed = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => printed.add(line),
    ),
  );
  return printed;
}

/// A request that failed because the worker closed before running it.
Matcher closedBeforeRun(String workerName) => isA<StateError>().having(
  (e) => e.message,
  'message',
  '$workerName closed before this request ran',
);
