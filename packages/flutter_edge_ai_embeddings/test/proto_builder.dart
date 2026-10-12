// Builds SentencePiece `ModelProto` bytes field by field, for tests that need a
// model small enough to reason about. Wire format only: no protobuf package.

import 'dart:convert';
import 'dart:typed_data';

List<int> varint(int value) {
  final out = <int>[];
  var rest = value;
  while (rest >= 0x80) {
    out.add(rest & 0x7f | 0x80);
    rest >>= 7;
  }
  out.add(rest);
  return out;
}

List<int> varintField(int field, int value) => [
  ...varint(field << 3),
  ...varint(value),
];

List<int> bytesField(int field, List<int> bytes) => [
  ...varint(field << 3 | 2),
  ...varint(bytes.length),
  ...bytes,
];

List<int> stringField(int field, String value) =>
    bytesField(field, utf8.encode(value));

List<int> fixed32Field(int field, [double value = 0]) => [
  ...varint(field << 3 | 5),
  ...(ByteData(4)..setFloat32(0, value, Endian.little)).buffer.asUint8List(),
];

List<int> fixed64Field(int field) => [
  ...varint(field << 3 | 1),
  ...List.filled(8, 0),
];

/// `ModelProto.pieces` (1): `piece` (1), `score` (2), `type` (3; omitted when
/// null, i.e. NORMAL by default).
List<int> piece(String text, {double? score, int? type}) => bytesField(1, [
  ...stringField(1, text),
  if (score != null) ...fixed32Field(2, score),
  if (type != null) ...varintField(3, type),
]);

/// `ModelProto.trainer_spec` (2).
List<int> trainerSpec({
  int? modelType,
  bool? byteFallback,
  int? unkId,
  int? bosId,
  int? eosId,
  int? padId,
}) => bytesField(2, [
  if (modelType != null) ...varintField(3, modelType),
  if (byteFallback != null) ...varintField(35, byteFallback ? 1 : 0),
  if (unkId != null) ...varintField(40, unkId),
  if (bosId != null) ...varintField(41, bosId),
  if (eosId != null) ...varintField(42, eosId),
  if (padId != null) ...varintField(43, padId),
]);

/// `ModelProto.normalizer_spec` (3).
List<int> normalizerSpec({
  String? name,
  List<int>? charsmap,
  bool? addDummyPrefix,
  bool? removeExtraWhitespaces,
  bool? escapeWhitespaces,
}) => bytesField(3, [
  if (name != null) ...stringField(1, name),
  if (charsmap != null) ...bytesField(2, charsmap),
  if (addDummyPrefix != null) ...varintField(3, addDummyPrefix ? 1 : 0),
  if (removeExtraWhitespaces != null)
    ...varintField(4, removeExtraWhitespaces ? 1 : 0),
  if (escapeWhitespaces != null) ...varintField(5, escapeWhitespaces ? 1 : 0),
]);
