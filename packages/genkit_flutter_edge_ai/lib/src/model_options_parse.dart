import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

import 'flutter_edge_ai_options.dart';

/// The context window a request gets when its config sets no `maxTokens`:
/// flutter_edge_ai's own default.
const int kDefaultMaxTokens = 1024;

/// Reads a request's model config, or throws INVALID_ARGUMENT.
///
/// Validated against [FlutterEdgeAiModelOptions]'s schema first: a value of
/// the wrong type, a fraction for an integer option (`1024.0` passes), a value
/// below an option's minimum, or a `toolChoice` or backend the schema does not
/// list. The generated getters cast lazily and truncate, so read unvalidated a
/// `maxTokens` of `0.9` became 0 and a string became a `TypeError`, which a
/// hybrid router treats as transient and hands to the next branch. Sampling
/// values no engine can sample with are rejected as well, and so is a
/// `maxOutputTokens` larger than the context window it is part of.
Future<FlutterEdgeAiModelOptions?> parseModelOptions(
  Map<String, dynamic>? config,
) async {
  if (config == null) return null;
  final errors = await FlutterEdgeAiModelOptions.$schema.validate(config);
  if (errors.isNotEmpty) {
    throw GenkitException(
      'Invalid model config: '
      '${errors.map((e) => e.toErrorString()).join('; ')}',
      status: StatusCode.invalidArgument,
    );
  }
  final options = FlutterEdgeAiModelOptions.fromJson(config);
  try {
    gemma.SamplingParams(
      temperature: options.temperature,
      topK: options.topK,
      topP: options.topP,
      randomSeed: options.randomSeed,
    ).validate();
  } on ArgumentError catch (e) {
    // `$e`, not e.message: the message alone does not name the option.
    throw GenkitException(
      'Invalid model config: $e',
      status: StatusCode.invalidArgument,
    );
  }
  final maxTokens = options.maxTokens ?? kDefaultMaxTokens;
  final maxOutputTokens = options.maxOutputTokens;
  if (maxOutputTokens != null && maxOutputTokens > maxTokens) {
    throw GenkitException(
      'Invalid model config: maxOutputTokens ($maxOutputTokens) is larger '
      'than maxTokens ($maxTokens), the context window that holds the input '
      'and the output together.',
      status: StatusCode.invalidArgument,
    );
  }
  return options;
}
