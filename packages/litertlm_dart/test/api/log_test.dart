// LiteRtLmLog: what each level writes of litertlm_dart's own lines, that the
// level reads back as set, and that the sink and level an app sets are its
// own (a binding such as flutter_edge_ai_litertlm's leaves them alone).
import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    resetRuntimeLogSink();
    runtimeLogLevel = RuntimeLogLevel.info;
  });

  test('debug and info write the informational lines, a level above info '
      'writes none, only verbose adds prompts; each reads back as set', () {
    for (final (level, runtime) in [
      (LiteRtLmLogLevel.verbose, RuntimeLogLevel.verbose),
      (LiteRtLmLogLevel.debug, RuntimeLogLevel.info),
      (LiteRtLmLogLevel.info, RuntimeLogLevel.info),
      (LiteRtLmLogLevel.warning, RuntimeLogLevel.none),
      (LiteRtLmLogLevel.error, RuntimeLogLevel.none),
      (LiteRtLmLogLevel.fatal, RuntimeLogLevel.none),
      (LiteRtLmLogLevel.silent, RuntimeLogLevel.none),
    ]) {
      LiteRtLmLog.level = level;
      expect(currentRuntimeLogLevel(), runtime, reason: '$level');
      expect(LiteRtLmLog.level, level);
    }
  });

  test('a level set by the app wins over a level source bound later', () {
    LiteRtLmLog.level = LiteRtLmLogLevel.silent;
    expect(runtimeLogLevelSetByApp, isTrue);
    expect(runtimeLogLevelSource, isNull);
  });

  test('a sink set by the app is marked as the app\'s', () {
    void sink(String message, {bool verbose = false}) {}
    LiteRtLmLog.sink = sink;
    expect(runtimeLogSinkSetByApp, isTrue);
    expect(LiteRtLmLog.sink, same(sink));
  });
}
