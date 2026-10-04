import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// What a tool actually is, on the app's side: a Dart function from the
/// arguments the model wrote to the map the model will be shown.
///
/// Synchronous on purpose. Everything these four do is local and instant —
/// arithmetic, a clock, a constant, a colour — which keeps this codelab offline
/// and its answers checkable. A tool that talks to the network returns a
/// `Future` and the loop awaits it; nothing else changes.
typedef ToolRunner = Map<String, dynamic> Function(Map<String, dynamic> args);

/// Multiply two numbers.
///
/// The answer is checkable. Ask a small model for 1234 × 5678 and it produces
/// a confident number of about the right length; ask it to call this instead
/// and the number is exact, offline, and you can verify it on a pocket
/// calculator. A weather tool would demonstrate the same mechanism and prove
/// nothing about the answer.
const multiplyTool = Tool(
  name: 'multiply',
  // The model reads this. It is the only thing telling it WHEN to call — so
  // "instead of working it out yourself" is instruction, not prose.
  description:
      'Multiply two numbers and return the exact product. Use this for any '
      'multiplication instead of working it out yourself.',
  parameters: {
    'type': 'object',
    'properties': {
      'a': {'type': 'number', 'description': 'The first number.'},
      'b': {'type': 'number', 'description': 'The second number.'},
    },
    'required': ['a', 'b'],
  },
);

/// The device clock.
///
/// A tool with no arguments, which is worth having one of: the declaration
/// still carries `parameters` and a `type`, and the runtime renders a
/// `type: OBJECT` for it. Drop the map entirely and the parameters block goes
/// with it, which reads to the model as a declaration that was cut off — but
/// an empty `properties` map is wrong too. The runtime prints it and
/// FunctionGemma's own chat template omits it, so the two render the same
/// declaration differently, and Step 4 refuses to train on that shape.
const clockTool = Tool(
  name: 'get_current_time',
  description:
      'Return the current local date and time on this device. Use this '
      'whenever the answer depends on what time it is now.',
  parameters: {'type': 'object'},
);

/// What the app is running on.
///
/// The other kind of checkable answer: you know what device you are holding,
/// so a wrong answer here is obvious without a calculator.
const deviceTool = Tool(
  name: 'get_device_info',
  description:
      'Return the platform this app is running on. Use this when asked about '
      'the device, the operating system, or where the app is running.',
  parameters: {'type': 'object'},
);

/// The six colours this app will paint itself.
///
/// A closed set, and the declaration below lists it: an open string invites
/// "chartreuse", which the app cannot paint and the model cannot guess is
/// unavailable until it has already promised it to the user.
const backgroundColors = <String, Color>{
  'red': Color(0xFFFFEBEE),
  'green': Color(0xFFE8F5E9),
  'blue': Color(0xFFE3F2FD),
  'yellow': Color(0xFFFFFDE7),
  'purple': Color(0xFFF3E5F5),
  'orange': Color(0xFFFFF3E0),
};

/// Repaint the app.
///
/// The one tool here whose result you do not have to read. Arithmetic is
/// checkable, a clock is checkable, and both still arrive as text in a bubble;
/// this one you watch happen. It is the same mechanism either way — a name, a
/// schema, a Dart function — which is the point worth seeing twice.
const backgroundTool = Tool(
  name: 'change_background_color',
  description:
      'Repaint the chat background. Use this whenever the user asks for a '
      'different colour, a new background, or a change of theme.',
  parameters: {
    'type': 'object',
    'properties': {
      // The model reads the list. Leaving it out is how you get a call for a
      // colour this app has never heard of.
      'color': {
        'type': 'string',
        'description': 'One of: red, green, blue, yellow, purple, orange.',
      },
    },
    'required': ['color'],
  },
);

/// Everything the model is told it can call.
const toolbox = <Tool>[multiplyTool, clockTool, deviceTool, backgroundTool];

/// Everything the app can actually run, keyed by the name in the declaration.
///
/// A map rather than a `switch` because the two halves — what is declared and
/// what is implemented — are then two collections a test can compare. A tool
/// declared with no runner is a call the app answers with an error forever,
/// and the model never finds out why.
const toolRunners = <String, ToolRunner>{
  'multiply': runMultiply,
  'get_current_time': runClock,
  'get_device_info': runDeviceInfo,
  'change_background_color': runChangeBackground,
};

/// Runs a call, or says it cannot.
///
/// The miss branch is not defensive padding: the model writes the name, and a
/// model can write a name you never declared. That is a turn to answer, not a
/// crash — returned as a map so the model reads it and can correct itself on
/// the next turn, where an exception would end the conversation.
Map<String, dynamic> runTool(FunctionCallResponse call) {
  final runner = toolRunners[call.name];
  if (runner == null) {
    return {'error': 'This app has no tool named "${call.name}".'};
  }
  return runner(call.args);
}

/// Multiplies, and returns the map the model will be shown.
///
/// Everything returned here becomes the model's only knowledge of what
/// happened, so the keys are part of the interface: `result` is what it will
/// read back to the user, and `error` is what it will apologise about.
Map<String, dynamic> runMultiply(Map<String, dynamic> args) {
  final a = asNumber(args['a']);
  final b = asNumber(args['b']);
  if (a == null || b == null) {
    return {
      'error':
          'multiply needs two numbers. Got a=${args['a']}, b=${args['b']}.',
    };
  }
  final product = a * b;
  // `12 * 13` arriving as doubles comes back as `156.0`, and the model has to
  // read that number out loud. Say 156.
  return {
    'result': product is double && product == product.truncateToDouble()
        ? product.toInt()
        : product,
  };
}

/// The device clock, in two forms.
///
/// `time` is what a person checks against their own watch; `iso8601` is what
/// the model should use if it has to compute with it. Giving both costs a few
/// tokens and removes a whole class of "it read the date as the year".
Map<String, dynamic> runClock(Map<String, dynamic> args) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return {
    'time': '${two(now.hour)}:${two(now.minute)}',
    'date': '${now.year}-${two(now.month)}-${two(now.day)}',
    'iso8601': now.toIso8601String(),
  };
}

/// Where the app is running.
///
/// `kIsWeb` is asked first because `defaultTargetPlatform` in a browser
/// reports the HOST operating system — a Chrome tab on a Mac answers
/// `macOS`, which is true about the machine and wrong about the app.
Map<String, dynamic> runDeviceInfo(Map<String, dynamic> args) => {
  'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
  'build': kDebugMode ? 'debug' : 'release',
};

/// Arguments arrive as whatever JSON the model produced.
///
/// FunctionGemma is trained to emit tool-call arguments as strings, so `"12"`
/// is the common case there and `12` or `12.0` are the others. All three are
/// the same number and the app should not care which one it got.
num? asNumber(Object? value) => switch (value) {
  final num n => n,
  final String s => num.tryParse(s.trim()),
  _ => null,
};

/// Repaints, or says which colours exist.
///
/// The error branch is the whole reason the colour list is closed: a model that
/// asks for "teal" gets the six names back and picks again on the next turn,
/// where a silent no-op would leave it telling the user the screen is now teal.
Map<String, dynamic> runChangeBackground(Map<String, dynamic> args) {
  final asked = args['color']?.toString().trim().toLowerCase();
  if (asked == null || !backgroundColors.containsKey(asked)) {
    return {
      'error':
          'This app has no colour named "${args['color']}". '
          'Available: ${backgroundColors.keys.join(', ')}.',
    };
  }
  // The colour travels back as its NAME, not as an int: the model reads this
  // to write its sentence, and the page reads the same map to repaint. One
  // answer, two readers, no second source of truth.
  return {'result': 'background is now $asked', 'color': asked};
}

/// The colour a tool result asks for, or null when it asked for none.
///
/// Lives here rather than in the page so the mapping from an answer to a
/// repaint is testable without a widget.
Color? backgroundFrom(Map<String, dynamic> result) =>
    backgroundColors[result['color']?.toString()];
