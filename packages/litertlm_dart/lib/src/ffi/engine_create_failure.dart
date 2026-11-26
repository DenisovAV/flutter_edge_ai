// The message of a failed `litert_lm_engine_create`, built from what the
// client knows when the engine pointer comes back null: the backend it asked
// for, LiteRT-LM's own last error and the activation type the attempt ran at.

import '../bundle/litertlm_bundle_activation.dart';

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
        'plugin, cannot load on any native platform. Use a .litertlm built '
        'for the CPU/GPU CompiledModel backends instead: for the '
        'litert-community "-gpu" files, that is the generic file beside them. '
        'Model: $modelPath';
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
          // Float16: no float32 attempt to blame.
          GpuActivationReason.gemma4LongContextAndroid => '',
        };
  return 'Failed to create engine on $backend$because. Model: $modelPath'
      '$hint';
}

/// A turn that failed inside the compiled model: LiteRT-LM's `INTERNAL`
/// status, which leads its error text ("INTERNAL: … Failed to invoke the
/// compiled model"). Another status is not this failure, whatever it says.
final _compiledModelFailure = RegExp(r'^\s*INTERNAL\b');

/// The message of a streamed turn that failed with [nativeError].
///
/// On a GPU engine loaded at float32 ([activationDataType] 0), a failure
/// inside the compiled model is named as possibly the float32 activations'
/// (Adreno 8xx fails at the first token with "Invalid work group size",
/// LiteRT-LM #4825), with how to load at float16 or on the CPU.
/// [gpuActivationReason] is why the engine chose float32, null when the caller
/// asked for it. On [android], such a failure at any other activation type is
/// named as LiteRT's GPU kernels exceeding the work-group limits of some
/// Adreno GPUs (Adreno 610 at float16, LiteRT #12075), with the CPU as the
/// way out.
String streamFailureMessage({
  required String nativeError,
  required String? backend,
  required int? activationDataType,
  required GpuActivationReason? gpuActivationReason,
  required bool android,
}) {
  final message = 'Stream error: $nativeError';
  if (backend != 'gpu' || !_compiledModelFailure.hasMatch(nativeError)) {
    return message;
  }
  const cpu = 'on the CPU (Backend.cpu())';
  if (activationDataType != 0) {
    if (!android) return message;
    return '$message (the GPU turn failed inside LiteRT. A known cause on '
        "some Adreno GPUs: LiteRT's GPU kernels exceed the device's "
        'work-group limits with this native build, "Invalid work group size" '
        'in the native log (Adreno 610, LiteRT #12075), which a future native '
        'build is expected to fix. Load $cpu)';
  }
  final why = switch (gpuActivationReason) {
    // Never float32; named like a caller's.
    null || GpuActivationReason.gemma4LongContextAndroid =>
      'activationDataType asked for float32. Load without it, or with '
          'ActivationDataType.float16, or $cpu',
    GpuActivationReason.functionGemmaWithoutKey =>
      'the engine chose float32 because this FunctionGemma bundle declares no '
          'prefer_activation_type, and at float16 such a bundle answers with '
          'nothing. Load it $cpu',
    GpuActivationReason.gemma4LongContext =>
      'the engine chose float32 because Gemma 4 with a context (maxTokens) '
          'above $gemma4Fp16MaxContextTokens tokens runs at float32 on the '
          'GPU. Load with a maxTokens of $gemma4Fp16MaxContextTokens or less, '
          'or with ActivationDataType.float16, where a prompt past about '
          '$gemma4Fp16MaxContextTokens tokens degrades, or $cpu',
  };
  return '$message (this engine runs float32 activations on the GPU, which '
      'fail inside the compiled model on some GPUs: Adreno 8xx fails at the '
      'first token with "Invalid work group size" (LiteRT-LM #4825); '
      '$why)';
}
