// What a photo goes through before EmbeddingGemma 2 sees it.
//
// LiteRT-LM decodes an image with stb_image: it ignores EXIF orientation, so a
// portrait photo from a phone camera (stored sideways with an Orientation tag)
// would be embedded lying on its side; and it decodes at full size, so a 12 MP
// original costs time and memory the model does not need — it scales every
// image down to its vision budget anyway. Flutter's own codec applies the EXIF
// orientation (its Skia generator orients the pixels; Android's platform
// decoder does too) and can decode straight to a smaller size, so the photo is
// decoded here, upright, with its long side at most [kMaxPhotoSide], and handed
// to the model as an uncompressed BMP — a format the engine accepts, with
// nothing for it to re-decode but the pixels. Google AI Edge Gallery does the
// same (downscale to 1024, uncompressed pixels).
//
// It also widens what the screen takes: anything Flutter decodes on this
// platform (WebP everywhere, HEIC on Android) becomes a BMP the model accepts;
// what Flutter cannot decode is a [PhotoDecodeException].
//
// Every platform, the web included: there the codec is CanvasKit's or skwasm's
// (the browser decodes), and the BMP is written on the page itself — `compute`
// runs inline on the web, where there are no isolates; `Isolate.run` would
// throw there.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;

/// The longest side a photo is given to the model with. Never scaled up.
const kMaxPhotoSide = 1024;

/// A photo ready for `EmbeddingInput.image`: an upright 24-bit BMP.
typedef PreparedPhoto = ({
  Uint8List bytes,
  int width,
  int height,
  int sourceWidth,
  int sourceHeight,
});

/// Flutter could not decode the bytes on this platform.
final class PhotoDecodeException implements Exception {
  const PhotoDecodeException(this.message);
  final String message;

  @override
  String toString() => 'PhotoDecodeException: $message';
}

/// Decodes [encoded] with Flutter's codec — EXIF orientation applied, the long
/// side scaled down to at most [maxSide] — and re-encodes it as a 24-bit BMP.
/// The pixel loop runs on a short-lived isolate on native platforms, and on
/// the page on the web (`compute`).
///
/// Throws [PhotoDecodeException] when Flutter cannot decode the bytes.
Future<PreparedPhoto> preparePhotoForEmbedding(
  Uint8List encoded, {
  int maxSide = kMaxPhotoSide,
}) async {
  var sourceWidth = 0;
  var sourceHeight = 0;
  final ui.Codec codec;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    codec = await ui.instantiateImageCodecWithSize(
      buffer,
      // The size Flutter reports is already oriented (an EXIF rotation swaps
      // it). Constrain only the long side: the other follows the aspect.
      getTargetSize: (width, height) {
        sourceWidth = width;
        sourceHeight = height;
        if (math.max(width, height) <= maxSide) {
          return const ui.TargetImageSize(); // never scaled up
        }
        return width >= height
            ? ui.TargetImageSize(width: maxSide)
            : ui.TargetImageSize(height: maxSide);
      },
    );
  } on Exception catch (e) {
    throw PhotoDecodeException('Flutter could not decode this image: $e');
  }
  try {
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } on Exception catch (e) {
      throw PhotoDecodeException('Flutter could not decode this image: $e');
    }
    try {
      final rgba = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (rgba == null) {
        throw const PhotoDecodeException('the decoded image has no pixels');
      }
      final width = image.width;
      final height = image.height;
      final pixels = rgba.buffer.asUint8List(
        rgba.offsetInBytes,
        rgba.lengthInBytes,
      );
      final bmp = await compute(_encodeBmp24Message, (
        pixels,
        width,
        height,
      ), debugLabel: 'photo-bmp');
      return (
        bytes: bmp,
        width: width,
        height: height,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
      );
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// [encodeBmp24] as `compute` calls it: one message, a top-level function.
Uint8List _encodeBmp24Message((Uint8List, int, int) message) {
  final (rgba, width, height) = message;
  return encodeBmp24(rgba, width: width, height: height);
}

/// A 24-bit, bottom-up, uncompressed (BI_RGB) BMP of [rgba] — straight RGBA,
/// row-major, [width] x [height]. Alpha is dropped. Pure; no `dart:ui`.
Uint8List encodeBmp24(
  Uint8List rgba, {
  required int width,
  required int height,
}) {
  if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    throw ArgumentError(
      'rgba holds ${rgba.length} bytes, not $width x $height x 4',
    );
  }
  final rowBytes = (width * 3 + 3) & ~3;
  const headerBytes = 14 + 40;
  final out = Uint8List(headerBytes + rowBytes * height);
  final h = ByteData.sublistView(out)
    // BITMAPFILEHEADER
    ..setUint8(0, 0x42) // 'B'
    ..setUint8(1, 0x4D) // 'M'
    ..setUint32(2, out.length, Endian.little)
    ..setUint32(10, headerBytes, Endian.little)
    // BITMAPINFOHEADER
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, height, Endian.little) // positive: bottom-up rows
    ..setUint16(26, 1, Endian.little) // planes
    ..setUint16(28, 24, Endian.little) // bits per pixel
    ..setUint32(30, 0, Endian.little) // BI_RGB
    ..setUint32(34, rowBytes * height, Endian.little)
    ..setInt32(38, 2835, Endian.little) // 72 dpi
    ..setInt32(42, 2835, Endian.little);
  assert(h.lengthInBytes == out.length);
  for (var y = 0; y < height; y++) {
    var src = y * width * 4;
    var dst = headerBytes + (height - 1 - y) * rowBytes;
    for (var x = 0; x < width; x++) {
      out[dst] = rgba[src + 2]; // B
      out[dst + 1] = rgba[src + 1]; // G
      out[dst + 2] = rgba[src]; // R
      src += 4;
      dst += 3;
    }
  }
  return out;
}
