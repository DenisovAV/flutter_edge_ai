// Shared helpers for voice-loop integration tests.
// Not a test file — imported by voice_*_test.dart files.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' show SpeechRecognizer;
import 'package:path_provider/path_provider.dart';

/// Resolve a device-local staged model file (no network, no token) — the same
/// convention [voice_loop_test.dart]'s `_stagedLlmPath` uses, so these tests run
/// on every platform, not just Android. Desktop/iOS read it from the app
/// documents dir; Android (Firebase Test Lab) reads it from
/// `/data/local/tmp/flutter_gemma_test/` (pushed via `--other-files`). Returns
/// null when no staged file is present.
Future<String?> stagedModelPath(String filename) async {
  if (Platform.isAndroid) {
    final p = '/data/local/tmp/flutter_gemma_test/$filename';
    return File(p).existsSync() ? p : null;
  }
  final docs = await getApplicationDocumentsDirectory();
  final p = '${docs.path}/$filename';
  return File(p).existsSync() ? p : null;
}

/// A [SpeechRecognizer] that ignores the PCM and returns a fixed transcript, so
/// voice ITs exercise the LLM/tools/TTS path deterministically (real STT is
/// covered by voice_loop_test.dart / stt_moonshine_test.dart).
class FixedTranscriptRecognizer implements SpeechRecognizer {
  FixedTranscriptRecognizer(this.transcript);

  final String transcript;

  @override
  String? language;

  @override
  Future<String> transcribe(Uint8List pcm16kMono, {String? language}) async =>
      transcript;

  @override
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async {}
}
