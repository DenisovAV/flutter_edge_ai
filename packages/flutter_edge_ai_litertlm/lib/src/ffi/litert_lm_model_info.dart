import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/core/sampling.dart';

typedef _CreateNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _VoidOfFileNative = Void Function(Pointer<Void>);
typedef _VoidOfFile = void Function(Pointer<Void>);
typedef _IntOfFileNative = Int32 Function(Pointer<Void>);
typedef _IntOfFile = int Function(Pointer<Void>);
typedef _FloatOfFileNative = Float Function(Pointer<Void>);
typedef _FloatOfFile = double Function(Pointer<Void>);

/// `kLiteRtLmSamplerTypeUnspecified`: the bundle ships no sampler.
const _samplerTypeUnspecified = 0;

/// `kLiteRtLmSamplerTypeTopK`.
const _samplerTypeTopK = 1;

/// `kLiteRtLmSamplerTypeGreedy`.
const _samplerTypeGreedy = 3;

/// The sampler a `.litertlm` bundle ships (`LlmMetadata.sampler_params`),
/// read through LiteRT-LM's `c/model_info.h`.
///
/// Written by hand because the generated bindings cover `engine.h` only.
/// Empty when the bundle has no sampler. The C API has no getter for the
/// seed, and it returns zero for a field the bundle leaves out, so a zero
/// `top_k`, `top_p` or temperature counts as unset.
SamplingParams readBundleSampler(DynamicLibrary lib, String modelPath) {
  final create = lib.lookupFunction<_CreateNative, _CreateNative>(
    'litert_lm_loaded_file_create',
  );
  final delete = lib.lookupFunction<_VoidOfFileNative, _VoidOfFile>(
    'litert_lm_loaded_file_delete',
  );
  final type = lib.lookupFunction<_IntOfFileNative, _IntOfFile>(
    'litert_lm_loaded_file_sampler_type',
  );
  final temperature = lib.lookupFunction<_FloatOfFileNative, _FloatOfFile>(
    'litert_lm_loaded_file_sampler_temperature',
  );
  final topK = lib.lookupFunction<_IntOfFileNative, _IntOfFile>(
    'litert_lm_loaded_file_sampler_top_k',
  );
  final topP = lib.lookupFunction<_FloatOfFileNative, _FloatOfFile>(
    'litert_lm_loaded_file_sampler_top_p',
  );

  final path = modelPath.toNativeUtf8();
  final file = create(path);
  calloc.free(path);
  if (file == nullptr) {
    throw StateError(
      'litert_lm_loaded_file_create could not read model info from '
      '$modelPath',
    );
  }
  try {
    return bundleSamplerFrom(
      type: type(file),
      temperature: temperature(file),
      topK: topK(file),
      topP: topP(file),
    );
  } finally {
    delete(file);
  }
}

/// The outcome of reading a bundle's sampler: [sampler], empty when the bundle
/// ships none, or the [error] that stopped the read. Plain data, so it crosses
/// the isolate the read runs in.
final class BundleSamplerRead {
  const BundleSamplerRead(this.sampler) : error = null;

  const BundleSamplerRead.failed(String this.error)
    : sampler = const SamplingParams();

  const BundleSamplerRead.notRead()
    : sampler = const SamplingParams(),
      error = null;

  final SamplingParams sampler;

  /// Why the read failed, with its type and stack; null when it worked.
  final String? error;
}

/// [readBundleSampler], with any failure returned instead of thrown.
BundleSamplerRead tryReadBundleSampler(DynamicLibrary lib, String modelPath) {
  try {
    return BundleSamplerRead(readBundleSampler(lib, modelPath));
  } on Object catch (e, st) {
    return BundleSamplerRead.failed('${e.runtimeType}: $e\n$st');
  }
}

/// The values the C getters returned, as [SamplingParams].
///
/// The engine is always sent a TOP_P sampler, because LiteRT-LM's CPU sampler
/// rejects the other types, so the other types are written as TOP_P: a greedy
/// bundle becomes `topK: 1`, and a TOP_K bundle gets `topP: 1.0` so no
/// nucleus cut is added to it.
SamplingParams bundleSamplerFrom({
  required int type,
  required double temperature,
  required int topK,
  required double topP,
}) {
  if (type == _samplerTypeUnspecified) return const SamplingParams();
  if (type == _samplerTypeGreedy) return const SamplingParams(topK: 1);
  return SamplingParams(
    temperature: temperature > 0 ? temperature : null,
    topK: topK > 0 ? topK : null,
    topP: type == _samplerTypeTopK ? 1.0 : (topP > 0 ? topP : null),
  );
}
