// The EmbeddingGemma 2 audio golden (R5 §10.4) and the clips it was measured
// on cannot drift apart.
//
// integration_test/tools/eg2_audio_golden.py writes the golden twice: as
// integration_test/goldens/eg2_audio_golden.json, and as the same JSON in a
// Dart string (eg2_audio_golden.dart), because a JSON file next to a test is
// not readable on a phone. This checks that the two agree, that every clip and
// variant in assets/eg2_audio/ is byte for byte the one measured, and that the
// combined inputs name files that exist. To regenerate, rerun the two tools
// (generate_eg2_audio_clips.py, then eg2_audio_golden.py) — never on CI.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/goldens/eg2_audio_golden.dart';

const _jsonPath = 'integration_test/goldens/eg2_audio_golden.json';
const _audio = 'assets/eg2_audio';
const _vision = 'assets/eg2_vision';

String _sha256(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();

void main() {
  final golden = jsonDecode(eg2AudioGoldenJson) as Map<String, dynamic>;

  test('the Dart golden is the JSON golden', () {
    expect(eg2AudioGoldenJson, File(_jsonPath).readAsStringSync());
  });

  test('every clip is the one measured', () {
    final clips = (golden['clips'] as Map).cast<String, dynamic>();
    expect(clips, hasLength(6));
    for (final MapEntry(:key, :value) in clips.entries) {
      final clip = (value as Map).cast<String, dynamic>();
      expect(clip['file'], '$key.wav');
      expect(
        _sha256('$_audio/${clip['file']}'),
        clip['sha256'],
        reason: '${clip['file']} changed since the golden was measured',
      );
      expect(clip['vector'], isA<String>());
      expect(clip['vector_native'], isA<String>());
      expect(clip['query'], isA<String>());
    }
  });

  test('every variant is the one measured', () {
    final variants = (golden['variants'] as Map).cast<String, dynamic>();
    expect(variants.keys, [
      'kitchen_lights_44k_stereo.wav',
      'kitchen_lights.mp3',
      'kitchen_lights.flac',
    ]);
    for (final MapEntry(:key, :value) in variants.entries) {
      expect(_sha256('$_audio/$key'), (value as Map)['sha256'], reason: key);
    }
  });

  test('every combined input names files that exist', () {
    final combined = (golden['combined'] as Map).cast<String, dynamic>();
    expect(combined.keys, [
      'text_image',
      'text_audio',
      'image_audio',
      'text_image_audio',
    ]);
    for (final value in combined.values) {
      final item = (value as Map).cast<String, dynamic>();
      for (final image in (item['images'] as List).cast<String>()) {
        expect(File('$_vision/$image').existsSync(), isTrue, reason: image);
      }
      final audio = item['audio'] as String?;
      if (audio != null) {
        expect(File('$_audio/$audio').existsSync(), isTrue, reason: audio);
      }
    }
  });

  test('the bundle is the pinned 740m', () {
    final bundle = (golden['bundle'] as Map).cast<String, dynamic>();
    expect(bundle['revision'], '24d962e906c7d332c6428e71c9676855024569e2');
    expect(
      bundle['sha256'],
      'e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c',
    );
  });

  test('core sniffs every committed clip as the container it is', () {
    final want = {
      'kitchen_lights.wav': EncodedMediaFormat.wav,
      'kitchen_lights_44k_stereo.wav': EncodedMediaFormat.wav,
      'kitchen_lights.mp3': EncodedMediaFormat.mp3,
      'kitchen_lights.flac': EncodedMediaFormat.flac,
      'kitchen_lights.ogg': EncodedMediaFormat.ogg,
      'kitchen_lights.m4a': EncodedMediaFormat.m4a,
      // A RIFF/WAVE header over garbage: passes the sniff, fails in the
      // engine (status 2).
      'corrupt_riff.wav': EncodedMediaFormat.wav,
    };
    for (final MapEntry(:key, :value) in want.entries) {
      expect(
        sniffEncodedMediaFormat(File('$_audio/$key').readAsBytesSync()),
        value,
        reason: key,
      );
    }
  });
}
