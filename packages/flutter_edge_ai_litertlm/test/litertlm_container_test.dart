@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_container.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
