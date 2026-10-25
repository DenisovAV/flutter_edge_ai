/// Refuses a missing adapter before mutating the shared runtime.
Future<void> validateLoraPath(String path) async =>
    throw UnsupportedError('This connector does not wire Web LoRA adapters.');
