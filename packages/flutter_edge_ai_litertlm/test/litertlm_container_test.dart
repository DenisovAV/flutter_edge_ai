@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_container_io.dart';
import 'package:flutter_edge_ai_litertlm/src/litertlm_flatbuffer.dart'
    show litertlmHeaderEnd;
import 'package:flutter_test/flutter_test.dart';

import 'web/eg2_header_fixtures.dart';

/// The container headers of the three EmbeddingGemma 2 bundles, cut at their
/// header end. See test/ffi/fixtures/README.md.
const _header270m = 'test/ffi/fixtures/embeddinggemma2_270m_header.litertlm';
const _header440m = 'test/ffi/fixtures/embeddinggemma2_440m_header.litertlm';
const _header740m = 'test/ffi/fixtures/embeddinggemma2_740m_header.litertlm';

String _tempCopy(String fixture, void Function(Uint8List bytes) mutate) {
  final dir = Directory.systemTemp.createTempSync('litertlm_container_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final bytes = File(fixture).readAsBytesSync();
  mutate(bytes);
  final path = '${dir.path}/model.litertlm';
  File(path).writeAsBytesSync(bytes);
  return path;
}

void main() {
  group('readLitertlmModelTypes on the real EmbeddingGemma 2 headers', () {
    test('270m: the text tower only', () {
      final types = readLitertlmModelTypes(_header270m);
      expect(types, ['tf_lite_embedder', 'tf_lite_text_encoder']);
      expect(litertlmHasAudioEncoder(types), isFalse);
    });

    test('440m: text and vision, no audio (ModelInfo claims audio)', () {
      final types = readLitertlmModelTypes(_header440m);
      expect(
        types,
        containsAll([
          'tf_lite_text_encoder',
          'tf_lite_vision_encoder',
          'tf_lite_vision_adapter',
        ]),
      );
      expect(types.where((t) => t.contains('audio')), isEmpty);
      expect(litertlmHasAudioEncoder(types), isFalse);
    });

    test('740m: the audio encoder is there', () {
      final types = readLitertlmModelTypes(_header740m);
      expect(
        types,
        containsAll([
          'tf_lite_audio_encoder_hw',
          'tf_lite_audio_adapter',
          'tf_lite_end_of_audio',
          'tf_lite_vision_encoder',
          'tf_lite_text_encoder',
        ]),
      );
      expect(litertlmHasAudioEncoder(types), isTrue);
    });
  });

  group('litertlmHasAudioEncoder', () {
    test('only an audio ENCODER counts, not its adapter or end marker', () {
      expect(
        litertlmHasAudioEncoder([
          'tf_lite_audio_adapter',
          'tf_lite_end_of_audio',
          'tf_lite_audio_frontend',
        ]),
        isFalse,
      );
      expect(litertlmHasAudioEncoder(['tf_lite_audio_encoder']), isTrue);
      expect(litertlmHasAudioEncoder(const []), isFalse);
    });
  });

  group('the media towers are the two keys LiteRT-LM builds an executor for '
      '(kTfLiteVisionEncoder, kTfLiteAudioEncoderHw)', () {
    test('on the real headers: the 440m and the 740m carry exactly those keys '
        'beside their adapters and end-of markers', () {
      final t440 = readLitertlmModelTypes(_header440m);
      final t740 = readLitertlmModelTypes(_header740m);
      expect(t440, containsAll(['tf_lite_vision_encoder']));
      expect(
        t740,
        containsAll(['tf_lite_vision_encoder', 'tf_lite_audio_encoder_hw']),
      );
      expect(litertlmHasVisionTower(t440), isTrue);
      expect(litertlmHasAudioTower(t440), isFalse);
      expect(litertlmHasVisionTower(t740), isTrue);
      expect(litertlmHasAudioTower(t740), isTrue);
      final t270 = readLitertlmModelTypes(_header270m);
      expect(litertlmHasVisionTower(t270), isFalse);
      expect(litertlmHasAudioTower(t270), isFalse);
    });

    test('an adapter or an end-of marker alone is no tower: upstream builds '
        'no executor for it, and naming its backend would fail create', () {
      for (final types in [
        ['tf_lite_end_of_vision'],
        ['tf_lite_vision_adapter'],
        ['tf_lite_end_of_vision', 'tf_lite_vision_adapter'],
        ['tf_lite_vision_encoder_v2'],
        ['tf_lite_end_of_audio', 'tf_lite_end_of_vision'],
      ]) {
        expect(litertlmHasVisionTower(types), isFalse, reason: '$types');
      }
      for (final types in [
        ['tf_lite_end_of_audio'],
        ['tf_lite_audio_adapter'],
        ['tf_lite_audio_encoder'],
        ['tf_lite_audio_frontend', 'tf_lite_end_of_vision'],
      ]) {
        expect(litertlmHasAudioTower(types), isFalse, reason: '$types');
      }
      expect(litertlmHasVisionTower(['tf_lite_vision_encoder']), isTrue);
      expect(litertlmHasAudioTower(['tf_lite_audio_encoder_hw']), isTrue);
      expect(litertlmHasVisionTower(['tf_lite_audio_encoder_hw']), isFalse);
      expect(litertlmHasAudioTower(['tf_lite_vision_encoder']), isFalse);
    });
  });

  test('a model_type whose value is not a string is not read as one', () {
    // Byte 1539 of the 740m header is the union discriminator (value_type)
    // of the audio encoder section's model_type pair: 9, StringValue. As 5
    // (UInt32) the pair no longer names a type, so the bundle reads as having
    // no audio encoder rather than reinterpreting a number as text.
    final path = _tempCopy(_header740m, (b) {
      expect(b[1539], 9);
      b[1539] = 5;
    });
    final types = readLitertlmModelTypes(path);
    expect(types, isNot(contains('tf_lite_audio_encoder_hw')));
    expect(types, contains('tf_lite_audio_adapter'));
    expect(litertlmHasAudioEncoder(types), isFalse);
  });

  group(
    'a file it cannot read is a FormatException or FileSystemException',
    () {
      test('wrong magic', () {
        expect(
          () => readLitertlmModelTypes(
            _tempCopy(_header740m, (b) => b[0] = 0x58),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('LITERTLM'),
            ),
          ),
        );
      });

      test('a container major version it does not know', () {
        expect(
          () => readLitertlmModelTypes(_tempCopy(_header740m, (b) => b[8] = 2)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('version 2'),
            ),
          ),
        );
      });

      test('a header end before the preamble or past 1 MB', () {
        for (final end in [16, (1 << 20) + 33]) {
          final path = _tempCopy(_header740m, (b) {
            ByteData.sublistView(b).setUint64(24, end, Endian.little);
          });
          expect(
            () => readLitertlmModelTypes(path),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains('out of range'),
              ),
            ),
            reason: 'header end $end',
          );
        }
      });

      test('a header cut short', () {
        final dir = Directory.systemTemp.createTempSync('litertlm_container');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/cut.litertlm';
        File(
          path,
        ).writeAsBytesSync(File(_header740m).readAsBytesSync().sublist(0, 900));
        expect(
          () => readLitertlmModelTypes(path),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('ends at 900'),
            ),
          ),
        );
      });

      test('a flatbuffer whose offsets point outside it', () {
        // The root offset at byte 32 sends the reader past the header's end.
        final path = _tempCopy(_header740m, (b) {
          b
            ..[32] = 0xF0
            ..[33] = 0xFF
            ..[34] = 0x00
            ..[35] = 0x00;
        });
        expect(() => readLitertlmModelTypes(path), throwsFormatException);
      });

      test('a missing file', () {
        expect(
          () => readLitertlmModelTypes('/nonexistent/model.litertlm'),
          throwsA(isA<FileSystemException>()),
        );
      });
    },
  );

  group('readLitertlmModelTypesFrom: the same header through a reader of the '
      'file\'s first bytes (the web\'s fetch)', () {
    for (final (fixture, end, audio) in [
      (_header270m, 880, false),
      (_header440m, 1552, false),
      (_header740m, 2176, true),
    ]) {
      test('$fixture: the preamble, then up to the header end — the native '
          'reader\'s answer', () async {
        final bytes = File(fixture).readAsBytesSync();
        final asked = <int>[];
        final types = await readLitertlmModelTypesFrom((length) async {
          asked.add(length);
          // A file far longer than its header: the reader serves only the
          // prefix it is asked for.
          return Uint8List.sublistView(bytes, 0, length);
        });
        expect(asked, [32, end]);
        expect(types, readLitertlmModelTypes(fixture));
        expect(litertlmHasAudioEncoder(types), audio);
      });
    }

    test('a file shorter than its header end: FormatException', () async {
      final bytes = File(_header740m).readAsBytesSync();
      await expectLater(
        readLitertlmModelTypesFrom(
          (length) async =>
              Uint8List.sublistView(bytes, 0, length.clamp(0, 1000)),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('ends at 1000, expected 2176'),
          ),
        ),
      );
      await expectLater(
        readLitertlmModelTypesFrom((_) async => Uint8List(10)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('ends at 10, expected 32'),
          ),
        ),
      );
    });

    test('what the reader throws passes through', () async {
      final failure = StateError('TypeError: Failed to fetch');
      await expectLater(
        readLitertlmModelTypesFrom((_) async => throw failure),
        throwsA(same(failure)),
      );
    });

    test('a header end with a non-zero high word is out of range (read as two '
        'uint32 halves, so dart2js can run it)', () {
      final bytes = File(_header740m).readAsBytesSync();
      ByteData.sublistView(bytes).setUint32(28, 1, Endian.little);
      expect(
        () => litertlmHeaderEnd(bytes),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('out of range'),
          ),
        ),
      );
    });

    test('the browser suites\' base64 copies are the fixtures', () {
      expect(eg2Header270m, File(_header270m).readAsBytesSync());
      expect(eg2Header740m, File(_header740m).readAsBytesSync());
    });
  });
}
