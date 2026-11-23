// A turn's errors as core's apps catch them, on the native and the web
// session alike: one failure has one type on every platform.

import 'package:flutter_edge_ai/engine.dart';
import 'package:litertlm_dart/internal.dart' show turnFailureCause;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

import 'core_hints.dart';
import 'runtime_mapping.dart';

/// The session, or its model, was closed while a reply streamed: a
/// [StateError], as a use of a closed session is.
final class LiteRtLmSessionClosedError extends StateError {
  LiteRtLmSessionClosedError(super.message);
}

/// The runtime's turn errors as core's: a close is
/// [LiteRtLmSessionClosedError]; a failure is what the runtime threw, not
/// litertlm_dart's wrapper of it, a native one a plain [Exception] with its
/// line in core's terms; a message that did not fit is
/// [ContextLimitException], which keeps native's token counts; the rest as
/// [mapRuntimeError] maps them.
Object coreTurnError(Object error) {
  if (error is lm.ConversationClosedException) {
    return LiteRtLmSessionClosedError(error.message);
  }
  if (error is lm.TurnFailedException) {
    final cause = turnFailureCause(error);
    // A native failure mid-turn as at session open: a plain Exception.
    if (cause is lm.LiteRtLmNativeException) {
      return Exception(withCoreHint(cause.message));
    }
    if (cause != null) return withCoreHintError(mapRuntimeError(cause));
  }
  if (error is lm.ContextFullException) {
    return ContextLimitException(
      'The input token count does not fit the context window space '
      'left; the session was restored to before this turn. Send a '
      'shorter message, or close the session and open a new one. '
      'Native token counts: ${error.message}',
    );
  }
  // A refusal in litertlm_dart's terms (no encoder, maxNumImages) gets its
  // line in core's.
  return withCoreHintError(mapRuntimeError(error));
}
