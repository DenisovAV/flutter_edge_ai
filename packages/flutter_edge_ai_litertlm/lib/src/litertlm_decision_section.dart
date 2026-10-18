import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'litertlm_flatbuffer.dart';

/// The `name` item of the section litetune's `bundle` writes the decision a
/// model was trained on into (`decision_section.SECTION_NAME`).
const litetuneDecisionSectionName = 'litetune.decision';

/// `AnySectionDataType.GenericBinaryData` in `litertlm_header_schema.fbs`.
const _genericBinaryData = 1;

/// `VData.StringValue`: the union discriminator (NONE is 0).
const _stringValue = 9;

/// Far larger than any decision payload (151 options with descriptions are a
/// few KB); a bigger range is a corrupt file, not one to read into memory.
const _maxDecisionBytes = 4 << 20;

/// The decision a `.litertlm` model file was trained on: the UTF-8 JSON
/// payload of its `litetune.decision` section, or null when it has none. Reads
/// the container header and that one section, nothing else.
///
/// The section is a `GenericBinaryData` section whose `name` item is
/// `litetune.decision`, as litetune 0.5.0's `bundle` writes it; LiteRT-LM never
/// maps such a section, so it costs the model nothing. Throws
/// [FormatException] for a file that is not a `.litertlm` container this
/// reader understands, a section range outside it, more than one decision
/// section, and a payload that is not UTF-8.
Future<String?> readLitetuneDecisionSection(String modelPath) async {
  final file = await File(modelPath).open();
  try {
    final headerEnd = litertlmHeaderEnd(await _readExactly(file, 0, 32));
    final header = await _readExactly(file, 32, headerEnd - 32);
    final range = litetuneDecisionRange(header);
    if (range == null) return null;
    final (begin, end) = range;
    return utf8.decode(await _readExactly(file, begin, end - begin));
  } finally {
    await file.close();
  }
}

/// The `[begin, end)` byte range of the `litetune.decision` section, from the
/// header flatbuffer that follows the 32-byte preamble, or null when the
/// bundle has none.
(int, int)? litetuneDecisionRange(Uint8List header) {
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
      if (fb.uint8(section, 3) != _genericBinaryData) continue;
      if (!_named(fb, section, litetuneDecisionSectionName)) continue;
      if (found != null) {
        throw const FormatException(
          'the .litertlm file carries the litetune.decision section twice',
        );
      }
      final begin = fb.uint64(section, 1);
      final end = fb.uint64(section, 2);
      if (end < begin || end - begin > _maxDecisionBytes) {
        throw FormatException(
          'the litetune.decision section $begin..$end is invalid',
        );
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
    if (fb.uint8(item, 1) != _stringValue) continue;
    final value = fb.table(item, 2);
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
