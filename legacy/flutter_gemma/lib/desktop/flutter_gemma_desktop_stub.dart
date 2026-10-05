// Stub for desktop implementation on web platform
//
// This file is used when the library is compiled for web.
// Desktop functionality is not available on web.

import '../flutter_gemma_interface.dart';

/// Desktop plugin is not available on web
class FlutterGemmaDesktop extends FlutterGemmaPlugin {
  FlutterGemmaDesktop._() {
    throw UnsupportedError('Desktop is not supported on web platform');
  }

  static FlutterGemmaDesktop get instance =>
      throw UnsupportedError('Desktop is not supported on web platform');

  static void registerWith() {
    // No-op on web
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Desktop is not supported on web platform');
  }
}

/// Always false on web
bool get isDesktop => false;
