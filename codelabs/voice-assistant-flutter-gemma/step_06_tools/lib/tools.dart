import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// The device clock.
///
/// A tool with no arguments still declares `parameters` with a `type`: drop the
/// map and the model reads the declaration as cut off.
const clockTool = Tool(
  name: 'get_current_time',
  // The model reads this. It is the only thing telling it WHEN to call.
  description:
      'Return the current local time on this device. Use this whenever the '
      'answer depends on what time it is now.',
  parameters: {'type': 'object'},
);

/// A countdown on this device.
///
/// This one does something, not just look something up: the app keeps the
/// timer and says so out loud when it runs out.
const timerTool = Tool(
  name: 'set_timer',
  description: 'Start a countdown timer on this device.',
  parameters: {
    'type': 'object',
    'properties': {
      'minutes': {'type': 'number', 'description': 'Length in minutes.'},
    },
    'required': ['minutes'],
  },
);

/// Everything the assistant may call. Both tools are local and instant, so the
/// assistant keeps working in airplane mode.
const toolbox = [clockTool, timerTool];

/// The app's side of a tool call: a Dart function from the arguments the model
/// wrote to the map the model will be shown next.
class AssistantTools {
  AssistantTools({required this.onTimerDone});

  /// Called when a timer runs out, with the length it was set for.
  final void Function(num minutes) onTimerDone;

  final _timers = <Timer>[];

  Map<String, dynamic> run(FunctionCallResponse call) => switch (call.name) {
    'get_current_time' => {'time': _clock(DateTime.now())},
    'set_timer' => _setTimer(call.args['minutes']),
    // The model can name a tool that does not exist. Tell it so, in the same
    // shape as any other result, rather than throwing out of the chat loop.
    _ => {'error': 'There is no tool called ${call.name}.'},
  };

  Map<String, dynamic> _setTimer(Object? minutes) {
    // The model writes these arguments; check them like any other input.
    if (minutes is! num || minutes <= 0 || minutes > 24 * 60) {
      return {'error': 'minutes must be a number between 0 and 1440'};
    }
    _timers.add(
      Timer(
        Duration(seconds: (minutes * 60).round()),
        () => onTimerDone(minutes),
      ),
    );
    return {'status': 'started', 'minutes': minutes};
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
  }
}
