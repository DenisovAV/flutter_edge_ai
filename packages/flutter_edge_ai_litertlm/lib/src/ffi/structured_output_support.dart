import 'package:flutter_edge_ai/engine.dart';

import '../npu_stacks.dart';
import 'open_session_backing.dart';

/// One native LiteRT-LM host/backend row whose constrained decoding needs its
/// own discriminating run before it can be advertised.
typedef LiteRtLmStructuredOutputRow = ({
  String abi,
  PreferredBackend backend,
  AndroidGpuFamily? androidGpu,
  NpuStack? npuVendor,
});

/// Rows that passed the discriminating structured-output integration suite.
///
/// Enabling another host is deliberately a one-line addition after its run.
const liteRtLmStructuredOutputRows = <LiteRtLmStructuredOutputRow>{
  (
    abi: 'macos_arm64',
    backend: PreferredBackend.cpu,
    androidGpu: null,
    npuVendor: null,
  ),
  (
    abi: 'macos_arm64',
    backend: PreferredBackend.gpu,
    androidGpu: null,
    npuVendor: null,
  ),
  // 2026-11-06: suite +7/-0 on Intel LNL and PTL, 33.5/36.6 constrained tok/s.
  (
    abi: 'windows_x64',
    backend: PreferredBackend.cpu,
    androidGpu: null,
    npuVendor: null,
  ),
};

/// Every row that may be qualified in the 2.6.0 device campaign.
final liteRtLmStructuredOutputCandidateRows = <LiteRtLmStructuredOutputRow>{
  for (final abi in [
    'macos_arm64',
    'linux_x64',
    'linux_arm64',
    'windows_x64',
    'android_arm64',
    'ios_arm64',
  ])
    (
      abi: abi,
      backend: PreferredBackend.cpu,
      androidGpu: null,
      npuVendor: null,
    ),
  for (final abi in [
    'macos_arm64',
    'linux_x64',
    'linux_arm64',
    'windows_x64',
    'ios_arm64',
  ])
    (
      abi: abi,
      backend: PreferredBackend.gpu,
      androidGpu: null,
      npuVendor: null,
    ),
  for (final gpu in [AndroidGpuFamily.adreno, AndroidGpuFamily.mali])
    (
      abi: 'android_arm64',
      backend: PreferredBackend.gpu,
      androidGpu: gpu,
      npuVendor: null,
    ),
  for (final vendor in NpuStack.values)
    for (final abi in vendor.abis)
      (
        abi: abi,
        backend: PreferredBackend.npu,
        androidGpu: null,
        npuVendor: vendor,
      ),
};

LiteRtLmStructuredOutputRow liteRtLmStructuredOutputRow({
  required String abi,
  required PreferredBackend backend,
  AndroidGpuFamily? androidGpu,
  NpuStack? npuVendor,
}) => (
  abi: abi,
  backend: backend,
  androidGpu: backend == PreferredBackend.gpu && abi == 'android_arm64'
      ? androidGpu
      : null,
  npuVendor: backend == PreferredBackend.npu ? npuVendor : null,
);

/// The whole core dialect where LLGuidance passed for this exact row; a
/// precise refusal everywhere else, including web (reported by its model).
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
  final row = liteRtLmStructuredOutputRow(
    abi: abi,
    backend: backend,
    androidGpu: androidGpu,
    npuVendor: npuVendor,
  );
  if (liteRtLmStructuredOutputRows.contains(row)) {
    return const StructuredOutputSupport(keywords: ResponseFormat.dialect);
  }
  final detail = switch (backend) {
    PreferredBackend.cpu => '$abi CPU',
    PreferredBackend.gpu when abi == 'android_arm64' =>
      '$abi GPU (${androidGpu?.name ?? 'unknown family'})',
    PreferredBackend.gpu => '$abi GPU',
    PreferredBackend.npu =>
      '$abi NPU (${npuVendor?.label ?? 'unknown vendor'})',
  };
  return StructuredOutputSupport.none(
    'LiteRT-LM constrained decoding is refused on $detail until that row '
    'passes the discriminating device run.',
  );
}
