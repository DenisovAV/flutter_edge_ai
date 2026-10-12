// What a `.litertlm` embedding bundle carries, read from its container header
// (R5 D23, §10.4): the one capability LiteRT-LM's ModelInfo cannot be trusted
// with.
//
// `litert_lm_loaded_file_supports_input_modality` reports audio on the
// text-only 270m and on the text-vision 440m (measured), so the `.litertlm`
// pass never asks it. Audio support is read from the container instead: a
// `TFLiteModel` section whose `model_type` starts with `tf_lite_audio_encoder`
// (`tf_lite_audio_encoder_hw` in the 740m bundle, next to
// `tf_lite_audio_adapter` and `tf_lite_end_of_audio`).
//
// The layout is LiteRT-LM's `schema/core/litertlm_header_schema.fbs` (pin
// b2f686e2), the same one `litertlm_bundle_sampler.dart` walks: the 32-byte
// preamble, then a `LiteRTLMMetaData` flatbuffer whose `SectionObject`s carry
// `items` — `KeyValuePair`s whose `model_type` value is a `StringValue`. The
// header is small (880 to 2176 bytes on the three EmbeddingGemma 2 bundles);
// nothing past it is read.
//
// Synchronous on purpose: the pass reads it inside core's embedding worker,
// where blocking costs no frame.

import 'dart:io';
import 'dart:typed_data';

import '../litertlm_bundle_sampler.dart' show litertlmHeaderEnd;
import '../litertlm_flatbuffer.dart';

/// `AnySectionDataType.TFLiteModel`.
const _tfliteModel = 3;

/// `VData.StringValue`: the union discriminator (NONE is 0).
const _stringValue = 9;

/// The `model_type` that marks an audio encoder section, as a prefix.
const _audioEncoderPrefix = 'tf_lite_audio_encoder';

/// The `model_type` of every `TFLiteModel` section of [path], lowercased (as
/// LiteRT-LM compares them), in file order. A section without one is left
/// out.
///
/// Throws [FileSystemException] when the file cannot be read and
/// [FormatException] when it is not a `.litertlm` container this reader
/// understands.
List<String> readLitertlmModelTypes(String path) {
  final file = File(path).openSync();
  try {
    final headerEnd = litertlmHeaderEnd(_readExactly(file, 0, 32));
    return litertlmModelTypes(_readExactly(file, 32, headerEnd - 32));
  } finally {
    file.closeSync();
  }
}

/// The `model_type` of every `TFLiteModel` section in [header] — the
/// `LiteRTLMMetaData` flatbuffer that follows the preamble.
List<String> litertlmModelTypes(Uint8List header) {
  try {
    final fb = LitertlmFlatBuffer(header);
    // LiteRTLMMetaData.section_metadata = 1; SectionMetadata.objects = 0.
    final sectionMetadata = fb.table(fb.root(), 1);
    if (sectionMetadata == null) {
      throw const FormatException('.litertlm header has no section table');
    }
    final objects = fb.vector(sectionMetadata, 0);
    if (objects == null) {
      throw const FormatException('.litertlm header has no section table');
    }
    final types = <String>[];
    for (var i = 0; i < fb.length(objects); i++) {
      final section = fb.element(objects, i);
      // SectionObject: items = 0, begin_offset = 1, end_offset = 2,
      // data_type = 3.
      if (fb.uint8(section, 3) != _tfliteModel) continue;
      final items = fb.vector(section, 0);
      if (items == null) continue;
      for (var j = 0; j < fb.length(items); j++) {
        final item = fb.element(items, j);
        // KeyValuePair: key = 0; the union `value` takes two slots,
        // value_type = 1 and value = 2.
        if (fb.string(item, 0) != 'model_type') continue;
        if (fb.uint8(item, 1) != _stringValue) continue;
        final value = fb.table(item, 2);
        // StringValue.value = 0.
        final type = value == null ? null : fb.string(value, 0);
        if (type != null) types.add(type.toLowerCase());
      }
    }
    return types;
  } on RangeError {
    throw const FormatException('.litertlm header flatbuffer is truncated');
  }
}

/// Whether a bundle whose `TFLiteModel` sections have [modelTypes] carries an
/// audio encoder.
bool litertlmHasAudioEncoder(Iterable<String> modelTypes) =>
    modelTypes.any((type) => type.startsWith(_audioEncoderPrefix));

Uint8List _readExactly(RandomAccessFile file, int position, int length) {
  file.setPositionSync(position);
  final bytes = file.readSync(length);
  if (bytes.length != length) {
    throw FormatException(
      '.litertlm file ends at ${position + bytes.length}, '
      'expected ${position + length}',
    );
  }
  return bytes;
}
