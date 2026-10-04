import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// The one Dart function the model may call.
///
/// Kept apart from the UI so it can be tested without a model, and written so
/// it never throws: a model can recover from an error it can read, while an
/// exception out of a tool ends the turn.
abstract final class ColorTool {
  static const name = 'change_color';

  /// What the model sees. It matches the user's request against the
  /// description, so the description names an action and every parameter is
  /// described.
  static const declaration = Tool(
    name: name,
    description: "Change the app's colour theme.",
    parameters: {
      'type': 'object',
      'properties': {
        'color': {
          'type': 'string',
          'description': 'A colour name, for example red, green or purple.',
        },
      },
      'required': ['color'],
    },
  );

  static const colors = <String, Color>{
    'red': Colors.red,
    'pink': Colors.pink,
    'purple': Colors.purple,
    'indigo': Colors.indigo,
    'blue': Colors.blue,
    'teal': Colors.teal,
    'green': Colors.green,
    'amber': Colors.amber,
    'orange': Colors.orange,
    'brown': Colors.brown,
    'grey': Colors.grey,
    'gray': Colors.grey,
  };

  /// Runs one call and returns what the model reads back, plus the colour to
  /// apply when the call succeeded.
  static ToolOutcome run(String callName, Map<String, dynamic> args) {
    if (callName != name) {
      return ToolOutcome({'error': 'unknown function: $callName'});
    }
    final requested = args['color'];
    if (requested is! String || requested.trim().isEmpty) {
      return const ToolOutcome({'error': 'no colour given'});
    }
    final key = requested.trim().toLowerCase();
    final color = colors[key];
    if (color == null) {
      return ToolOutcome({
        'error': 'unknown colour: $requested',
        'known': colors.keys.toList(),
      });
    }
    return ToolOutcome({'color': key}, color: color);
  }
}

class ToolOutcome {
  const ToolOutcome(this.result, {this.color});

  /// Sent back to the model.
  final Map<String, dynamic> result;

  /// Applied by the app; null when the call failed.
  final Color? color;
}
