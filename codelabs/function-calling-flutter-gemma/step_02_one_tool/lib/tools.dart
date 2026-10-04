import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// The one function this app lets the model ask for.
///
/// A [Tool] is a DECLARATION and nothing else — a name, a description the
/// model reads, and a JSON Schema for the arguments. It holds no code and it
/// cannot run: the runtime renders this into the prompt and hands the call
/// back parsed, and running the call is the app's job. [runMultiply] below is the half
/// that actually computes something, and `chat_page.dart` is where the two are
/// wired together.
///
/// Multiplication, because the answer is checkable. Ask a 270M model for
/// 1234 × 5678 and it will produce a confident number of about the right
/// length; ask it to call this instead and the number is exact, offline, and
/// you can verify it on a pocket calculator. A weather tool would demonstrate
/// the same mechanism and prove nothing about the answer.
const multiplyTool = Tool(
  name: 'multiply',
  // The model reads this. It is the only thing telling it WHEN to call — so
  // "use this instead of working it out yourself" is instruction, not prose.
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

/// Runs [multiplyTool] and returns the map the model will be shown.
///
/// Everything this function returns becomes the model's only knowledge of what
/// happened, so the keys are part of the interface: `result` is what it will
/// read back to the user, and `error` is what it will apologise about.
Map<String, dynamic> runMultiply(Map<String, dynamic> args) {
  final a = asNumber(args['a']);
  final b = asNumber(args['b']);
  if (a == null || b == null) {
    // Returned, not thrown. A model wrote these arguments and a model can
    // write nonsense; an error map is a turn it can read and correct on the
    // next one, while an exception ends the conversation and takes the
    // committed call with it.
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

/// Arguments arrive as whatever JSON the model produced.
///
/// It is trained to emit tool-call arguments as strings, so `"12"` is the
/// common case and `12` or `12.0` are the others. All three are the same
/// number and the app should not care which one it got.
num? asNumber(Object? value) => switch (value) {
  final num n => n,
  final String s => num.tryParse(s.trim()),
  _ => null,
};
