// Helpers shared by `stt_worker_test.dart` and `tts_worker_test.dart`.
//
// The fake engines in those tests run INSIDE the worker isolate, so the test
// on the main isolate cannot read their state. Each fake appends one line per
// call to a log file instead; the writes are synchronous and flushed, so a
// line is on disk before the call returns — and a worker that was killed
// never writes the lines that come after the kill.
//
// A fake that must hold a call — a native call that has not returned yet —
// blocks on a gate: it waits until the file `<log>.release` exists. The test
// creates that file when it is ready, for a close test after it has already
// sent the close, so the order is fixed by the test and not by how fast the
// machine is. Every gated log is also released in a teardown, and the gate
// gives up on its own after [_gateDeadline], so a failing test never leaves a
// worker blocked for good.
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

const _gateDeadline = Duration(seconds: 30);

/// Blocks this isolate — no events, no microtasks — until the gate of the log
/// at [logPath] is released, the way a synchronous native call does.
void blockUntilReleased(String? logPath) {
  final release = File('$logPath.release');
  final deadline = DateTime.now().add(_gateDeadline);
  while (!release.existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('fake gate was never released');
    }
    sleep(const Duration(milliseconds: 5));
  }
}

/// Opens the gate of [log], letting the call it holds return.
void release(File log) => File('${log.path}.release').createSync();

/// A log in [dir] whose gate is also opened in a teardown, so a test that
/// fails before releasing it never leaves a worker blocked behind it.
File gatedLog(Directory dir, String name) {
  final log = File('${dir.path}/$name.log');
  addTearDown(() {
    final gate = File('${log.path}.release');
    if (!gate.existsSync()) gate.createSync();
  });
  return log;
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

/// Waits until a line of [printed] contains [text], failing after 10 s.
Future<void> waitForPrint(List<String> printed, String text) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!printed.any((l) => l.contains(text))) {
    if (DateTime.now().isAfter(deadline)) {
      fail('nothing printed "$text"; got: ${printed.join('\n')}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Settles [future] into its value or its error, so a request that fails
/// before the test looks at it is never reported as unhandled.
Future<Object?> outcomeOf<T>(Future<T> future) =>
    future.then<Object?>((v) => v, onError: (Object e) => e);

/// A zone that adds every printed line to [printed]. The workers print from
/// callbacks registered while they were spawned or closed, so those calls
/// must happen inside it.
ZoneSpecification capturePrintsInto(List<String> printed) =>
    ZoneSpecification(print: (self, parent, zone, line) => printed.add(line));

/// Runs [body] and returns every line it — and everything it started —
/// printed.
Future<List<String>> capturePrints(Future<void> Function() body) async {
  final printed = <String>[];
  await runZoned(body, zoneSpecification: capturePrintsInto(printed));
  return printed;
}

/// A request that failed because the worker closed before running it — the
/// worker's own answer, not the main isolate's safety net.
Matcher closedBeforeRun(String workerName) => isA<StateError>().having(
  (e) => e.message,
  'message',
  '$workerName closed before this request ran',
);

/// An error whose `toString` throws: serving it as a reply throws too, which
/// is the one way a test can make a worker's serving loop itself fail.
class UnprintableError {
  @override
  String toString() =>
      throw StateError('fake error that cannot describe itself');
}
