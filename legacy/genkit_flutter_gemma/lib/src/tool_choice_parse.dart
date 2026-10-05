import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:genkit/plugin.dart';

/// Maps a Genkit toolChoice string to flutter_gemma's [gemma.ToolChoice].
///
/// `null` → [gemma.ToolChoice.auto] (unset / default). An unrecognized value
/// throws [GenkitException] with `INVALID_ARGUMENT` — mirroring
/// `parsePreferredBackend` — so a typo like `'non'` or `'REQUIRED'` cannot
/// silently fall through to `auto` and enable tool calls the caller meant to
/// forbid.
gemma.ToolChoice parseToolChoice(String? value) {
  switch (value) {
    case null:
    case 'auto':
      return gemma.ToolChoice.auto;
    case 'required':
      return gemma.ToolChoice.required;
    case 'none':
      return gemma.ToolChoice.none;
    default:
      throw GenkitException(
        'Unknown toolChoice: "$value". Supported values: auto, required, none.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
  }
}
