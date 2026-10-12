// EncodedMediaFormat, the one media sniffer, and detectImageMimeType over it.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(List<Object> parts, {int padTo = 32}) {
  final out = <int>[];
  for (final part in parts) {
    if (part is String) {
      out.addAll(part.codeUnits);
    } else {
      out.addAll(part as List<int>);
    }
  }
  while (out.length < padTo) {
    out.add(0);
  }
  return Uint8List.fromList(out);
}

/// `ftyp` box of [size] bytes with a major brand, minor version 0 and
/// [compatible] brands.
List<int> _ftyp(String major, [List<String> compatible = const []]) {
  final size = 16 + 4 * compatible.length;
  return [
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...'ftyp'.codeUnits,
    ...major.codeUnits,
    0,
    0,
    0,
    0,
    for (final brand in compatible) ...brand.codeUnits,
  ];
}

void main() {
  group('sniffEncodedMediaFormat recognises', () {
    final table = <String, (Uint8List, EncodedMediaFormat)>{
      'JPEG': (
        _bytes([
          const [0xFF, 0xD8, 0xFF, 0xE0],
        ]),
        EncodedMediaFormat.jpeg,
      ),
      'PNG': (
        _bytes([
          const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        ]),
        EncodedMediaFormat.png,
      ),
      'GIF87a': (_bytes(['GIF87a']), EncodedMediaFormat.gif),
      'GIF89a': (_bytes(['GIF89a']), EncodedMediaFormat.gif),
      'BMP (BITMAPINFOHEADER)': (
        _bytes([
          'BM',
          List<int>.filled(12, 0),
          const [40, 0, 0, 0],
        ]),
        EncodedMediaFormat.bmp,
      ),
      'WebP': (
        _bytes([
          'RIFF',
          const [0, 0, 0, 0],
          'WEBP',
          'VP8 ',
        ]),
        EncodedMediaFormat.webp,
      ),
      'HEIC (major brand)': (
        _bytes([
          _ftyp('heic', ['mif1', 'heic']),
        ]),
        EncodedMediaFormat.heic,
      ),
      'HEIC (generic mif1 + heic brand)': (
        _bytes([
          _ftyp('mif1', ['mif1', 'heic']),
        ]),
        EncodedMediaFormat.heic,
      ),
      'AVIF (major brand)': (
        _bytes([
          _ftyp('avif', ['mif1', 'avif']),
        ]),
        EncodedMediaFormat.avif,
      ),
      'AVIF (generic mif1 + avif brand)': (
        _bytes([
          _ftyp('mif1', ['mif1', 'avif']),
        ]),
        EncodedMediaFormat.avif,
      ),
      'TIFF little-endian': (
        _bytes([
          const [0x49, 0x49, 0x2A, 0x00],
        ]),
        EncodedMediaFormat.tiff,
      ),
      'TIFF big-endian': (
        _bytes([
          const [0x4D, 0x4D, 0x00, 0x2A],
        ]),
        EncodedMediaFormat.tiff,
      ),
      'WAV': (
        _bytes([
          'RIFF',
          const [0, 0, 0, 0],
          'WAVE',
          'fmt ',
        ]),
        EncodedMediaFormat.wav,
      ),
      'MP3 (ID3 tag)': (
        _bytes([
          'ID3',
          const [4, 0],
        ]),
        EncodedMediaFormat.mp3,
      ),
      'MP3 (bare MPEG-1 layer III frame)': (
        _bytes([
          const [0xFF, 0xFB, 0x90, 0x64],
        ]),
        EncodedMediaFormat.mp3,
      ),
      'FLAC': (_bytes(['fLaC']), EncodedMediaFormat.flac),
      'Ogg': (_bytes(['OggS']), EncodedMediaFormat.ogg),
      'M4A': (
        _bytes([
          _ftyp('M4A ', ['M4A ', 'mp42', 'isom']),
        ]),
        EncodedMediaFormat.m4a,
      ),
    };
    table.forEach((label, row) {
      test(label, () => expect(sniffEncodedMediaFormat(row.$1), row.$2));
    });

    test('every known format has a row above', () {
      expect(
        table.values.map((row) => row.$2).toSet(),
        EncodedMediaFormat.known.toSet(),
      );
    });
  });

  group('sniffEncodedMediaFormat answers null for', () {
    final table = <String, Uint8List>{
      'no bytes': Uint8List(0),
      'garbage': _bytes(['not a media file']),
      'a PNG magic cut short': Uint8List.fromList(const [
        0x89,
        0x50,
        0x4E,
        0x47,
      ]),
      'RIFF that is neither WebP nor WAV (AVI)': _bytes([
        'RIFF',
        const [0, 0, 0, 0],
        'AVI ',
      ]),
      'an ISO-BMFF video (isom)': _bytes([
        _ftyp('isom', ['isom', 'mp41']),
      ]),
      'a generic HEIF without a heic or avif brand': _bytes([
        _ftyp('mif1', ['mif1', 'miaf']),
      ]),
      '"BM" with an impossible DIB header size': _bytes([
        'BM',
        List<int>.filled(12, 0),
        const [7, 0, 0, 0],
      ]),
      'AAC ADTS (frame sync, layer 00)': _bytes([
        const [0xFF, 0xF1, 0x50, 0x80],
      ]),
      'an MPEG frame header with a bad bitrate index': _bytes([
        const [0xFF, 0xFB, 0xF0, 0x64],
      ]),
    };
    table.forEach((label, bytes) {
      test(label, () => expect(sniffEncodedMediaFormat(bytes), isNull));
    });
  });

  group('EncodedMediaFormat', () {
    test('equality and hash are by name', () {
      final copy = debugCopyEncodedMediaFormat(EncodedMediaFormat.jpeg);
      expect(identical(copy, EncodedMediaFormat.jpeg), isFalse);
      expect(copy, EncodedMediaFormat.jpeg);
      expect(copy.hashCode, EncodedMediaFormat.jpeg.hashCode);
      expect(EncodedMediaFormat.jpeg, isNot(EncodedMediaFormat.png));
      expect(EncodedMediaFormat.jpeg.hashCode, 'jpeg'.hashCode);
      expect(EncodedMediaFormat.known.toSet(), hasLength(13));
    });

    test('a value that crossed an isolate still equals the constant', () async {
      final fromIsolate = await Isolate.run(() => EncodedMediaFormat.heic);
      expect(fromIsolate, EncodedMediaFormat.heic);
      expect({EncodedMediaFormat.heic}.contains(fromIsolate), isTrue);
    });

    test('names, MIME types and modalities', () {
      expect(
        {for (final f in EncodedMediaFormat.known) f.name: f.mimeType},
        {
          'jpeg': 'image/jpeg',
          'png': 'image/png',
          'gif': 'image/gif',
          'bmp': 'image/bmp',
          'webp': 'image/webp',
          'heic': 'image/heic',
          'avif': 'image/avif',
          'tiff': 'image/tiff',
          'wav': 'audio/wav',
          'mp3': 'audio/mpeg',
          'flac': 'audio/flac',
          'ogg': 'audio/ogg',
          'm4a': 'audio/mp4',
        },
      );
      expect(
        EncodedMediaFormat.known
            .where((f) => f.modality == EmbeddingModality.audio)
            .map((f) => f.name),
        ['wav', 'mp3', 'flac', 'ogg', 'm4a'],
      );
      expect(EncodedMediaFormat.webp.toString(), 'webp');
    });
  });

  group('detectImageMimeType (LLM web arms)', () {
    test('keeps the answers it gave before the sniffer existed', () {
      expect(
        detectImageMimeType(
          _bytes([
            const [0xFF, 0xD8, 0xFF, 0xE0],
          ]),
        ),
        'image/jpeg',
      );
      expect(
        detectImageMimeType(
          _bytes([
            const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
          ]),
        ),
        'image/png',
      );
      expect(
        detectImageMimeType(
          _bytes([
            'RIFF',
            const [0, 0, 0, 0],
            'WEBP',
          ]),
        ),
        'image/webp',
      );
      expect(
        detectImageMimeType(Uint8List.fromList(const [1, 2])),
        'image/png',
      );
      expect(detectImageMimeType(_bytes(['garbage'])), 'image/png');
    });

    test('names the other image formats it now recognises', () {
      expect(detectImageMimeType(_bytes(['GIF89a'])), 'image/gif');
      expect(
        detectImageMimeType(
          _bytes([
            _ftyp('heic', ['heic']),
          ]),
        ),
        'image/heic',
      );
    });

    test('never answers an audio type', () {
      expect(
        detectImageMimeType(
          _bytes([
            'RIFF',
            const [0, 0, 0, 0],
            'WAVE',
          ]),
        ),
        'image/png',
      );
    });
  });
}
