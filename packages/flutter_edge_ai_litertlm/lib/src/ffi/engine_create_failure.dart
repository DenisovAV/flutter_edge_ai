// The message of a failed `litert_lm_engine_create`, built from what the
// client knows when the engine pointer comes back null: the backend it asked
// for, LiteRT-LM's own last error and the activation type the attempt ran at.

import '../litertlm_bundle_activation.dart';

/// LiteRT-LM's refusal of a `*-gpu.litertlm` build: litert-community
/// publishes these for its GPU "artisan" backend (`Backend::GPU_ARTISAN`,
/// engine types `kAdvancedLegacyTfLite`/`kLegacyTfLite`), which the
/// open-source runtime registers on no native platform. On Windows it reads
/// `NOT_FOUND: No available engine for backend: GPU_ARTISAN. Preferred engine
/// types: [...]`.
final _gpuArtisanRefusal = RegExp(
  r'no\s+available\s+engine\s+for\s+backend\W*gpu_artisan\b',
  caseSensitive: false,
);

/// Whether [nativeMessage] is LiteRT-LM saying it has no engine for the GPU
/// artisan backend.
bool isGpuArtisanRefusal(String? nativeMessage) =>
    nativeMessage != null && _gpuArtisanRefusal.hasMatch(nativeMessage);

/// The message for an engine create on [backend] that failed for [modelPath].
///
/// [nativeMessage] is LiteRT-LM's last error, null when it left none.
/// [activationDataType] is the wire value the attempt sent (0 = float32), and
/// [gpuActivationReason] why the engine chose it when the caller set none
/// (null when the caller set it, or when the engine chose nothing).
String engineCreateFailureMessage({
  required String backend,
  required String modelPath,
  required String? nativeMessage,
  required int? activationDataType,
  required GpuActivationReason? gpuActivationReason,
}) {
  if (isGpuArtisanRefusal(nativeMessage)) {
    return 'This .litertlm file is a GPU-artisan build (LiteRT-LM: "no '
        'available engine for backend GPU_ARTISAN"). It needs LiteRT-LM\'s GPU '
        'artisan engine, which the open-source LiteRT-LM runtime, and so this '
        'plugin, cannot load on any native platform. Use the generic '
        '.litertlm of the same model instead (litert-community publishes it '
        'beside the "-gpu" file). Model: $modelPath';
  }
  final because = nativeMessage == null ? '' : ': $nativeMessage';
  // Only the GPU executor reads the activation type, so only a float32 GPU
  // attempt can have failed because of it.
  final float32OnGpu = activationDataType == 0 && backend == 'gpu';
  final hint = !float32OnGpu
      ? ''
      : switch (gpuActivationReason) {
          null =>
            ' (float32 activations need more GPU memory than the default; '
                'activationDataType asked for float32: try without it, and '
                'ActivationDataType.float16 asks for the default)',
          GpuActivationReason.functionGemmaWithoutKey =>
            ' (float32 activations need more GPU memory than the default; '
                'the engine chose float32 because this FunctionGemma bundle '
                'declares no prefer_activation_type, and '
                'ActivationDataType.float16 asks for the default instead)',
          GpuActivationReason.gemma4LongContext =>
            ' (float32 activations need more GPU memory than the default; '
                'the engine chose float32 because Gemma 4 with a context '
                '(maxTokens) above $gemma4Fp16MaxContextTokens tokens runs '
                'at float32 on the GPU; a maxTokens of '
                '$gemma4Fp16MaxContextTokens or less, or '
                'ActivationDataType.float16, asks for the default, where a '
                'prompt past about $gemma4Fp16MaxContextTokens tokens '
                'degrades)',
        };
  return 'Failed to create engine on $backend$because. Model: $modelPath'
      '$hint';
}
