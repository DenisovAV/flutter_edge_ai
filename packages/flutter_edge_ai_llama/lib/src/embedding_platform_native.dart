import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Src-only platform seam. CoreSimulator sets SIMULATOR_UDID on simulator
/// processes, including arm64; Platform.environment is empty on iOS.
String? nativeEmbeddingGpuRefusal({
  bool? isAndroid,
  bool? isIOS,
  String? Function(String)? readVariable,
}) {
  if (isAndroid ?? Platform.isAndroid) {
    return 'GPU GGUF embeddings are unavailable on Android; use CPU.';
  }
  if ((isIOS ?? Platform.isIOS) &&
      ((readVariable ?? _environmentVariable)('SIMULATOR_UDID')?.isNotEmpty ??
          false)) {
    return 'GPU GGUF embeddings are unavailable on iOS simulators; use CPU.';
  }
  return null;
}

/// Whether llamadart intentionally selects CPU for automatic placement.
/// macOS x64 includes Rosetta; explicit GPU requests retain their own policy.
bool nativeEmbeddingAutoUsesCpu({
  bool? isAndroid,
  bool? isIOS,
  bool? isMacosX64,
  String? Function(String)? readVariable,
}) =>
    (isMacosX64 ?? Abi.current() == Abi.macosX64) ||
    nativeEmbeddingGpuRefusal(
          isAndroid: isAndroid,
          isIOS: isIOS,
          readVariable: readVariable,
        ) !=
        null;

typedef _Getenv = Pointer<Utf8> Function(Pointer<Utf8>);

String? _environmentVariable(String name) {
  final getenv = DynamicLibrary.process().lookupFunction<_Getenv, _Getenv>(
    'getenv',
  );
  final nativeName = name.toNativeUtf8(allocator: calloc);
  try {
    final value = getenv(nativeName);
    return value == nullptr ? null : value.toDartString();
  } finally {
    calloc.free(nativeName);
  }
}
