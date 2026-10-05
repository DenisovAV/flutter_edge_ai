// Web stub for platform_file_system_service.dart.
//
// The real PlatformFileSystemService uses dart:io + path_provider, which break
// dart2wasm. Web never instantiates it — ServiceRegistry picks
// WebFileSystemService when kIsWeb. This stub exists only so the web/wasm
// import graph compiles without pulling in dart:io. (noSuchMethod satisfies the
// FileSystemService interface without re-declaring all members; the constructor
// throws because it must never be reached on web.)

import 'package:flutter_gemma/core/services/file_system_service.dart';

class PlatformFileSystemService implements FileSystemService {
  PlatformFileSystemService() {
    throw UnsupportedError(
      'PlatformFileSystemService is not available on web — '
      'ServiceRegistry uses WebFileSystemService instead.',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('web stub — never instantiated');
}
