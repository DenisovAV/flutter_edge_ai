import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/tools.dart';

FunctionCallResponse _call(
  String name, [
  Map<String, dynamic> args = const {},
]) => FunctionCallResponse(name: name, args: args);

void main() {
  test('every tool the model is told about has an implementation', () {
    final tools = AssistantTools(onTimerDone: (_) {});
    for (final tool in toolbox) {
      expect(
        tools.run(_call(tool.name, {'minutes': 1})),
        isNot(contains('error')),
        reason: tool.name,
      );
    }
    tools.dispose();
  });

  test('the clock answers HH:mm', () {
    final tools = AssistantTools(onTimerDone: (_) {});
    expect(
      tools.run(_call('get_current_time'))['time'],
      matches(RegExp(r'^\d\d:\d\d$')),
    );
  });

  // testWidgets runs on a fake clock, so a two-minute timer takes no time.
  testWidgets('a timer runs out after the minutes the model asked for', (
    tester,
  ) async {
    num? done;
    final tools = AssistantTools(onTimerDone: (m) => done = m);
    expect(tools.run(_call('set_timer', {'minutes': 2})), {
      'status': 'started',
      'minutes': 2,
    });
    await tester.pump(const Duration(seconds: 119));
    expect(done, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(done, 2);
  });

  test(
    'bad arguments and unknown tools come back as a result, not a throw',
    () {
      final tools = AssistantTools(onTimerDone: (_) {});
      for (final args in [
        <String, dynamic>{},
        {'minutes': 'five'},
        {'minutes': 0},
      ]) {
        expect(
          tools.run(_call('set_timer', args)),
          contains('error'),
          reason: '$args',
        );
      }
      expect(tools.run(_call('open_the_pod_bay_doors')), contains('error'));
    },
  );

  testWidgets('dispose cancels timers that have not run out', (tester) async {
    var fired = false;
    final tools = AssistantTools(onTimerDone: (_) => fired = true);
    tools.run(_call('set_timer', {'minutes': 1}));
    tools.dispose();
    await tester.pump(const Duration(minutes: 2));
    expect(fired, isFalse);
  });
}
