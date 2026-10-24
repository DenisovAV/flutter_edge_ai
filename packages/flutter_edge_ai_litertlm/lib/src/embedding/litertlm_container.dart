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
// Web-safe: the parsing is pure Dart over the header bytes, and the bytes come
// from whoever can read the file — `litertlm_container_io.dart` natively
// (synchronous on purpose: the pass reads it inside core's embedding worker,
// where blocking costs no frame), the page's `fetch()` on the web
// ([readLitertlmModelTypesFrom]).

import 'dart:typed_data';

import '../litertlm_flatbuffer.dart';

/// `AnySectionDataType.TFLiteModel`.
const _tfliteModel = 3;

/// `VData.StringValue`: the union discriminator (NONE is 0).
const _stringValue = 9;

/// The `model_type` that marks an audio encoder section, as a prefix.
const _audioEncoderPrefix = 'tf_lite_audio_encoder';

/// The `model_type` of every `TFLiteModel` section of a `.litertlm` file,
/// lowercased, in file order, from [prefix] — a reader of the file's first
/// `length` bytes (fewer when the file is shorter). It is asked for the
/// 32-byte preamble, then for everything up to the header end.
///
/// Throws [FormatException] when the file is not a `.litertlm` container this
/// reader understands, or ends inside its header; whatever [prefix] throws
/// passes through.
Future<List<String>> readLitertlmModelTypesFrom(
  Future<Uint8List> Function(int length) prefix,
) async {
  final preamble = await prefix(32);
  if (preamble.length < 32) {
    throw FormatException(
      '.litertlm file ends at ${preamble.length}, expected 32',
    );
  }
  final headerEnd = litertlmHeaderEnd(preamble);
  final head = await prefix(headerEnd);
  if (head.length < headerEnd) {
    throw FormatException(
      '.litertlm file ends at ${head.length}, expected $headerEnd',
    );
  }
  return litertlmModelTypes(Uint8List.sublistView(head, 32, headerEnd));
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
    // LitertlmFlatBuffer checks every offset itself, so this is a Dart
    // RangeError on every compiler (dart2js and dart2wasm included).
    throw const FormatException('.litertlm header flatbuffer is truncated');
  }
}

/// Whether a bundle whose `TFLiteModel` sections have [modelTypes] carries an
/// audio encoder.
bool litertlmHasAudioEncoder(Iterable<String> modelTypes) =>
    modelTypes.any((type) => type.startsWith(_audioEncoderPrefix));
