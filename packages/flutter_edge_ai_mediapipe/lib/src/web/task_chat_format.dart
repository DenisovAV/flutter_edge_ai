// What a MediaPipe `.task` file says about its own chat format.
//
// A web `.task` is a TFLite flatbuffer whose metadata holds an
// `odml.infra.proto.LlmParameters` message. The converter that wrote Gemma 4
// puts the turn markers in it as plain strings (fields 11 to 14). That is the
// only place the markers are written down, so the session reads them from the
// file instead of keeping a table of model types.
//
// Platform-neutral: the caller hands over the first bytes of the file, however
// it read them.
import 'dart:convert';
import 'dart:typed_data';

import 'web_prompt.dart';

/// How many bytes from the start of a file [readTaskChatFormat] needs. The
/// converter writes the small metadata buffers right behind the flatbuffer's
/// tables, far ahead of the weights (Gemma 4 E2B: the first 264 KiB of 2 GB).
const taskMetadataPrefixBytes = 4 * 1024 * 1024;

/// The chat format a `.task` declares.
final class TaskChatFormat {
  const TaskChatFormat({this.template, this.hasRuntimePromptTemplates = false});

  /// The turn markers the file spells out, or null when it does not.
  final WebChatTemplate? template;

  /// Whether the file carries `prompt_templates` (field 17), the message
  /// `@mediapipe/tasks-genai` 0.10.29 itself reads.
  final bool hasRuntimePromptTemplates;

  @override
  String toString() =>
      'TaskChatFormat(template: $template, '
      'runtimePromptTemplates: $hasRuntimePromptTemplates)';
}

const _llmParametersName = 'odml.infra.proto.LlmParameters';

/// Reads the chat format from [prefix], the first bytes of a `.task` file.
///
/// Returns null when [prefix] is not a TFLite file, has no `LlmParameters`
/// entry, or ends before the entry does. A format that is not there is not an
/// error: the caller falls back to the model type.
TaskChatFormat? readTaskChatFormat(Uint8List prefix) {
  final params = _llmParameters(prefix);
  if (params == null) return null;
  final fields = _protoFields(params);
  if (fields == null) return null;

  String? string(int number) {
    final bytes = fields.bytes[number];
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  final user = string(11);
  final model = string(13);
  final suffix = string(14);
  return TaskChatFormat(
    template: user != null && model != null && suffix != null
        ? WebChatTemplate(
            userPrefix: user,
            modelPrefix: model,
            turnSuffix: suffix,
          )
        : null,
    hasRuntimePromptTemplates: fields.bytes.containsKey(17),
  );
}

/// The bytes of the `LlmParameters` metadata buffer, or null.
Uint8List? _llmParameters(Uint8List data) {
  final fb = _FlatBuffer(data);
  // A TFLite file: the root offset, then the identifier at byte 4.
  if (data.length < 8 ||
      utf8.decode(data.sublist(4, 8), allowMalformed: true) != 'TFL3') {
    return null;
  }
  final root = fb.u32(0);
  if (root == null) return null;
  // Model: 4 buffers, 6 metadata.
  final metadata = fb.vector(root, 6);
  final buffers = fb.vector(root, 4);
  if (metadata == null || buffers == null) return null;
  for (var i = 0; i < metadata.length; i++) {
    final entry = fb.tableAt(metadata.element(i));
    if (entry == null) return null;
    final name = fb.string(entry, 0);
    if (name != _llmParametersName) continue;
    final index = fb.scalar32(entry, 1);
    if (index == null || index >= buffers.length) return null;
    final buffer = fb.tableAt(buffers.element(index));
    if (buffer == null) return null;
    // Buffer: 0 data, 1 offset, 2 size. Large files keep the bytes behind an
    // offset and a size instead of inline.
    final inline = fb.vector(buffer, 0);
    if (inline != null) return fb.bytes(inline.start, inline.length);
    final offset = fb.scalar64(buffer, 1);
    final size = fb.scalar64(buffer, 2);
    if (offset == null || size == null) return null;
    return fb.bytes(offset, size);
  }
  return null;
}

class _Vec {
  _Vec(this.start, this.length);

  /// Where the elements begin.
  final int start;
  final int length;

  /// The position of element [i] of a vector of 4-byte offsets.
  int element(int i) => start + 4 * i;
}

/// The little a TFLite file needs from FlatBuffers: tables, vectors, strings.
/// Every read is bounds-checked and answers null when the bytes are not in
/// [data].
class _FlatBuffer {
  _FlatBuffer(this.data) : _view = ByteData.sublistView(data);

  final Uint8List data;
  final ByteData _view;

  bool _has(int offset, int length) =>
      offset >= 0 && length >= 0 && offset + length <= data.length;

  int? u16(int offset) =>
      _has(offset, 2) ? _view.getUint16(offset, Endian.little) : null;
  int? u32(int offset) =>
      _has(offset, 4) ? _view.getUint32(offset, Endian.little) : null;
  int? i32(int offset) =>
      _has(offset, 4) ? _view.getInt32(offset, Endian.little) : null;

  /// The table that the offset stored at [position] points to.
  int? tableAt(int position) {
    final rel = u32(position);
    return rel == null ? null : position + rel;
  }

  /// Where field [index] of [table] is stored, or null when the table has no
  /// such field.
  int? field(int table, int index) {
    final back = i32(table);
    if (back == null) return null;
    final vtable = table - back;
    final vtableSize = u16(vtable);
    final slot = 4 + 2 * index;
    if (vtableSize == null || slot + 2 > vtableSize) return null;
    final rel = u16(vtable + slot);
    return rel == null || rel == 0 ? null : table + rel;
  }

  _Vec? vector(int table, int index) {
    final at = field(table, index);
    if (at == null) return null;
    final rel = u32(at);
    if (rel == null) return null;
    final start = at + rel;
    final length = u32(start);
    return length == null ? null : _Vec(start + 4, length);
  }

  String? string(int table, int index) {
    final v = vector(table, index);
    if (v == null || !_has(v.start, v.length)) return null;
    return utf8.decode(
      data.sublist(v.start, v.start + v.length),
      allowMalformed: true,
    );
  }

  int? scalar32(int table, int index) {
    final at = field(table, index);
    return at == null ? null : u32(at);
  }

  /// A uint64 as two uint32 halves: dart2js has no 64-bit accessor, and a
  /// file offset stays below 2^53.
  int? scalar64(int table, int index) {
    final at = field(table, index);
    if (at == null) return null;
    final low = u32(at);
    final high = u32(at + 4);
    return low == null || high == null ? null : low + high * 4294967296;
  }

  Uint8List? bytes(int start, int length) => _has(start, length)
      ? Uint8List.sublistView(data, start, start + length)
      : null;
}

class _ProtoFields {
  _ProtoFields(this.bytes);

  /// The last length-delimited value of each field number.
  final Map<int, Uint8List> bytes;
}

/// The length-delimited fields of a protobuf message, or null when it does not
/// parse. Other wire types are skipped.
_ProtoFields? _protoFields(Uint8List message) {
  final out = <int, Uint8List>{};
  var i = 0;
  int? varint() {
    // Arithmetic, not shifts: a JS bit operation is 32 bits wide.
    var result = 0;
    var scale = 1;
    for (var n = 0; n < 8 && i < message.length; n++) {
      final b = message[i++];
      result += (b & 0x7f) * scale;
      if (b & 0x80 == 0) return result;
      scale *= 128;
    }
    return null;
  }

  while (i < message.length) {
    final key = varint();
    if (key == null) return null;
    final number = key >> 3;
    switch (key & 7) {
      case 0:
        if (varint() == null) return null;
      case 1:
        i += 8;
      case 2:
        final length = varint();
        if (length == null || i + length > message.length) return null;
        out[number] = Uint8List.sublistView(message, i, i + length);
        i += length;
      case 5:
        i += 4;
      default:
        return null;
    }
    if (i > message.length) return null;
  }
  return _ProtoFields(out);
}
