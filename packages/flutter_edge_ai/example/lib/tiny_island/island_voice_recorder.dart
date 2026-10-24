import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../utils/platform_io_helper.dart';

/// Records one spoken request at a time, as the screen's mic button holds
/// it: [start] on press, [stop] on release.
abstract interface class IslandVoiceRecorder {
  /// Starts recording. Throws [StateError] naming why the microphone cannot
  /// be used (permission refused, no input device).
  Future<void> start();

  /// Stops recording and returns it as a WAV file (16 kHz, mono, 16-bit);
  /// null when nothing was recorded.
  Future<Uint8List?> stop();

  /// Stops a recording in progress and releases the microphone.
  Future<void> dispose();
}

/// The app's recorder: the `record` plugin, writing a WAV file to the system
/// temp directory (a blob URL on the web), read back and deleted on [stop].
final class RecordIslandVoiceRecorder implements IslandVoiceRecorder {
  final _recorder = AudioRecorder();

  @override
  Future<void> start() async {
    if (!kIsWeb && (platformIsAndroid || platformIsIOS)) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        throw StateError(
          'Microphone permission was refused: allow it in Settings to speak '
          'to the island.',
        );
      }
    }
    if (!await _recorder.hasPermission()) {
      throw StateError('No microphone is available to this app.');
    }
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: kIsWeb ? '' : '$systemTempPath/tiny_island_request.wav',
    );
  }

  @override
  Future<Uint8List?> stop() async {
    final path = await _recorder.stop();
    if (path == null) return null;
    if (kIsWeb) return (await http.get(Uri.parse(path))).bodyBytes;
    final file = createFile(path);
    final bytes = await file.readAsBytes();
    await file.delete();
    return bytes;
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
