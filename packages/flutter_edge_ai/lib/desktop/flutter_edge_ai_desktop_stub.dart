// Stub for desktop implementation on web platform
//
// This file is used when the library is compiled for web.
// Desktop functionality is not available on web.

import '../flutter_edge_ai_interface.dart';

/// Desktop plugin is not available on web
class FlutterEdgeAiDesktop extends FlutterEdgeAiPlugin {
  FlutterEdgeAiDesktop._() {
    throw UnsupportedError('Desktop is not supported on web platform');
  }

  static FlutterEdgeAiDesktop get instance =>
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

@Deprecated(
  'Use FlutterEdgeAiDesktop: flutter_gemma was renamed to flutter_edge_ai '
  '(dart fix --apply migrates). Removed in flutter_edge_ai 2.0.0.',
)
typedef FlutterGemmaDesktop = FlutterEdgeAiDesktop;
