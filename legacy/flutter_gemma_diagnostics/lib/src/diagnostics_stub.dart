import 'memory_snapshot.dart';

/// Memory diagnostics read from the OS: Android and iOS.
///
/// This is the build without `dart:ffi` (web), where there is nothing to read.
abstract final class FlutterGemmaDiagnostics {
  /// Always false here.
  static bool get isSupported => false;

  /// Always throws [UnsupportedError] here.
  static Future<MemorySnapshot> memorySnapshot() async =>
      throw UnsupportedError(
        'flutter_gemma_diagnostics supports Android and iOS, not the web.',
      );
}
