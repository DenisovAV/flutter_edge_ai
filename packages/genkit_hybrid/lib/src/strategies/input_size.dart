import 'package:genkit/genkit.dart';

import '../routing_context.dart';
import '../routing_strategy.dart';

/// Routes by input length: total character count of all text parts in the
/// request. At or below [threshold] -> [small] branch, above -> [large] branch.
@Deprecated('Use RouteRule.inputSize; removed in 0.5.0.')
class InputSizeStrategy implements RoutingStrategy {
  InputSizeStrategy({
    required this.threshold,
    required this.small,
    required this.large,
  });

  final int threshold;
  final String small;
  final String large;

  @override
  List<String> route(RoutingContext context) {
    final size = _charCount(context.request);
    return [size > threshold ? large : small];
  }

  int _charCount(ModelRequest? request) {
    if (request == null) return 0;
    var total = 0;
    for (final message in request.messages) {
      for (final part in message.content) {
        total += part.text?.length ?? 0;
      }
    }
    return total;
  }
}
