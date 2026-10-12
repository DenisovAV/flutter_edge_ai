@TestOn('vm')
library;

// The minimal `ModelProto` reader (`src/sentencepiece_model_proto.dart`): the
// fields it reads, the proto2 defaults it assumes, what it skips and refuses,
// and the rewrite that keeps a piece's leading U+FEFF through
// `dart_sentencepiece_tokenizer`'s reader, which drops it.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_embeddings/src/embedding_tokenizer.dart';
import 'package:flutter_edge_ai_embeddings/src/sentencepiece_model_proto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'proto_builder.dart';

const _eg1Model =
    '../flutter_edge_ai/example/assets/models/sentencepiece.model';

final _bom = String.fromCharCode(0xFEFF);
final _escapedSpace = String.fromCharCode(0x2581);

Uint8List _model(List<List<int>> fields) =>
    Uint8List.fromList([for (final f in fields) ...f]);

void main() {
  group('the EmbeddingGemma 1 sentencepiece.model', () {
    final bytes = File(_eg1Model).readAsBytesSync();
    final model = SentencePieceModelProto.parse(bytes);

    test('has the counts the Python reference reports', () {
      expect(model.pieceCount, 262144);
      expect(model.userDefined, hasLength(6410));
    });

    test('maps its user-defined pieces to their ids', () {
      expect(model.userDefined['</div>'], 235);
      expect(model.userDefined['<mask>'], 4);
      expect(model.userDefined['[multimodal]'], 5);
      expect(model.userDefined['$_escapedSpace$_escapedSpace'], 138);
      expect(model.userDefined['\n'], 107);
      expect(model.userDefined['<?'], isNull, reason: 'a normal piece');
    });

    test('is BPE with only spaces escaped: the pass applies', () {
      expect(model.modelType, bpeModelType);
      expect(model.hasCharsmap, isFalse);
      expect(model.addDummyPrefix, isFalse);
      expect(model.removeExtraWhitespaces, isFalse);
      expect(model.escapeWhitespaces, isTrue);
    });

    test('lists its six BOM-led pieces with the BOM kept', () {
      expect(model.bomLed, {
        88979: '$_bom$_bom',
        135260: '$_bom//',
        140291: '$_bom<?',
        180799: '$_bom$_bom$_bom$_bom',
        208867: '$_bom#',
        237922: _bom,
      });
    });

    test('through loadEmbeddingTokenizer, `<?` and `//` keep their own ids '
        'and the BOM pieces theirs', () async {
      final tokenizer = await loadEmbeddingTokenizer(_eg1Model);
      expect(tokenizer.convertTokensToIds(['<?', '//', '#', _bom, '$_bom<?']), [
        8510,
        715,
        236865,
        237922,
        140291,
      ]);
      expect(tokenizer.convertIdsToTokens([237922, 140291]), [_bom, '$_bom<?']);
    });
  });

  group('parse', () {
    test('applies the proto2 defaults to absent fields', () {
      final model = SentencePieceModelProto.parse(_model([piece('a')]));
      expect(model.pieceCount, 1);
      expect(model.modelType, 1, reason: 'UNIGRAM');
      expect(model.addDummyPrefix, isTrue);
      expect(model.removeExtraWhitespaces, isTrue);
      expect(model.escapeWhitespaces, isTrue);
      expect(model.hasCharsmap, isFalse);
      expect(model.userDefined, isEmpty);
    });

    test('reads the trainer and normalizer fields', () {
      final model = SentencePieceModelProto.parse(
        _model([
          piece('a'),
          trainerSpec(modelType: bpeModelType),
          normalizerSpec(
            charsmap: [1, 2, 3],
            addDummyPrefix: false,
            removeExtraWhitespaces: false,
            escapeWhitespaces: false,
          ),
        ]),
      );
      expect(model.modelType, bpeModelType);
      expect(model.hasCharsmap, isTrue);
      expect(model.addDummyPrefix, isFalse);
      expect(model.removeExtraWhitespaces, isFalse);
      expect(model.escapeWhitespaces, isFalse);
    });

    test('an empty charsmap is no charsmap', () {
      final model = SentencePieceModelProto.parse(
        _model([piece('a'), normalizerSpec(charsmap: const [])]),
      );
      expect(model.hasCharsmap, isFalse);
    });

    test('skips unknown fields of every wire type, and reads a piece\'s '
        'fields in any order', () {
      final model = SentencePieceModelProto.parse(
        _model([
          varintField(9, 300),
          fixed64Field(10),
          fixed32Field(11),
          bytesField(12, [1, 2, 3]),
          // type before text, an unknown varint and a score between.
          bytesField(1, [
            ...varintField(3, userDefinedPieceType),
            ...varintField(7, 1),
            ...fixed32Field(2),
            ...stringField(1, '<x>'),
          ]),
          piece('<y>', type: userDefinedPieceType),
        ]),
      );
      expect(model.userDefined, {'<x>': 0, '<y>': 1});
    });

    test('keeps every leading U+FEFF of a piece', () {
      final model = SentencePieceModelProto.parse(
        _model([
          piece('a'),
          piece('$_bom${_bom}x', type: userDefinedPieceType),
        ]),
      );
      expect(model.userDefined, {'$_bom${_bom}x': 1});
      expect(model.bomLed, {1: '$_bom${_bom}x'});
    });

    final onePiece = piece('a');
    final nineContinuations = List.filled(9, 0xFF);
    for (final (name, bytes) in [
      ('no pieces', <int>[]),
      ('a truncated varint', [0x08, 0x80]),
      ('a truncated length-delimited field', [0x0A, 5, 1, 2]),
      ('a group (wire type 3)', [0x0B]),
      ('an end-group tag (wire type 4)', [...onePiece, 0x0C]),
      ('wire type 6', [...onePiece, 0x0E]),
      ('wire type 7', [...onePiece, 0x0F]),
      ('field number 0', [0x00]),
      // 2^29 is one past protobuf's largest field number; a varint value
      // follows, so only the field number is wrong.
      ('a field number above 2^29 - 1', [...onePiece, ...varint(1 << 32), 0]),
      // A 10-byte varint carries bit 63 in its last byte, which must be 1:
      // anything above overflows 64 bits (and wrapped silently before).
      (
        'a varint whose 10th byte overflows 64 bits',
        [...onePiece, 0x48, ...nineContinuations, 0x02],
      ),
      (
        'a varint with a 10th byte of 0 (not canonical)',
        [...onePiece, 0x48, ...nineContinuations, 0x00],
      ),
      (
        'a varint longer than 10 bytes',
        [...onePiece, 0x48, ...nineContinuations, 0x81, 0x01],
      ),
      (
        'a length that does not fit in 63 bits',
        [...onePiece, 0x52, ...nineContinuations, 0x01, 0x41],
      ),
      ('a piece type outside the enum (0)', piece('b', type: 0)),
      ('a piece type outside the enum (7)', piece('b', type: 7)),
      (
        'a piece type that is a wrapped 64-bit value',
        bytesField(1, [
          ...stringField(1, 'b'),
          0x18,
          ...nineContinuations,
          0x01,
        ]),
      ),
      (
        'a model type outside the enum (0)',
        [...onePiece, ...trainerSpec(modelType: 0)],
      ),
      (
        'a model type outside the enum (5)',
        [...onePiece, ...trainerSpec(modelType: 5)],
      ),
    ]) {
      test('refuses $name', () {
        expect(
          () => SentencePieceModelProto.parse(Uint8List.fromList(bytes)),
          throwsFormatException,
        );
      });
    }

    test('reads a canonical 10-byte varint: a negative int32, as protobuf '
        'writes bos_id = -1', () {
      final model = SentencePieceModelProto.parse(
        _model([
          piece('a'),
          // trainer_spec { bos_id (41): -1 } — ten bytes, the last one 0x01.
          bytesField(2, [0xC8, 0x02, ...nineContinuations, 0x01]),
          trainerSpec(modelType: bpeModelType),
        ]),
      );
      expect(model.modelType, bpeModelType);
    });

    test('refuses an empty user-defined piece and a duplicate, as '
        'SentencePiece does', () {
      expect(
        () => SentencePieceModelProto.parse(
          _model([piece('', type: userDefinedPieceType)]),
        ),
        throwsA(
          isFormatException.having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
      expect(
        () => SentencePieceModelProto.parse(
          _model([
            piece('<x>', type: userDefinedPieceType),
            piece('<x>', type: userDefinedPieceType),
          ]),
        ),
        throwsA(
          isFormatException.having(
            (e) => e.message,
            'message',
            contains('defined twice'),
          ),
        ),
      );
    });
  });

  group('withLeadingBomsKept', () {
    test('returns the same bytes when no piece begins with a BOM', () {
      final bytes = _model([piece('a'), piece('b', score: -1)]);
      expect(identical(withLeadingBomsKept(bytes), bytes), isTrue);
    });

    test('adds one BOM in front of each BOM-led piece and changes nothing '
        'else', () {
      final bytes = _model([
        trainerSpec(modelType: bpeModelType),
        piece('a', score: -1),
        piece('${_bom}b', score: -2, type: userDefinedPieceType),
        piece(_bom, score: -3),
        normalizerSpec(addDummyPrefix: false),
      ]);
      final rewritten = withLeadingBomsKept(bytes);
      expect(
        rewritten,
        _model([
          trainerSpec(modelType: bpeModelType),
          piece('a', score: -1),
          piece('$_bom${_bom}b', score: -2, type: userDefinedPieceType),
          piece('$_bom$_bom', score: -3),
          normalizerSpec(addDummyPrefix: false),
        ]),
      );
    });
  });
}
