// The image-search screen's photo preparation, on Flutter's real codec (no
// model): EXIF orientation applied, the long side scaled to at most 1024 and
// never up, the result a 24-bit BMP that decodes back to the same pixels, and
// a typed refusal for bytes Flutter cannot decode.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/image_search/eg2_vision_samples.dart';
import 'package:flutter_edge_ai_example/image_search/photo_preparation.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _asset(String key) => File(key).readAsBytesSync();

Future<({int width, int height, Uint8List rgba})> _decode(
  Uint8List bytes,
) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  final out = (
    width: image.width,
    height: image.height,
    rgba: data!.buffer.asUint8List(),
  );
  image.dispose();
  codec.dispose();
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encodeBmp24', () {
    test('a 2x2 image: headers, bottom-up BGR rows padded to 4 bytes', () {
      // Row 0: red, green; row 1: blue, white. Alpha is dropped.
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 0, 255, 0, 255, //
        0, 0, 255, 255, 255, 255, 255, 128,
      ]);
      final bmp = encodeBmp24(rgba, width: 2, height: 2);
      final h = ByteData.sublistView(bmp);
      expect(String.fromCharCodes(bmp.sublist(0, 2)), 'BM');
      // 2 px * 3 bytes = 6, padded to 8 per row.
      expect(h.getUint32(2, Endian.little), 14 + 40 + 2 * 8);
      expect(h.getUint32(10, Endian.little), 54);
      expect(h.getUint32(14, Endian.little), 40);
      expect(h.getInt32(18, Endian.little), 2);
      expect(h.getInt32(22, Endian.little), 2, reason: 'positive: bottom-up');
      expect(h.getUint16(28, Endian.little), 24);
      expect(h.getUint32(30, Endian.little), 0, reason: 'BI_RGB');
      expect(bmp.sublist(54), [
        255, 0, 0, 255, 255, 255, 0, 0, // bottom row first: blue, white
        0, 0, 255, 0, 255, 0, 0, 0, // then the top: red, green (BGR)
      ]);
      expect(sniffEncodedMediaFormat(bmp), EncodedMediaFormat.bmp);
    });

    test('refuses a buffer that does not match the size', () {
      expect(
        () => encodeBmp24(Uint8List(3), width: 1, height: 1),
        throwsArgumentError,
      );
    });
  });

  group('preparePhotoForEmbedding (Flutter\'s codec)', () {
    test('a small PNG: same size, never scaled up, and the BMP decodes to '
        'the same pixels', () async {
      final png = _asset(eg2VisionSampleAsset('circle'));
      final prepared = await preparePhotoForEmbedding(png);
      expect((prepared.width, prepared.height), (640, 480));
      expect((prepared.sourceWidth, prepared.sourceHeight), (640, 480));
      expect(sniffEncodedMediaFormat(prepared.bytes), EncodedMediaFormat.bmp);
      final fromPng = await _decode(png);
      final fromBmp = await _decode(prepared.bytes);
      expect((fromBmp.width, fromBmp.height), (640, 480));
      var maxDiff = 0;
      for (var i = 0; i < fromPng.rgba.length; i += 4) {
        for (var c = 0; c < 3; c++) {
          final d = (fromPng.rgba[i + c] - fromBmp.rgba[i + c]).abs();
          if (d > maxDiff) maxDiff = d;
        }
      }
      expect(maxDiff, 0, reason: 'lossless');
    });

    test('EXIF orientation is applied: the rotated camera JPEG comes out '
        'upright, like its upright twin', () async {
      final rotated = await preparePhotoForEmbedding(
        _asset('assets/eg2_vision/portrait_exif6.jpg'),
      );
      final upright = await preparePhotoForEmbedding(
        _asset('assets/eg2_vision/portrait_upright.jpg'),
      );
      expect((rotated.width, rotated.height), (480, 640));
      expect((upright.width, upright.height), (480, 640));
      final a = await _decode(rotated.bytes);
      final b = await _decode(upright.bytes);
      var sum = 0;
      for (var i = 0; i < a.rgba.length; i++) {
        sum += (a.rgba[i] - b.rgba[i]).abs();
      }
      expect(
        sum / a.rgba.length,
        lessThan(3),
        reason: 'the same picture, not a rotated one',
      );
    });

    test(
      'a 12 MP photo comes out with its long side at 1024, aspect kept',
      () async {
        final prepared = await preparePhotoForEmbedding(
          _asset('assets/eg2_vision/large_12mp.jpg'),
        );
        expect((prepared.sourceWidth, prepared.sourceHeight), (4032, 3024));
        expect((prepared.width, prepared.height), (1024, 768));
      },
    );

    test('a portrait photo is limited on its long side, the height', () async {
      // The EXIF twin is 480x640; with a 320 limit the height is the long side.
      final prepared = await preparePhotoForEmbedding(
        _asset('assets/eg2_vision/portrait_exif6.jpg'),
        maxSide: 320,
      );
      expect((prepared.width, prepared.height), (240, 320));
    });

    test('WebP decodes (Flutter has a decoder for it)', () async {
      final prepared = await preparePhotoForEmbedding(
        _asset('assets/eg2_vision/small_circle.webp'),
      );
      expect((prepared.width, prepared.height), (160, 120));
    });

    test('bytes Flutter cannot decode are a PhotoDecodeException', () async {
      await expectLater(
        preparePhotoForEmbedding(Uint8List.fromList(List.filled(64, 7))),
        throwsA(isA<PhotoDecodeException>()),
      );
    });
  });

  test('the preparation runs on the web too: no isolate API, the BMP is '
      'written through compute (inline on the web)', () {
    // `Isolate.run` throws on the web, and the Image Search screen runs there
    // (P2w); the browser half is example/integration_test/web_eg2_test.dart.
    final source = File(
      'lib/image_search/photo_preparation.dart',
    ).readAsStringSync();
    expect(source, isNot(contains("'dart:isolate'")));
    expect(source, isNot(contains('Isolate.run(')));
    expect(source, isNot(contains('Isolate.spawn(')));
    expect(source, contains('compute('));
  });
}
