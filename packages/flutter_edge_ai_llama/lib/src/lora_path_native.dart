import 'dart:io';

/// Refuses a missing adapter before mutating the shared runtime.
Future<void> validateLoraPath(String path) async {
  if (!await File(path).exists()) {
    throw ArgumentError('Choose an existing local LoRA file for loraPath.');
  }
}
