// The runtime side's log sink and build mode (lib/src/runtime): by default the
// sink prints at the runtime's own level; bound to core (the adapter), it is
// core's edgeAiLog at the app's edgeAiLogLevel. The build mode is Flutter's
// kDebugMode/kReleaseMode, to the constant.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart'
    show EdgeAiLogLevel, edgeAiLogLevel;
import 'package:flutter_edge_ai_litertlm/src/adapter/runtime_log_binding.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;
import 'package:flutter_test/flutter_test.dart';

/// What [body] printed through `print`.
List<String> _printed(void Function() body) {
  final lines = <String>[];
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  late RuntimeLogLevel savedRuntimeLevel;
  late EdgeAiLogLevel savedCoreLevel;

  setUp(() {
    savedRuntimeLevel = runtimeLogLevel;
    savedCoreLevel = edgeAiLogLevel;
  });
  tearDown(() {
    runtimeLogLevel = savedRuntimeLevel;
    edgeAiLogLevel = savedCoreLevel;
    resetRuntimeLogSink();
  });

  test('the default sink prints at the runtime level: info at info, verbose '
      'only at verbose, nothing at none', () {
    runtimeLogLevel = RuntimeLogLevel.info;
    expect(
      _printed(() {
        runtimeLog('a');
        runtimeLog('b', verbose: true);
      }),
      ['a'],
    );

    runtimeLogLevel = RuntimeLogLevel.verbose;
    expect(
      _printed(() {
        runtimeLog('c');
        runtimeLog('d', verbose: true);
      }),
      ['c', 'd'],
    );

    runtimeLogLevel = RuntimeLogLevel.none;
    expect(_printed(() => runtimeLog('e')), isEmpty);
  });

  test('the default sink writes a lone surrogate as U+FFFD', () {
    expect(_printed(() => runtimeLog('x\uD800y')), ['xU+FFFDy']);
  });

  group('bound to core', () {
    late List<String?> debugPrinted;
    late DebugPrintCallback savedDebugPrint;

    setUp(() {
      debugPrinted = [];
      savedDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => debugPrinted.add(message);
      bindRuntimeLogToCore();
    });
    tearDown(() => debugPrint = savedDebugPrint);

    test('messages go through edgeAiLog at the app\'s level', () {
      edgeAiLogLevel = EdgeAiLogLevel.info;
      runtimeLog('a');
      runtimeLog('b', verbose: true);
      expect(debugPrinted, ['a']);

      edgeAiLogLevel = EdgeAiLogLevel.none;
      runtimeLog('c');
      expect(debugPrinted, ['a']);
    });

    test('the level handed to a spawned isolate is the app\'s', () {
      runtimeLogLevel = RuntimeLogLevel.none;
      edgeAiLogLevel = EdgeAiLogLevel.verbose;
      expect(currentRuntimeLogLevel(), RuntimeLogLevel.verbose);
      edgeAiLogLevel = EdgeAiLogLevel.none;
      expect(currentRuntimeLogLevel(), RuntimeLogLevel.none);
    });
  });

  test('a replaced sink gets every message with its verbosity', () {
    final got = <(String, bool)>[];
    runtimeLogSink = (message, {verbose = false}) =>
        got.add((message, verbose));
    runtimeLog('a');
    runtimeLog('b', verbose: true);
    expect(got, [('a', false), ('b', true)]);
  });

  test('the build mode is Flutter\'s, constant for constant', () {
    expect(isReleaseBuild, kReleaseMode);
    expect(isProductBuild, kReleaseMode);
    expect(isProfileBuild, kProfileMode);
    expect(isDebugBuild, kDebugMode);
  });
}
