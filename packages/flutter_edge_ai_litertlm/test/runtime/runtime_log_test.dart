// The runtime side's log sink and build mode (lib/src/runtime): by default
// they are core's edgeAiLog and Flutter's kDebugMode/kReleaseMode, to the
// message and to the constant; a replaced sink gets every message.

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart'
    show EdgeAiLogLevel, edgeAiLogLevel;
import 'package:flutter_edge_ai_litertlm/src/runtime/build_mode.dart';
import 'package:flutter_edge_ai_litertlm/src/runtime/runtime_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runtime log', () {
    late List<String?> printed;
    late DebugPrintCallback savedPrint;
    late EdgeAiLogLevel savedLevel;

    setUp(() {
      printed = [];
      savedPrint = debugPrint;
      savedLevel = edgeAiLogLevel;
      debugPrint = (message, {wrapWidth}) => printed.add(message);
    });
    tearDown(() {
      debugPrint = savedPrint;
      edgeAiLogLevel = savedLevel;
      resetRuntimeLogSink();
    });

    test('defaults to core\'s edgeAiLog: info at info, verbose only at '
        'verbose, nothing at none', () {
      edgeAiLogLevel = EdgeAiLogLevel.info;
      runtimeLog('a');
      runtimeLog('b', verbose: true);
      expect(printed, ['a']);

      edgeAiLogLevel = EdgeAiLogLevel.verbose;
      runtimeLog('c');
      runtimeLog('d', verbose: true);
      expect(printed, ['a', 'c', 'd']);

      edgeAiLogLevel = EdgeAiLogLevel.none;
      runtimeLog('e');
      expect(printed, ['a', 'c', 'd']);
    });

    test('a replaced sink gets every message with its verbosity', () {
      final got = <(String, bool)>[];
      runtimeLogSink = (message, {verbose = false}) =>
          got.add((message, verbose));
      runtimeLog('a');
      runtimeLog('b', verbose: true);
      expect(got, [('a', false), ('b', true)]);
      expect(printed, isEmpty, reason: 'edgeAiLog is no longer the sink');

      resetRuntimeLogSink();
      runtimeLog('c');
      expect(printed, ['c']);
    });
  });

  test('the build mode is Flutter\'s, constant for constant', () {
    expect(isReleaseBuild, kReleaseMode);
    expect(isProductBuild, kReleaseMode);
    expect(isProfileBuild, kProfileMode);
    expect(isDebugBuild, kDebugMode);
  });
}
