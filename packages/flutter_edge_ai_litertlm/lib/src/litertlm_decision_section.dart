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
    final range = litetuneDecisionRange(header, headerEnd: headerEnd);
    if (range == null) return null;
    final (begin, end) = range;
    return utf8.decode(await _readExactly(file, begin, end - begin));
  } finally {
    await file.close();
  }
}

/// The `[begin, end)` byte range of the `litetune.decision` section, from the
/// header flatbuffer that follows the 32-byte preamble (the file's header
/// ends at [headerEnd]), or null when the bundle has none. A section that
/// carries the name in another form — on a section of another data type, or
/// as a value that is not a string — is a [FormatException], not "none": it
/// is a decision this release cannot read, not a chat model.
(int, int)? litetuneDecisionRange(Uint8List header, {required int headerEnd}) {
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
      if (!_named(fb, section, litetuneDecisionSectionName)) continue;
      final type = fb.uint8(section, 3);
      if (type != _genericBinaryData) {
        throw FormatException(
          'the litetune.decision section has data type $type, not '
          'GenericBinaryData ($_genericBinaryData)',
        );
      }
      if (found != null) {
        throw const FormatException(
          'the .litertlm file carries the litetune.decision section twice',
        );
      }
      final begin = fb.uint64(section, 1);
      final end = fb.uint64(section, 2);
      // A uint64 at or above 2^63 reads as negative.
      if (begin < headerEnd || end < begin || end - begin > _maxDecisionBytes) {
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
    final valueType = fb.uint8(item, 1);
    final value = fb.table(item, 2);
    if (valueType != _stringValue) {
      // Only a GenericBinaryData section can be litetune's; elsewhere a `name`
      // item of another kind is someone else's.
      if (fb.uint8(section, 3) == _genericBinaryData) {
        throw FormatException(
          'a GenericBinaryData section has a name item of value type '
          '$valueType, not a string; it may be a litetune.decision section '
          'this release cannot read',
        );
      }
      continue;
    }
    if (value != null && fb.string(value, 0) == name) return true;
  }
  return false;
}

/// What reading a model file's decision gave, captured when the model is
/// loaded, so that a decider reads the file the engine loaded: the payload,
/// or null when the file has none, or why it could not be read.
final class LitetuneDecisionRead {
  const LitetuneDecisionRead._(this.payload, this.error);

  final String? payload;

  /// Why the file's decision could not be read; then [payload] is null.
  final FormatException? error;

  /// Reads [modelPath]'s decision. An I/O failure is captured as a
  /// [FormatException] too: the decision is the file's, unreadable either way.
  static Future<LitetuneDecisionRead> read(String modelPath) async {
    try {
      return LitetuneDecisionRead._(
        await readLitetuneDecisionSection(modelPath),
        null,
      );
    } on FormatException catch (e) {
      return LitetuneDecisionRead._(null, e);
    } on FileSystemException catch (e) {
      return LitetuneDecisionRead._(
        null,
        FormatException('the model file could not be read: $e'),
      );
    }
  }
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
