// The GPU activation type the LLM engine picks when the caller set none: a
// policy by core's ModelType, over what the runtime reads from the bundle
// (bundle/litertlm_bundle_activation.dart).

import 'package:flutter_edge_ai/engine.dart';

import 'package:litertlm_dart/litertlm_dart.dart';

/// The activation type a GPU attempt gets when the caller set none, or null to
/// leave the engine's choice alone, with the reason it was chosen.
///
/// FP32 is worth its cost where FP16 is broken, and two cases are where it is:
///
/// - FunctionGemma without the key: in litetune, on a Galaxy S24, a fine-tune
///   without it flooded `<pad>` on 14 of 20 prompts at FP16 and on none at
///   FP32, at 1.4 s a prompt against 2.5 s on its CPU.
/// - Gemma 4 with [maxTokens] above [gemma4Fp16MaxContextTokens] (LiteRT-LM #4001), even
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
