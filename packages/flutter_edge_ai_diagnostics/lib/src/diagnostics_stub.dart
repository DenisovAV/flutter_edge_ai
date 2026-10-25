import 'package:meta/meta.dart';

import 'gpu_memory_reading.dart';
import 'memory_snapshot.dart';

/// Memory diagnostics read from the OS: Android, iOS and macOS.
///
/// This is the build without `dart:ffi` (web), where there is nothing to read.
abstract final class FlutterEdgeAiDiagnostics {
  /// Always false here.
  static bool get isSupported => false;

  /// Always throws [UnsupportedError] here.
  static Future<MemorySnapshot>
  memorySnapshot() async => throw UnsupportedError(
    'flutter_edge_ai_diagnostics supports Android, iOS and macOS, not the web.',
  );

  /// Always throws [UnsupportedError] here.
  @experimental
  static Future<GpuMemoryReading?> gpuMemory() async => throw UnsupportedError(
    'flutter_edge_ai_diagnostics supports Android, iOS and macOS, not the web.',
  );
}
