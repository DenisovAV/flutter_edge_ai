// Where LiteRT-LM's constrained decoding (a response format: a JSON schema or
// a regex) was qualified: the host and backend rows that passed the
// discriminating device suite. Engine refuses a response format elsewhere;
// flutter_edge_ai_litertlm reports the same rows to core.

import '../ffi/open_session_backing.dart' show AndroidGpuFamily;
import 'npu_stacks.dart';
import 'types.dart' show BackendKind;

/// One native LiteRT-LM host/backend row whose constrained decoding needs its
/// own discriminating run before it can be advertised.
typedef LiteRtLmConstrainedDecodingRow = ({
  String abi,
  BackendKind backend,
  AndroidGpuFamily? androidGpu,
  NpuStack? npuVendor,
});

/// Rows that passed the discriminating structured-output integration suite.
///
/// Enabling another host is deliberately a one-line addition after its run.
const liteRtLmConstrainedDecodingRows = <LiteRtLmConstrainedDecodingRow>{
  (
    abi: 'macos_arm64',
    backend: BackendKind.cpu,
    androidGpu: null,
    npuVendor: null,
  ),
  (
    abi: 'macos_arm64',
    backend: BackendKind.gpu,
    androidGpu: null,
    npuVendor: null,
  ),
  // 2026-11-06: iPhone 17 Pro, iOS 26.5.2, CPU/Metal suites +7/-0 at
  // 4fbf6508.
  (
    abi: 'ios_arm64',
    backend: BackendKind.cpu,
    androidGpu: null,
    npuVendor: null,
  ),
  (
    abi: 'ios_arm64',
    backend: BackendKind.gpu,
    androidGpu: null,
    npuVendor: null,
  ),
  // 2026-11-06: Linux x64 CPU/Vulkan suites +7/-0; Vulkan rewind +13/-0.
  (
    abi: 'linux_x64',
    backend: BackendKind.cpu,
    androidGpu: null,
    npuVendor: null,
  ),
  (
    abi: 'linux_x64',
    backend: BackendKind.gpu,
    androidGpu: null,
    npuVendor: null,
  ),
  // 2026-11-06: suite +7/-0 on Intel LNL and PTL.
  (
    abi: 'windows_x64',
    backend: BackendKind.cpu,
    androidGpu: null,
    npuVendor: null,
  ),
  // 2026-11-06: LNL D3D12 suite +7/-0; stop/rewind +13/-0.
  (
    abi: 'windows_x64',
    backend: BackendKind.gpu,
    androidGpu: null,
    npuVendor: null,
  ),
  // 2026-11-06: DDP round 2 +8/-0 on S25 Ultra and Pixel 8a CPU.
  (
    abi: 'android_arm64',
    backend: BackendKind.cpu,
    androidGpu: null,
    npuVendor: null,
  ),
  // 2026-11-06: DDP round 2 +8/-0 on Adreno 830 and Mali-G715.
  (
    abi: 'android_arm64',
    backend: BackendKind.gpu,
    androidGpu: AndroidGpuFamily.adreno,
    npuVendor: null,
  ),
  (
    abi: 'android_arm64',
    backend: BackendKind.gpu,
    androidGpu: AndroidGpuFamily.mali,
    npuVendor: null,
  ),
  // 2026-11-06: DDP round 2 +8/-0 on Pixel 11 PowerVR (virtual sessions).
  (
    abi: 'android_arm64',
    backend: BackendKind.gpu,
    androidGpu: AndroidGpuFamily.powerVr,
    npuVendor: null,
  ),
};

/// Every row that may be qualified in the 2.6.0 device campaign.
final liteRtLmConstrainedDecodingCandidateRows =
    <LiteRtLmConstrainedDecodingRow>{
      for (final abi in [
        'macos_arm64',
        'linux_x64',
        'linux_arm64',
        'windows_x64',
        'android_arm64',
        'ios_arm64',
      ])
        (abi: abi, backend: BackendKind.cpu, androidGpu: null, npuVendor: null),
      for (final abi in [
        'macos_arm64',
        'linux_x64',
        'linux_arm64',
        'windows_x64',
        'ios_arm64',
      ])
        (abi: abi, backend: BackendKind.gpu, androidGpu: null, npuVendor: null),
      for (final gpu in AndroidGpuFamily.values)
        (
          abi: 'android_arm64',
          backend: BackendKind.gpu,
          androidGpu: gpu,
          npuVendor: null,
        ),
      for (final vendor in NpuStack.values)
        for (final abi in vendor.abis)
          (
            abi: abi,
            backend: BackendKind.npu,
            androidGpu: null,
            npuVendor: vendor,
          ),
    };

LiteRtLmConstrainedDecodingRow liteRtLmConstrainedDecodingRow({
  required String abi,
  required BackendKind backend,
  AndroidGpuFamily? androidGpu,
  NpuStack? npuVendor,
}) => (
  abi: abi,
  backend: backend,
  androidGpu: backend == BackendKind.gpu && abi == 'android_arm64'
      ? androidGpu
      : null,
  npuVendor: backend == BackendKind.npu ? npuVendor : null,
);

/// Why a response format is refused for a model loaded on [backend] on the
/// host [abi], or null where that row passed ([liteRtLmConstrainedDecodingRows]).
String? liteRtLmConstrainedDecodingRefusal({
  required String abi,
  required BackendKind backend,
  AndroidGpuFamily? androidGpu,
  NpuStack? npuVendor,
}) {
  final row = liteRtLmConstrainedDecodingRow(
    abi: abi,
    backend: backend,
    androidGpu: androidGpu,
    npuVendor: npuVendor,
  );
  if (liteRtLmConstrainedDecodingRows.contains(row)) return null;
  final detail = switch (backend) {
    BackendKind.cpu => '$abi CPU',
    BackendKind.gpu when abi == 'android_arm64' =>
      '$abi GPU (${androidGpu?.name ?? 'unknown family'})',
    BackendKind.gpu => '$abi GPU',
    BackendKind.npu => '$abi NPU (${npuVendor?.label ?? 'unknown vendor'})',
  };
  return 'LiteRT-LM constrained decoding is refused on $detail until that row '
      'passes the discriminating device run.';
}
