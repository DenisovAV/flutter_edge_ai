import 'package:flutter_edge_ai/engine.dart';

import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;

import 'runtime_mapping.dart';

/// The whole core dialect where LLGuidance passed for this exact row
/// ([liteRtLmConstrainedDecodingRows], litertlm_dart's table, which its
/// Engine enforces too); a precise refusal everywhere else, including web
/// (reported by its model).
StructuredOutputSupport liteRtLmStructuredOutputSupport({
  required String abi,
  required PreferredBackend? backend,
  AndroidGpuFamily? androidGpu,
  NpuStack? npuVendor,
}) {
  if (backend == null) {
    return const StructuredOutputSupport.none(
      'LiteRT-LM did not report the backend that loaded this model, so '
      'constrained decoding is refused.',
    );
  }
  final refusal = liteRtLmConstrainedDecodingRefusal(
    abi: abi,
    backend: backend.toRuntime,
    androidGpu: androidGpu,
    npuVendor: npuVendor,
  );
  return refusal == null
      ? const StructuredOutputSupport(keywords: ResponseFormat.dialect)
      : StructuredOutputSupport.none(refusal);
}
