// A minimal reader for the SentencePiece `.model` file (a serialized
// `ModelProto`, sentencepiece_model.proto): the few fields this package needs
// and `dart_sentencepiece_tokenizer` either does not expose or reads wrong.
//
// - The piece types, for the user-defined pass (`user_defined_pieces.dart`).
// - The pieces whose text begins with U+FEFF. The dependency decodes every
//   piece with `utf8.decode`, which drops a leading byte-order mark, so in
//   Gemma's vocabulary `\ufeff<?` (140291) is read as `<?` and takes that
//   key from the real `<?` (8510), `\ufeff//` takes `//` from 715, and
//   `\ufeff` itself becomes the empty piece: XML, PHP and C++ text came out
//   with the wrong ids. [withLeadingBomsKept] rewrites the file so the
//   dependency reads them right.
//
// Strings are decoded here with the BOM kept ([_ProtoReader.utf8String]).

import 'dart:convert';
import 'dart:typed_data';

/// `ModelProto.TrainerSpec.ModelType.BPE`.
const bpeModelType = 2;

/// `ModelProto.SentencePiece.Type.USER_DEFINED`.
const userDefinedPieceType = 4;

/// U+FEFF as UTF-8.
const _bom = [0xEF, 0xBB, 0xBF];

/// The fields of a SentencePiece `ModelProto` this package reads:
///
/// - `pieces` (1): `piece` (1, string), `type` (3, enum, default NORMAL);
/// - `trainer_spec` (2): `model_type` (3, enum, default UNIGRAM);
/// - `normalizer_spec` (3): `precompiled_charsmap` (2, bytes),
///   `add_dummy_prefix` (3), `remove_extra_whitespaces` (4) and
///   `escape_whitespaces` (5), all bools that default to true.
///
/// Everything else is skipped by wire type.
final class SentencePieceModelProto {
  SentencePieceModelProto._();

  /// User-defined piece → id.
  final userDefined = <String, int>{};

  /// Id → text of every piece whose text begins with U+FEFF.
  final bomLed = <int, String>{};

  /// How many pieces the model has.
  int pieceCount = 0;

  int modelType = 1;
  bool hasCharsmap = false;
  bool addDummyPrefix = true;
  bool removeExtraWhitespaces = true;
  bool escapeWhitespaces = true;

  /// Parses [bytes].
  ///
  /// Throws [FormatException] on bytes that are not a well-formed `ModelProto`
  /// with at least one piece, and on a user-defined piece that is empty or
  /// defined twice — both of which SentencePiece itself refuses to load.
  static SentencePieceModelProto parse(Uint8List bytes) {
    final model = SentencePieceModelProto._();
    final reader = _ProtoReader(bytes, 0, bytes.length);
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch ((field, wire)) {
        case (1, _lengthDelimited):
          model._readPiece(reader.message(), model.pieceCount++);
        case (2, _lengthDelimited):
          final spec = reader.message();
          while (spec.hasMore) {
            final (f, w) = spec.tag();
            if ((f, w) == (3, _varint)) {
              model.modelType = spec.enumValue('model_type', _modelTypes);
            } else {
              spec.skip(w);
            }
          }
        case (3, _lengthDelimited):
          final spec = reader.message();
          while (spec.hasMore) {
            final (f, w) = spec.tag();
            switch ((f, w)) {
              case (2, _lengthDelimited):
                model.hasCharsmap = spec.message().length > 0;
              case (3, _varint):
                model.addDummyPrefix = spec.varint() != 0;
              case (4, _varint):
                model.removeExtraWhitespaces = spec.varint() != 0;
              case (5, _varint):
                model.escapeWhitespaces = spec.varint() != 0;
              default:
                spec.skip(w);
            }
          }
        default:
          reader.skip(wire);
      }
    }
    if (model.pieceCount == 0) {
      throw const FormatException('not a SentencePiece model: no pieces');
    }
    return model;
  }

  void _readPiece(_ProtoReader piece, int id) {
    _ProtoReader? text;
    var type = 1;
    while (piece.hasMore) {
      final (field, wire) = piece.tag();
      switch ((field, wire)) {
        case (1, _lengthDelimited):
          text = piece.message();
        case (3, _varint):
          type = piece.enumValue('piece type', _pieceTypes);
        default:
          piece.skip(wire);
      }
    }
    // Decoded only when needed: 6,410 user-defined and 6 BOM-led pieces of
    // Gemma's 262,144.
    if (text != null && text.startsWith(_bom)) bomLed[id] = text.utf8String();
    if (type != userDefinedPieceType) return;
    final value = text?.utf8String() ?? '';
    if (value.isEmpty) {
      throw FormatException('user-defined piece $id is empty');
    }
    final earlier = userDefined[value];
    if (earlier != null) {
      throw FormatException(
        'user-defined piece "$value" is defined twice (ids $earlier and $id)',
      );
    }
    userDefined[value] = id;
  }
}

/// [bytes] with one more U+FEFF in front of every piece whose text begins
/// with one, for a reader that drops one leading BOM per string: it then reads
/// the piece as it is. [bytes] itself when no piece begins with a BOM.
///
/// Only the `pieces` entries that change are re-encoded; every other byte is
/// copied as it is.
Uint8List withLeadingBomsKept(Uint8List bytes) {
  final out = BytesBuilder(copy: false);
  final reader = _ProtoReader(bytes, 0, bytes.length);
  var copiedTo = 0;
  var changed = false;
  while (reader.hasMore) {
    final fieldStart = reader.position;
    final (field, wire) = reader.tag();
    if ((field, wire) != (1, _lengthDelimited)) {
      reader.skip(wire);
      continue;
    }
    final piece = reader.message();
    final rewritten = _pieceWithBomKept(piece);
    if (rewritten == null) continue;
    out
      ..add(Uint8List.sublistView(bytes, copiedTo, fieldStart))
      ..add(_tagBytes(1, _lengthDelimited))
      ..add(_varintBytes(rewritten.length))
      ..add(rewritten);
    copiedTo = reader.position;
    changed = true;
  }
  if (!changed) return bytes;
  out.add(Uint8List.sublistView(bytes, copiedTo));
  return out.takeBytes();
}

/// The `SentencePiece` message [piece] with U+FEFF added in front of its text,
/// or null when its text does not begin with one.
Uint8List? _pieceWithBomKept(_ProtoReader piece) {
  final out = BytesBuilder(copy: false);
  var changed = false;
  while (piece.hasMore) {
    final fieldStart = piece.position;
    final (field, wire) = piece.tag();
    if ((field, wire) == (1, _lengthDelimited)) {
      final text = piece.message();
      if (text.startsWith(_bom)) {
        final value = text.bytes();
        out
          ..add(_tagBytes(1, _lengthDelimited))
          ..add(_varintBytes(_bom.length + value.length))
          ..add(_bom)
          ..add(value);
        changed = true;
        continue;
      }
    } else {
      piece.skip(wire);
    }
    out.add(piece.bytesFrom(fieldStart));
  }
  return changed ? out.takeBytes() : null;
}

List<int> _tagBytes(int field, int wire) => _varintBytes(field << 3 | wire);

List<int> _varintBytes(int value) {
  final out = <int>[];
  var rest = value;
  while (rest >= 0x80) {
    out.add(rest & 0x7f | 0x80);
    rest >>= 7;
  }
  out.add(rest);
  return out;
}

const _varint = 0;
const _fixed64 = 1;
const _lengthDelimited = 2;
const _fixed32 = 5;
const _wireTypes = {_varint, _fixed64, _lengthDelimited, _fixed32};

/// `ModelProto.SentencePiece.Type`: NORMAL, UNKNOWN, CONTROL, USER_DEFINED,
/// UNUSED, BYTE.
const _pieceTypes = {1, 2, 3, 4, 5, 6};

/// `ModelProto.TrainerSpec.ModelType`: UNIGRAM, BPE, WORD, CHAR.
const _modelTypes = {1, 2, 3, 4};

/// Reads protobuf wire format from `[position, _end)` of [_bytes].
final class _ProtoReader {
  _ProtoReader(this._bytes, this.position, this._end);

  final Uint8List _bytes;
  int position;
  final int _end;

  bool get hasMore => position < _end;

  int get length => _end - position;

  /// The next field's number and wire type. Throws [FormatException] for a
  /// field number outside 1..2^29 - 1 (the tag must be a 32-bit value) and a
  /// wire type this reader does not take (groups, 3 and 4, are deprecated and
  /// absent from `ModelProto`; 6 and 7 do not exist).
  (int, int) tag() {
    final tag = varint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (tag < 0 || tag > 0xFFFFFFFF || field == 0) {
      throw FormatException('protobuf field number $field is out of range');
    }
    if (!_wireTypes.contains(wire)) {
      throw FormatException(
        'unsupported protobuf wire type $wire (field $field)',
      );
    }
    return (field, wire);
  }

  /// A base-128 varint, as protobuf's 64-bit two's complement: bit 63 makes
  /// the result negative, as a negative int32 is written.
  ///
  /// Throws [FormatException] when the input ends inside it, and when it has a
  /// 10th byte other than 0x01. That byte carries bit 63 alone: a larger
  /// value overflows 64 bits (and used to wrap silently, which could turn a
  /// piece type into USER_DEFINED), and 0 or a continuation is a longer
  /// encoding than any protobuf writer produces.
  int varint() {
    var result = 0;
    for (var index = 0; index < 10; index++) {
      if (position >= _end) {
        throw const FormatException('truncated protobuf varint');
      }
      final byte = _bytes[position++];
      if (index == 9) {
        if (byte != 0x01) {
          throw FormatException(
            'protobuf varint with 10th byte 0x${byte.toRadixString(16)}: '
            'it overflows 64 bits or is not canonical',
          );
        }
        return result | (1 << 63);
      }
      result |= (byte & 0x7f) << (7 * index);
      if (byte & 0x80 == 0) return result;
    }
    throw StateError('unreachable: the loop returns by its 10th byte');
  }

  /// A varint that must be one of [values] — a proto enum this reader acts
  /// on. Throws [FormatException] naming [what] otherwise.
  int enumValue(String what, Set<int> values) {
    final value = varint();
    if (!values.contains(value)) {
      throw FormatException('$what $value is not one $values allows');
    }
    return value;
  }

  /// A length-delimited field, as a reader over its bytes.
  _ProtoReader message() {
    final length = _length();
    final start = position;
    _advance(length);
    return _ProtoReader(_bytes, start, start + length);
  }

  /// The unread bytes.
  Uint8List bytes() => Uint8List.sublistView(_bytes, position, _end);

  /// The bytes from [start] to the current position.
  Uint8List bytesFrom(int start) =>
      Uint8List.sublistView(_bytes, start, position);

  bool startsWith(List<int> prefix) {
    if (length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (_bytes[position + i] != prefix[i]) return false;
    }
    return true;
  }

  /// The unread bytes as UTF-8, every leading U+FEFF KEPT. Dart's decoder
  /// drops one at the start of its input, so they are counted off first and
  /// put back.
  String utf8String() {
    var start = position;
    var boms = 0;
    while (_end - start >= _bom.length &&
        _bytes[start] == _bom[0] &&
        _bytes[start + 1] == _bom[1] &&
        _bytes[start + 2] == _bom[2]) {
      start += _bom.length;
      boms++;
    }
    final rest = utf8.decode(Uint8List.sublistView(_bytes, start, _end));
    return '${'\ufeff' * boms}$rest';
  }

  void skip(int wire) {
    switch (wire) {
      case _varint:
        varint();
      case _fixed64:
        _advance(8);
      case _lengthDelimited:
        _advance(_length());
      case _fixed32:
        _advance(4);
      default:
        throw FormatException('unsupported protobuf wire type $wire');
    }
  }

  /// A length prefix: a varint that must fit the bytes left.
  int _length() {
    final length = varint();
    if (length < 0 || length > _end - position) {
      throw FormatException(
        'protobuf length $length does not fit the ${_end - position} bytes '
        'left',
      );
    }
    return length;
  }

  void _advance(int count) {
    if (count < 0 || count > _end - position) {
      throw const FormatException('truncated protobuf field');
    }
    position += count;
  }
}
