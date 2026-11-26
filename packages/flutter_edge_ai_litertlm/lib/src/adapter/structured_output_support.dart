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

/// Why LiteRT-LM cannot apply a per-message tool choice on this row, or null
/// where it can: litertlm_dart refuses a tool choice wherever it refuses
/// constrained decoding ([liteRtLmConstrainedDecodingRefusal]), before
/// anything is sent.
String? liteRtLmToolChoiceRefusal({
  required String abi,
  required PreferredBackend? backend,
  AndroidGpuFamily? androidGpu,
  NpuStack? npuVendor,
}) => backend == null
    ? 'LiteRT-LM did not report the backend that loaded this model.'
    : liteRtLmConstrainedDecodingRefusal(
        abi: abi,
        backend: backend.toRuntime,
        androidGpu: androidGpu,
        npuVendor: npuVendor,
      );
