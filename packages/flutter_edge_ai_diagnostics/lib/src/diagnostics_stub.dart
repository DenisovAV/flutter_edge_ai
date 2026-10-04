import 'memory_snapshot.dart';

/// Memory diagnostics read from the OS: Android and iOS.
///
/// This is the build without `dart:ffi` (web), where there is nothing to read.
abstract final class FlutterEdgeAiDiagnostics {
  /// Always false here.
  static bool get isSupported => false;

  /// Always throws [UnsupportedError] here.
  static Future<MemorySnapshot> memorySnapshot() async =>
      throw UnsupportedError(
        'flutter_edge_ai_diagnostics supports Android and iOS, not the web.',
      );
}

@Deprecated(
  'Use FlutterEdgeAiDiagnostics: flutter_gemma_diagnostics was renamed to '
  'flutter_edge_ai_diagnostics (dart fix --apply migrates). Removed in '
  'flutter_edge_ai_diagnostics 0.2.0.',
)
typedef FlutterGemmaDiagnostics = FlutterEdgeAiDiagnostics;
