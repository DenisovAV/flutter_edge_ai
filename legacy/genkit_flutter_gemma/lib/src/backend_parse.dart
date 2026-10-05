import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:genkit/genkit.dart';

/// Parse a 'cpu'/'gpu'/'npu' string to [gemma.PreferredBackend]; null → null.
/// An unrecognized value throws [GenkitException] (INVALID_ARGUMENT).
gemma.PreferredBackend? parsePreferredBackend(
  String? value, {
  String field = 'preferredBackend',
}) {
  if (value == null) return null;
  switch (value) {
    case 'cpu':
      return gemma.PreferredBackend.cpu;
    case 'gpu':
      return gemma.PreferredBackend.gpu;
    case 'npu':
      return gemma.PreferredBackend.npu;
    default:
      throw GenkitException(
        'Unknown $field: "$value". Supported values: cpu, gpu, npu.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
  }
}
