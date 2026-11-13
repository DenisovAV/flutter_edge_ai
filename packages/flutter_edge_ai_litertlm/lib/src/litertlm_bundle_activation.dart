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
// token context, where its FP16 rotary positions break (#827): see
// `gpuActivationDefault`.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';

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
/// GPU attempt runs at FP32 (#827).
const gemma4Fp16MaxContextTokens = 2048;

/// Why [gpuActivationDefault] chose FP32 for a GPU attempt, for the engine's
/// log line.
enum GpuActivationReason {
  /// A FunctionGemma bundle that declares no `prefer_activation_type`.
  functionGemmaWithoutKey,

  /// Gemma 4 with a context above [gemma4Fp16MaxContextTokens].
  gemma4LongContext,
}

/// The activation type a GPU attempt gets when the caller set none, or null to
/// leave the engine's choice alone, with the reason it was chosen.
///
/// FP32 is worth its cost where FP16 is broken, and two cases are where it is:
///
/// - FunctionGemma without the key: in litetune, on a Galaxy S24, a fine-tune
///   without it flooded `<pad>` on 14 of 20 prompts at FP16 and on none at
///   FP32, at 1.4 s a prompt against 2.5 s on its CPU.
/// - Gemma 4 with [maxTokens] above [gemma4Fp16MaxContextTokens] (#827), even
///   though its bundles declare `prefer_activation_type: fp16`. In FP16 the
///   exported graph's rotary positions stop being distinct past about 2,048
///   tokens and step by 4 past 4,096 (LiteRT-LM #3913, #4001; litert-torch
///   #1343), so a long prompt degrades on every GPU backend. On Windows,
///   Intel Panther Lake (D3D12), Gemma 4 E2B with a ~4,875-token agent prompt
///   made 0 tool calls at FP16 and 13 at FP32, at 46 against 50 tok/s decode
///   and a first token after 1.5 against 3.8 s. On an M5 Pro (Metal) the same
///   model recalled 0 of 6 dates from a 4,862-token prompt at FP16 and 5 of 6
///   at FP32 (first token 0.62 against 1.08 s, decode 118 against 108 tok/s,
///   peak footprint 1.24 against 1.88 GB); from a 1,768-token prompt it
///   recalled all at both, from a 2,541-token one none at FP16. The context,
///   not the prompt, decides, because the prompt is not known at load: a
///   conversation fills the window turn by turn.
///
/// Gemma 3 1B answers correctly at the GPU default and is left alone, as is
/// Gemma 4 with a context of 2,048 tokens or less. Every Gemma 3 270M bundle
/// floods `<pad>` on the GPU as well (LiteRT-LM#3280) but is NOT covered here:
/// it is `ModelType.gemmaIt`, the type of the larger Gemma 3 bundles, where
/// FP32 costs prefill time (about 3x on a ~3,100-token prompt, #520), so it
/// needs `activationDataType: ActivationDataType.float32` passed explicitly.
///
/// - [requested] set: it is the caller's, returned as is (reason null),
///   float16 included.
/// - [preferredBackend] cpu: the CPU executor does not read the type, so
///   nothing is chosen. A null backend is the default order (GPU first), and
///   an NPU request falls back through the GPU, so both can reach it; the
///   engine hands the result to GPU attempts only (`encoderInitArgs`), never
///   to the NPU attempt itself.
/// - FunctionGemma: [declaresKey] true leaves the bundle's own precision
///   alone; null (the header could not be read) is not guessed about.
/// - Gemma 4: [declaresKey] is not consulted.
({ActivationDataType? type, GpuActivationReason? reason}) gpuActivationDefault({
  required ActivationDataType? requested,
  required PreferredBackend? preferredBackend,
  required ModelType modelType,
  required bool? declaresKey,
  required int maxTokens,
}) {
  const none = (type: null, reason: null);
  if (requested != null) return (type: requested, reason: null);
  if (preferredBackend == PreferredBackend.cpu) return none;
  return switch (modelType) {
    ModelType.gemma4 when maxTokens > gemma4Fp16MaxContextTokens => (
      type: ActivationDataType.float32,
      reason: GpuActivationReason.gemma4LongContext,
    ),
    ModelType.functionGemma when declaresKey == false => (
      type: ActivationDataType.float32,
      reason: GpuActivationReason.functionGemmaWithoutKey,
    ),
    _ => none,
  };
}

/// Whether the bundle header can change what [gpuActivationDefault] returns,
/// so the engine reads it only then: a caller who set the type, a CPU request,
/// Gemma 4 (decided by the context alone) and every other family never reach
/// the file.
bool activationHeaderMatters({
  required ActivationDataType? requested,
  required PreferredBackend? preferredBackend,
  required ModelType modelType,
  required int maxTokens,
}) {
  ActivationDataType? withKey(bool declaresKey) => gpuActivationDefault(
    requested: requested,
    preferredBackend: preferredBackend,
    modelType: modelType,
    declaresKey: declaresKey,
    maxTokens: maxTokens,
  ).type;
  return withKey(false) != withKey(true);
}
