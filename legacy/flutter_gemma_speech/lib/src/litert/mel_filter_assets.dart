// packages/flutter_gemma_speech/lib/src/litert/mel_filter_assets.dart
//
// Resolves a profile's `melFilterAsset` name to its bundled filterbank
// matrix. Compiled-into-source (not a Flutter `assets:` bundle + rootBundle)
// on purpose: the frontend runs inside the STT background isolate
// (stt_worker.dart), which has no Flutter asset-bundle access without extra
// isolate-binding ceremony — a compiled Dart constant works identically
// everywhere with zero I/O. All 6 flutter_gemma target platforms are
// little-endian, so a direct `.buffer.asFloat32List()` view over the
// base64-decoded bytes is safe (matches the bytes' generation endianness).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'mel_filters/nemo_mel_80.g.dart';
import 'mel_filters/whisper_mel_80.g.dart';

/// Resolve a bundled mel filterbank matrix by [assetName] (the value of
/// `SttModelProfile.melFilterAsset`). Row-major `[nMels, nBins]` float32.
/// Throws a [StateError] naming the asset if unknown — fail-loud rather
/// than silently returning an empty/wrong matrix (Global Constraints).
Float32List loadMelFilterAsset(String assetName) {
  switch (assetName) {
    case 'whisper_mel_80':
      return base64Decode(whisperMel80Base64).buffer.asFloat32List();
    case 'nemo_mel_80':
      return base64Decode(nemoMel80Base64).buffer.asFloat32List();
    default:
      throw StateError('loadMelFilterAsset: unknown asset "$assetName"');
  }
}
