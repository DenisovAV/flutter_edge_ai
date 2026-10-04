import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_skills/color_tool.dart';

void main() {
  test('a known colour is applied and reported back', () {
    final outcome = ColorTool.run('change_color', {'color': 'green'});
    expect(outcome.result, {'color': 'green'});
    expect(outcome.color, Colors.green);
  });

  test('the colour name is matched regardless of case and spacing', () {
    final outcome = ColorTool.run('change_color', {'color': '  Purple '});
    expect(outcome.color, Colors.purple);
  });

  // The rule from the function-calling skill: return errors as data, never
  // throw. The model can read an error and recover; an exception ends the turn.
  test('an unknown colour comes back as an error the model can read', () {
    late ToolOutcome outcome;
    expect(
      () => outcome = ColorTool.run('change_color', {'color': 'mauvish'}),
      returnsNormally,
    );
    expect(outcome.result['error'], contains('mauvish'));
    expect(outcome.result['known'], contains('green'));
    expect(outcome.color, isNull);
  });

  test('a missing argument is an error, not an exception', () {
    final outcome = ColorTool.run('change_color', {});
    expect(outcome.result['error'], isNotNull);
    expect(outcome.color, isNull);
  });

  test('a call to a function the app does not have is an error too', () {
    final outcome = ColorTool.run('launch_rocket', {'color': 'red'});
    expect(outcome.result['error'], contains('launch_rocket'));
    expect(outcome.color, isNull);
  });
}
