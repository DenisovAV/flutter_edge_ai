// The model VoiceActivityDetector uses by default: the Silero VAD asset this
// package ships, copied once into the app's support directory because LiteRT
// opens models by path, and checked against its SHA-256 there. Not exported:
// the test hooks below are for this package's tests only.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

import 'vad_worker.dart' show VadWorkerEngineFactory;

/// The Silero VAD model this package ships, as a Flutter asset of this
/// package: the 16 kHz model of silero-vad v6.2.3 (MIT, Silero Team),
/// exported to LiteRT by anira-project (huggingface.co/anira-project/
/// silero-vad at c302618523e14ea1a7a919df1b796096186513bb,
/// `litert/silero_vad_16k.tflite`).
const String bundledVadModelAsset =
    'packages/flutter_edge_ai_speech/assets/vad/silero_vad_16k_v6.2.3.tflite';

/// Size in bytes of [bundledVadModelAsset].
const int bundledVadModelBytes = 1254896;

/// SHA-256 of [bundledVadModelAsset]. The copy LiteRT opens is checked
/// against it, and a test holds the asset to it.
const String bundledVadModelSha256 =
    'dfb2e98438dede7718e33cb3a63863b333b82e486ba122ebb803551094d488e9';

/// Replaces the native engine in tests. Must be a top-level or static
/// function: it crosses into the worker isolate. Read by the detector, so
/// not marked `@visibleForTesting`; this library is not exported.
VadWorkerEngineFactory? debugVadEngineFactory;

/// Reads the bundled model in tests, instead of the Flutter asset bundle.
@visibleForTesting
Future<Uint8List> Function()? debugBundledModelBytes;

/// The directory the bundled model is copied to in tests, instead of the
/// app's support directory. Setting it forgets the path already resolved.
@visibleForTesting
set debugVadModelCacheDir(Directory? dir) {
  _debugCacheDir = dir;
  _bundledPath = null;
}

Directory? _debugCacheDir;

/// The copy of the bundled model, written once per isolate: concurrent
/// creates share it.
Future<String>? _bundledPath;

/// The path of the bundled model's checked copy, writing it if needed.
Future<String> bundledVadModelPath() => _bundledPath ??= _writeBundledModel();

/// Copies the bundled model to `<app support>/flutter_edge_ai_speech/vad/`
/// unless a copy with the right SHA-256 is there already. The copy is
/// written under a unique name and renamed into place, so two writers never
/// share a partial file and a reader never opens one; a rename that fails
/// because another writer got there first uses that copy once it checks.
Future<String> _writeBundledModel() async {
  try {
    final base = _debugCacheDir ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/flutter_edge_ai_speech/vad');
    final file = File('${dir.path}/silero_vad_16k_v6.2.3.tflite');
    if (await _isBundledModel(file)) return file.path;

    final bytes = await (debugBundledModelBytes ?? _assetBytes)();
    if (sha256.convert(bytes).toString() != bundledVadModelSha256) {
      throw StateError(
        'VoiceActivityDetector: the bundled model $bundledVadModelAsset '
        '(${bytes.length} bytes) does not match its SHA-256 '
        '$bundledVadModelSha256',
      );
    }
    await dir.create(recursive: true);
    final partial = File(
      '${file.path}.$pid.${Random().nextInt(1 << 32)}.partial',
    );
    await partial.writeAsBytes(bytes, flush: true);
    try {
      await partial.rename(file.path);
    } on FileSystemException {
      // Windows refuses to replace a file another process has open.
      if (await partial.exists()) await partial.delete();
      if (!await _isBundledModel(file)) rethrow;
    }
    return file.path;
  } catch (_) {
    // Let a later create try again instead of repeating this failure.
    _bundledPath = null;
    rethrow;
  }
}

Future<bool> _isBundledModel(File file) async {
  if (!await file.exists() || await file.length() != bundledVadModelBytes) {
    return false;
  }
  final digest = sha256.convert(await file.readAsBytes()).toString();
  return digest == bundledVadModelSha256;
}

Future<Uint8List> _assetBytes() async {
  final data = await rootBundle.load(bundledVadModelAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
