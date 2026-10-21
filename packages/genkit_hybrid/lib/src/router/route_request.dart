import 'package:genkit/genkit.dart';

import '../media_kind.dart';
import '../model_capability.dart';

/// The first turn of a routed generate call, as rules and classifiers see it.
///
/// Public so an app can unit-test its policy without a Genkit instance.
final class RouteRequest {
  RouteRequest(this.request, {this.isStreaming = false, this.context});

  /// The request as the router received it. Its `model` is replaced by the
  /// chosen target's; a prompt may have named one.
  final GenerateActionOptions request;

  /// Whether the caller streams the response.
  final bool isStreaming;

  /// The call's Genkit `context`.
  final Map<String, dynamic>? context;

  /// The text parts of the last `Role.user` message, joined; null when there
  /// is no user message or it has no text part. From the second turn of a
  /// tool loop the last message is a tool response, so this is the user's
  /// request, not the latest message.
  late final String? lastUserText = () {
    for (final message in request.messages.reversed) {
      if (message.role != Role.user) continue;
      if (!message.content.any((p) => p.isText)) return null;
      return message.text;
    }
    return null;
  }();

  /// What the request needs from a model: vision/audio for its media, tools
  /// when it offers any, json for structured output.
  late final Set<ModelCapability> requires = () {
    final caps = mediaCapabilities(request.messages);
    if (request.tools?.isNotEmpty ?? false) caps.add(ModelCapability.tools);
    final o = request.output;
    if (o != null &&
        (o.format == 'json' ||
            o.jsonSchema != null ||
            o.contentType == 'application/json')) {
      caps.add(ModelCapability.json);
    }
    return Set<ModelCapability>.unmodifiable(caps);
  }();

  /// Characters of every text part of every message.
  late final int textLength = () {
    var total = 0;
    for (final message in request.messages) {
      for (final part in message.content) {
        if (part.isText) total += part.text?.length ?? 0;
      }
    }
    return total;
  }();
}
