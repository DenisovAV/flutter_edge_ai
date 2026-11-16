// Whether a `.litertlm` bundle says which activation precision its GPU graphs
// want, and the default the engine picks when it says nothing.
//
// A TFLiteModel section carries an item `prefer_activation_type` (value
// `fp32_fp16`, `fp32`, …) when its converter set it; litetune does since
// 0.1.4, and the Gemma 4 bundles have it. A FunctionGemma bundle converted
// before that has none, and on GPU it then runs at FP16 and answers every
// prompt with `<pad>` to the token limit, with no error (LiteRT-LM#3280).
//
// Read from the container header, a few hundred bytes to a few KB, the same
// way as the sampler: LiteRT-LM's own loader would copy sections into the heap.
//
// Gemma 4 declares the key, and is still given FP32 on the GPU above a 2,048
// token context, where its FP16 rotary positions break (LiteRT-LM #4001): see
// `gpuActivationFor` (lib/src/api/engine.dart).

import 'dart:io';
import 'dart:typed_data';

import 'litertlm_flatbuffer.dart';

/// `AnySectionDataType.TFLiteModel`.
const _tfliteModel = 3;

/// The item key a converter sets to say which activation type the graph wants.
const _preferActivationType = 'prefer_activation_type';

/// Whether any `TFLiteModel` section in [header] declares
/// `prefer_activation_type`: the `LiteRTLMMetaData` flatbuffer that follows
/// the 32-byte preamble.
///
/// Any section counts: a bundle that states the type anywhere (the Gemma 4
/// bundles do, on the prefill/decode and the vision graphs) was built by a
/// converter that knows about it, and the engine leaves its choice alone.
///
/// Throws [FormatException] when the header is truncated or has no section
/// table.
bool litertlmDeclaresActivationType(Uint8List header) {
  try {
    final fb = LitertlmFlatBuffer(header);
    // LiteRTLMMetaData.section_metadata = 1; SectionMetadata.objects = 0.
    final sectionMetadata = fb.table(fb.root(), 1);
    final objects = sectionMetadata == null
        ? null
        : fb.vector(sectionMetadata, 0);
    if (objects == null) {
      throw const FormatException('.litertlm header has no section table');
    }
    for (var i = 0; i < fb.length(objects); i++) {
      final section = fb.element(objects, i);
      // SectionObject: items = 0, begin_offset = 1, end_offset = 2,
      // data_type = 3.
      if (fb.uint8(section, 3) != _tfliteModel) continue;
      final items = fb.vector(section, 0);
      if (items == null) continue;
      for (var j = 0; j < fb.length(items); j++) {
        // KeyValuePair: key = 0.
        if (fb.string(fb.element(items, j), 0) == _preferActivationType) {
          return true;
        }
      }
    }
    return false;
  } on RangeError {
    throw const FormatException('.litertlm header flatbuffer is truncated');
  }
}

/// What reading a bundle's header gave: [declaresKey] (null when it could not
/// be read, with the reason in [error]).
typedef BundleActivationRead = ({bool? declaresKey, String? error});

/// [litertlmDeclaresActivationType] for the file at [modelPath], with a file it
/// cannot read or parse returned as [BundleActivationRead.error] instead of
/// thrown, as `tryReadBundleSampler` does: the engine's own load reports a
/// real failure, and what this decides is only a default. A caller must say
/// that the answer is unknown, because the model then runs at the GPU default.
Future<BundleActivationRead> tryReadBundleActivationDeclaration(
  String modelPath,
) async {
  try {
    final file = await File(modelPath).open();
    try {
      final headerEnd = litertlmHeaderEnd(await _readExactly(file, 0, 32));
      return (
        declaresKey: litertlmDeclaresActivationType(
          await _readExactly(file, 32, headerEnd - 32),
        ),
        error: null,
      );
    } finally {
      await file.close();
    }
  } on FileSystemException catch (e) {
    return (declaresKey: null, error: 'FileSystemException: ${e.message}');
  } on FormatException catch (e) {
    return (declaresKey: null, error: 'FormatException: ${e.message}');
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

/// The largest context Gemma 4 keeps at the GPU's FP16 default: above it a
/// GPU attempt runs at FP32 (LiteRT-LM #4001).
const gemma4Fp16MaxContextTokens = 2048;

/// Why `gpuActivationFor` (`Engine.create`) chose FP32 for a GPU load, for the engine's
/// log line.
enum GpuActivationReason {
  /// A FunctionGemma bundle that declares no `prefer_activation_type`.
  functionGemmaWithoutKey,

  /// Gemma 4 with a context above [gemma4Fp16MaxContextTokens].
  gemma4LongContext,
}
