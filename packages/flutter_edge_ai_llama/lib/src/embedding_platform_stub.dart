/// Web never constructs a native embedding pass.
String? nativeEmbeddingGpuRefusal({
  bool? isAndroid,
  bool? isIOS,
  String? Function(String)? readVariable,
}) => null;

/// Web never constructs a native embedding pass.
bool nativeEmbeddingAutoUsesCpu({
  bool? isAndroid,
  bool? isIOS,
  bool? isMacosX64,
  String? Function(String)? readVariable,
}) => false;
