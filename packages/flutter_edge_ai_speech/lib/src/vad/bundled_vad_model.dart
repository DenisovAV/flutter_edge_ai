// The model VoiceActivityDetector uses by default: the Silero VAD asset this
// package ships, copied once into the app's cache directory because LiteRT
// opens models by path, and checked against its SHA-256 there. Not exported:
// the test hooks below are for this package's tests only.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationCacheDirectory;

import 'vad_worker.dart' show VadWorkerEngineFactory;

/// The Silero VAD model this package ships, as a Flutter asset of this
/// package: the 16 kHz model of silero-vad v6.3 (MIT, Silero Team), exported
/// to LiteRT for this package with anira-project's explicit-state export
/// scripts; provenance and checks in `assets/vad/README.md`.
const String bundledVadModelAsset =
    'packages/flutter_edge_ai_speech/assets/vad/silero_vad_16k_v6.3.tflite';

/// Size in bytes of [bundledVadModelAsset].
const int bundledVadModelBytes = 1254896;

/// SHA-256 of [bundledVadModelAsset]. The copy LiteRT opens is checked
/// against it, and a test holds the asset to it.
const String bundledVadModelSha256 =
    '01efcddffbff805ec147dba7983fc07cfd54464fbacfaf021877e991ae52b3b9';

/// Replaces the native engine in tests. Must be a top-level or static
/// function: it crosses into the worker isolate. Read by the detector, so
/// not marked `@visibleForTesting`; this library is not exported.
VadWorkerEngineFactory? debugVadEngineFactory;

/// Reads the bundled model in tests, instead of the Flutter asset bundle.
@visibleForTesting
Future<Uint8List> Function()? debugBundledModelBytes;

/// The directory the bundled model is copied to in tests, instead of the
/// app's cache directory. Setting it forgets the path already resolved.
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

/// Copies the bundled model to `<app cache>/flutter_edge_ai_speech/vad/`
/// unless a copy with the right SHA-256 is there already. The cache
/// directory, not the support one: the copy can always be rebuilt from the
/// asset, so it stays out of iCloud and Android Auto Backup (whose 25 MB
/// quota it would eat into), and a purge by the OS costs one copy at the
/// next create. The copy is
/// written under a unique name and renamed into place, so two writers never
/// share a partial file and a reader never opens one; a rename that fails
/// because another writer got there first uses that copy once it checks.
Future<String> _writeBundledModel() async {
  try {
    final base = _debugCacheDir ?? await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/flutter_edge_ai_speech/vad');
    final file = File('${dir.path}/silero_vad_16k_v6.3.tflite');
    if (await _isBundledModel(file)) return file.path;

    final bytes = await (debugBundledModelBytes ?? _assetBytes)();
    if (await _sha256(bytes) != bundledVadModelSha256) {
      throw StateError(
        'VoiceActivityDetector: the bundled model $bundledVadModelAsset '
        '(${bytes.length} bytes) does not match its SHA-256 '
        '$bundledVadModelSha256',
      );
    }
    await dir.create(recursive: true);
    await _sweepStalePartials(dir);
    final partial = File(
      '${file.path}.$pid.${Random().nextInt(1 << 32)}.partial',
    );
    try {
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
    } on FileSystemException {
      // A failed write (a full disk) leaves a partial file; Windows refuses
      // to replace a file another process has open. Either way, no partial
      // file is left behind, and another writer's good copy is used.
      try {
        if (await partial.exists()) await partial.delete();
      } on FileSystemException {
        // Best effort: the unique name never collides with a later write,
        // and a later create sweeps it once it is stale.
      }
      var good = false;
      try {
        good = await _isBundledModel(file);
      } on FileSystemException {
        // Reading the other copy failed too: report the write's error.
      }
      if (!good) rethrow;
    }
    return file.path;
  } catch (_) {
    // Let a later create try again instead of repeating this failure.
    _bundledPath = null;
    rethrow;
  }
}

/// How old a `.partial` copy must be before a create deletes it: younger
/// ones may belong to a writer in another process that is still at work.
/// Should a writer be suspended longer than this mid-copy, its create fails
/// with a FileSystemException when its file is gone, and the next create
/// copies again.
const Duration _stalePartialAge = Duration(hours: 1);

/// Deletes the `.partial` copies a killed writer left behind.
Future<void> _sweepStalePartials(Directory dir) async {
  final now = DateTime.now();
  await for (final entity in dir.list()) {
    if (entity is! File || !entity.path.endsWith('.partial')) continue;
    try {
      final age = now.difference(await entity.lastModified());
      if (age > _stalePartialAge) await entity.delete();
    } on FileSystemException {
      // Gone already (another create swept it), or not ours to delete.
    }
  }
}

Future<bool> _isBundledModel(File file) async {
  if (!await file.exists() || await file.length() != bundledVadModelBytes) {
    return false;
  }
  return await _sha256(await file.readAsBytes()) == bundledVadModelSha256;
}

/// The SHA-256 of [bytes], off the calling isolate: create runs on the UI
/// isolate, and hashing 1.25 MB there would cost a frame.
Future<String> _sha256(Uint8List bytes) =>
    Isolate.run(() => sha256.convert(bytes).toString());

Future<Uint8List> _assetBytes() async {
  final data = await rootBundle.load(bundledVadModelAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
