// A `GenericBinaryData` section of a `.litertlm` file, found by the `name`
// item LiteRT-LM's `litertlm_builder` and litetune's `bundle` write, and read
// without loading the model. LiteRT-LM never maps such a section, so a file
// can carry data for its caller at no cost to the engine.

import 'dart:io';
import 'dart:typed_data';

import 'litertlm_flatbuffer.dart';
import 'litertlm_generic_limits.dart';

export 'litertlm_generic_limits.dart';

/// `AnySectionDataType.GenericBinaryData` in `litertlm_header_schema.fbs`.
const _genericBinaryData = 1;

/// `VData.StringValue`: the union discriminator (NONE is 0).
const _stringValue = 9;

/// The bytes of the `GenericBinaryData` section of the `.litertlm` file at
/// [path] whose `name` item is [name], or null when it has none. Reads the
/// container header and that one section, nothing else.
///
/// Throws [FormatException] for a file that is not a `.litertlm` container
/// this reader understands, a section of that name of another data type or
/// whose name is not a string, two sections of that name, and a range outside
/// the file or above [maxBytes].
Future<Uint8List?> readBundleGenericData(
  String path,
  String name, {
  int maxBytes = maxGenericDataBytes,
}) async {
  final file = await File(path).open();
  try {
    final headerEnd = litertlmHeaderEnd(await _readExactly(file, 0, 32));
    final header = await _readExactly(file, 32, headerEnd - 32);
    final range = genericDataRange(
      header,
      name,
      headerEnd: headerEnd,
      maxBytes: maxBytes,
    );
    if (range == null) return null;
    final (begin, end) = range;
    return await _readExactly(file, begin, end - begin);
  } finally {
    await file.close();
  }
}

/// The `[begin, end)` byte range of the `GenericBinaryData` section named
/// [name], from the header flatbuffer that follows the 32-byte preamble (the
/// file's header ends at [headerEnd]), or null when the bundle has none. A
/// section that carries the name in another form — on a section of another
/// data type, or as a value that is not a string — is a [FormatException],
/// not "none": it is data this release cannot read.
(int, int)? genericDataRange(
  Uint8List header,
  String name, {
  required int headerEnd,
  int maxBytes = maxGenericDataBytes,
}) {
  try {
    final fb = LitertlmFlatBuffer(header);
    // LiteRTLMMetaData.section_metadata = 1; SectionMetadata.objects = 0.
    final sectionMetadata = fb.table(fb.root(), 1);
    if (sectionMetadata == null) return null;
    final objects = fb.vector(sectionMetadata, 0);
    if (objects == null) return null;
    (int, int)? found;
    for (var i = 0; i < fb.length(objects); i++) {
      final section = fb.element(objects, i);
      // SectionObject: items = 0, begin_offset = 1, end_offset = 2,
      // data_type = 3.
      if (!_named(fb, section, name)) continue;
      final type = fb.uint8(section, 3);
      if (type != _genericBinaryData) {
        throw FormatException(
          'the $name section has data type $type, not '
          'GenericBinaryData ($_genericBinaryData)',
        );
      }
      if (found != null) {
        throw FormatException(
          'the .litertlm file carries the $name section twice',
        );
      }
      final begin = fb.uint64(section, 1);
      final end = fb.uint64(section, 2);
      // A uint64 at or above 2^63 reads as negative.
      if (begin < headerEnd || end < begin || end - begin > maxBytes) {
        throw FormatException('the $name section $begin..$end is invalid');
      }
      found = (begin, end);
    }
    return found;
  } on RangeError {
    throw const FormatException('.litertlm header flatbuffer is truncated');
  }
}

bool _named(LitertlmFlatBuffer fb, int section, String name) {
  final items = fb.vector(section, 0);
  if (items == null) return false;
  for (var j = 0; j < fb.length(items); j++) {
    final item = fb.element(items, j);
    // KeyValuePair: key = 0; the union `value` takes two slots, value_type = 1
    // and value = 2. StringValue.value = 0.
    if (fb.string(item, 0) != 'name') continue;
    final valueType = fb.uint8(item, 1);
    final value = fb.table(item, 2);
    if (valueType != _stringValue) {
      // Only a GenericBinaryData section can be the one asked for; elsewhere a `name`
      // item of another kind is someone else's.
      if (fb.uint8(section, 3) == _genericBinaryData) {
        throw FormatException(
          'a GenericBinaryData section has a name item of value type '
          '$valueType, not a string; it may be a $name section this release '
          'cannot read',
        );
      }
      continue;
    }
    if (value != null && fb.string(value, 0) == name) return true;
  }
  return false;
}

Future<Uint8List> _readExactly(
  RandomAccessFile file,
  int position,
  int length,
) async {
  await file.setPosition(position);
  final bytes = await file.read(length);
  if (bytes.length != length) {
    throw FormatException(
      '.litertlm file ends at ${position + bytes.length}, '
      'expected ${position + length}',
    );
  }
  return bytes;
}
