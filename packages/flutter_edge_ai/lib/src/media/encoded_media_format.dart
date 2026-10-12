// Encoded media containers and the one magic-byte sniffer core has. Pure Dart,
// web-safe: the embedding facade calls it on the caller's isolate before a
// request is sent, and the LLM web arms ask it for an image's MIME type.

import 'dart:typed_data';

import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:meta/meta.dart' show visibleForTesting;

/// An encoded media container (a file format, not a decoded image or waveform).
///
/// An open value class rather than an enum: a new format is a new constant,
/// which breaks nobody's exhaustive switch. Equality is by [name], so a value
/// that crossed an isolate boundary (and lost its `const` identity on the way)
/// still equals the constant.
///
/// Which formats an engine accepts is the engine's business: it reports them
/// at load, and core refuses anything else before the request is sent.
final class EncodedMediaFormat {
  const EncodedMediaFormat._(this.name, this.mimeType, this.modality);

  /// Short lowercase name, e.g. `jpeg`. The identity of the format.
  final String name;

  /// The IANA media type, e.g. `image/jpeg`.
  final String mimeType;

  /// Whether this is an image or an audio container.
  final EmbeddingModality modality;

  static const jpeg = EncodedMediaFormat._(
    'jpeg',
    'image/jpeg',
    EmbeddingModality.image,
  );
  static const png = EncodedMediaFormat._(
    'png',
    'image/png',
    EmbeddingModality.image,
  );
  static const gif = EncodedMediaFormat._(
    'gif',
    'image/gif',
    EmbeddingModality.image,
  );
  static const bmp = EncodedMediaFormat._(
    'bmp',
    'image/bmp',
    EmbeddingModality.image,
  );
  static const webp = EncodedMediaFormat._(
    'webp',
    'image/webp',
    EmbeddingModality.image,
  );
  static const heic = EncodedMediaFormat._(
    'heic',
    'image/heic',
    EmbeddingModality.image,
  );
  static const avif = EncodedMediaFormat._(
    'avif',
    'image/avif',
    EmbeddingModality.image,
  );
  static const tiff = EncodedMediaFormat._(
    'tiff',
    'image/tiff',
    EmbeddingModality.image,
  );
  static const wav = EncodedMediaFormat._(
    'wav',
    'audio/wav',
    EmbeddingModality.audio,
  );
  static const mp3 = EncodedMediaFormat._(
    'mp3',
    'audio/mpeg',
    EmbeddingModality.audio,
  );
  static const flac = EncodedMediaFormat._(
    'flac',
    'audio/flac',
    EmbeddingModality.audio,
  );
  static const ogg = EncodedMediaFormat._(
    'ogg',
    'audio/ogg',
    EmbeddingModality.audio,
  );
  static const m4a = EncodedMediaFormat._(
    'm4a',
    'audio/mp4',
    EmbeddingModality.audio,
  );

  /// Every format [sniffEncodedMediaFormat] can recognise.
  static const List<EncodedMediaFormat> known = [
    jpeg,
    png,
    gif,
    bmp,
    webp,
    heic,
    avif,
    tiff,
    wav,
    mp3,
    flac,
    ogg,
    m4a,
  ];

  @override
  bool operator ==(Object other) =>
      other is EncodedMediaFormat && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// A copy of [format] that is NOT identical to the constant — what a value
/// that lost its `const` identity looks like. Not exported by any public
/// library; it lets a test pin that equality is by name, which a const that
/// kept its identity (e.g. across `Isolate.run`) cannot.
@visibleForTesting
EncodedMediaFormat debugCopyEncodedMediaFormat(EncodedMediaFormat format) =>
    EncodedMediaFormat._(format.name, format.mimeType, format.modality);

/// The container [bytes] start with, from their magic bytes, or null when they
/// match none of [EncodedMediaFormat.known].
///
/// Pure and web-safe, and the only sniffer in core. It reads the first few
/// bytes only; it does not validate the rest of the file, so a truncated or
/// corrupt file of a known type is still reported as that type (the engine
/// then fails to decode it).
EncodedMediaFormat? sniffEncodedMediaFormat(Uint8List bytes) {
  bool at(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (at(0, const [0xFF, 0xD8, 0xFF])) return EncodedMediaFormat.jpeg;
  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return EncodedMediaFormat.png;
  }
  if (at(0, _ascii('GIF87a')) || at(0, _ascii('GIF89a'))) {
    return EncodedMediaFormat.gif;
  }
  if (at(0, _ascii('RIFF'))) {
    if (at(8, _ascii('WEBP'))) return EncodedMediaFormat.webp;
    if (at(8, _ascii('WAVE'))) return EncodedMediaFormat.wav;
    return null;
  }
  if (at(0, const [0x49, 0x49, 0x2A, 0x00]) ||
      at(0, const [0x4D, 0x4D, 0x00, 0x2A])) {
    return EncodedMediaFormat.tiff;
  }
  if (at(0, _ascii('fLaC'))) return EncodedMediaFormat.flac;
  if (at(0, _ascii('OggS'))) return EncodedMediaFormat.ogg;
  if (at(4, _ascii('ftyp'))) return _sniffIsoBaseMedia(bytes);
  if (at(0, _ascii('BM')) && _isBmpHeader(bytes)) return EncodedMediaFormat.bmp;
  if (at(0, _ascii('ID3')) || _isMpegAudioFrame(bytes)) {
    return EncodedMediaFormat.mp3;
  }
  return null;
}

/// [sniffEncodedMediaFormat]'s MIME type for an IMAGE, else `'image/png'` —
/// the fallback the LLM web arms have always used for bytes they could not
/// identify. Audio bytes get the fallback too: this answers "what kind of
/// image is this", and has never named an audio type.
String detectImageMimeType(Uint8List bytes) {
  final format = sniffEncodedMediaFormat(bytes);
  return format != null && format.modality == EmbeddingModality.image
      ? format.mimeType
      : EncodedMediaFormat.png.mimeType;
}

List<int> _ascii(String s) => s.codeUnits;

/// ISO base media file format (`ftyp` box): HEIC, AVIF and M4A share it and are
/// told apart by their brands. Anything else in that container (MP4 video,
/// 3GP, QuickTime) is not a format we know, so null.
EncodedMediaFormat? _sniffIsoBaseMedia(Uint8List bytes) {
  if (bytes.length < 12) return null;
  String brandAt(int offset) => String.fromCharCodes(bytes, offset, offset + 4);

  const avifBrands = {'avif', 'avis'};
  const heicBrands = {
    'heic',
    'heix',
    'hevc',
    'hevx',
    'heim',
    'heis',
    'hevm',
    'hevs',
  };
  final major = brandAt(8);
  if (avifBrands.contains(major)) return EncodedMediaFormat.avif;
  if (heicBrands.contains(major)) return EncodedMediaFormat.heic;
  if (major == 'M4A ' || major == 'M4B ') return EncodedMediaFormat.m4a;
  if (major != 'mif1' && major != 'msf1') return null;

  // A generic HEIF major brand: the compatible brands, which follow the minor
  // version at offset 16 and run to the end of the box, say which it is.
  final boxSize =
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  final end = boxSize < bytes.length ? boxSize : bytes.length;
  for (var offset = 16; offset + 4 <= end; offset += 4) {
    final brand = brandAt(offset);
    if (avifBrands.contains(brand)) return EncodedMediaFormat.avif;
    if (heicBrands.contains(brand)) return EncodedMediaFormat.heic;
  }
  return null;
}

/// `BM` alone is two letters; the DIB header size at offset 14 must also be
/// one of the sizes the BMP header versions define.
bool _isBmpHeader(Uint8List bytes) {
  if (bytes.length < 18) return false;
  final dibHeaderSize =
      bytes[14] | (bytes[15] << 8) | (bytes[16] << 16) | (bytes[17] << 24);
  return const {12, 40, 52, 56, 64, 108, 124}.contains(dibHeaderSize);
}

/// An MPEG audio frame header with no reserved field: 11 sync bits, a version
/// other than "reserved", a layer other than "reserved" (which also excludes
/// AAC's ADTS header), a bitrate index other than "bad" and a sample rate
/// index other than "reserved".
bool _isMpegAudioFrame(Uint8List bytes) {
  if (bytes.length < 4) return false;
  if (bytes[0] != 0xFF || (bytes[1] & 0xE0) != 0xE0) return false;
  final version = (bytes[1] >> 3) & 0x3;
  final layer = (bytes[1] >> 1) & 0x3;
  final bitrateIndex = (bytes[2] >> 4) & 0xF;
  final sampleRateIndex = (bytes[2] >> 2) & 0x3;
  return version != 1 &&
      layer != 0 &&
      bitrateIndex != 0xF &&
      sampleRateIndex != 3;
}
