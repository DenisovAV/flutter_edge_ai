import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

void main() {
  group('EdgeAiLogLevel ordering invariant', () {
    test(
      'severity order is none < info < verbose (edgeAiLog filters on .index)',
      () {
        expect(EdgeAiLogLevel.none.index, lessThan(EdgeAiLogLevel.info.index));
        expect(EdgeAiLogLevel.info.index, lessThan(EdgeAiLogLevel.verbose.index));
      },
    );
  });

  group('sanitizeForLog', () {
    test('replaces a lone U+FFFD with literal text', () {
      expect(sanitizeForLog('a�b'), 'aU+FFFDb');
    });

    test('replaces every U+FFFD occurrence', () {
      expect(sanitizeForLog('��'), 'U+FFFDU+FFFD');
    });

    test('leaves ordinary text untouched', () {
      const s = 'The UTF-8 replacement character is...';
      expect(sanitizeForLog(s), s);
    });

    test('leaves valid emoji / multi-byte text untouched', () {
      const s = 'привет 🚀 你好';
      expect(sanitizeForLog(s), s);
    });

    test('handles empty string', () {
      expect(sanitizeForLog(''), '');
    });

    test('replaces a lone HIGH surrogate at end of string', () {
      final lone = String.fromCharCode(0xD83D);
      expect(sanitizeForLog('ab$lone'), 'abU+FFFD');
    });

    test('replaces a lone LOW surrogate', () {
      final lone = String.fromCharCode(0xDE80);
      expect(sanitizeForLog('${lone}x'), 'U+FFFDx');
    });

    test('keeps a valid surrogate pair', () {
      const rocket = '🚀';
      expect(sanitizeForLog('go $rocket now'), 'go 🚀 now');
    });

    test('matches the exact bytes from the #306 repro', () {
      expect(sanitizeForLog('�** ('), 'U+FFFD** (');
    });
  });

  group('edgeAiLog level filtering', () {
    late List<String?> printed;
    late DebugPrintCallback original;
    final defaultLevel = edgeAiLogLevel;

    setUp(() {
      printed = <String?>[];
      original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
    });

    tearDown(() {
      debugPrint = original;
      edgeAiLogLevel = defaultLevel;
    });

    test('verbose level prints both info and verbose', () {
      edgeAiLogLevel = EdgeAiLogLevel.verbose;
      edgeAiLog('i', level: EdgeAiLogLevel.info);
      edgeAiLog('v', level: EdgeAiLogLevel.verbose);
      expect(printed, ['i', 'v']);
    });

    test('info level prints info but filters verbose', () {
      edgeAiLogLevel = EdgeAiLogLevel.info;
      edgeAiLog('i', level: EdgeAiLogLevel.info);
      edgeAiLog('v', level: EdgeAiLogLevel.verbose);
      expect(printed, ['i']);
    });

    test('none level prints nothing', () {
      edgeAiLogLevel = EdgeAiLogLevel.none;
      edgeAiLog('i', level: EdgeAiLogLevel.info);
      edgeAiLog('v', level: EdgeAiLogLevel.verbose);
      expect(printed, isEmpty);
    });

    test('default level argument is info', () {
      edgeAiLogLevel = EdgeAiLogLevel.info;
      edgeAiLog('default');
      expect(printed, ['default']);
    });

    test('sanitizes U+FFFD before printing', () {
      edgeAiLogLevel = EdgeAiLogLevel.verbose;
      edgeAiLog('tok: �', level: EdgeAiLogLevel.verbose);
      expect(printed, ['tok: U+FFFD']);
    });
  });

  group('FlutterEdgeAi.logLevel facade', () {
    final defaultLevel = edgeAiLogLevel;
    tearDown(() => edgeAiLogLevel = defaultLevel);

    test('setter updates the top-level edgeAiLogLevel', () {
      FlutterEdgeAi.logLevel = EdgeAiLogLevel.none;
      expect(edgeAiLogLevel, EdgeAiLogLevel.none);
    });

    test('getter reflects the top-level edgeAiLogLevel', () {
      edgeAiLogLevel = EdgeAiLogLevel.verbose;
      expect(FlutterEdgeAi.logLevel, EdgeAiLogLevel.verbose);
    });
  });
}
