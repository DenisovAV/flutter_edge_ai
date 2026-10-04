import 'dart:io';

import 'android/proc_memory.dart';
import 'ios/mach_memory.dart';
import 'memory_snapshot.dart';

/// Memory diagnostics read from the OS: Android and iOS.
abstract final class FlutterEdgeAiDiagnostics {
  /// Whether [memorySnapshot] can run on this platform.
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Reads this process's memory from the OS.
  ///
  /// Throws [UnsupportedError] off Android and iOS rather than returning a
  /// snapshot of nulls: the numbers only mean something where jetsam or lmkd
  /// enforce them. Throws `MemoryReadException` when the OS read itself
  /// fails; a null field is reserved for a value that does not exist here.
  ///
  /// Asynchronous so later fields that need a platform call can be added
  /// without changing the signature.
  static Future<MemorySnapshot> memorySnapshot() async {
    if (Platform.isAndroid) return readProcMemorySnapshot();
    if (Platform.isIOS) return readMachMemorySnapshot();
    throw UnsupportedError(
      'flutter_edge_ai_diagnostics supports Android and iOS, '
      'not ${Platform.operatingSystem}.',
    );
  }
}

@Deprecated(
  'Use FlutterEdgeAiDiagnostics: flutter_gemma_diagnostics was renamed to '
  'flutter_edge_ai_diagnostics (dart fix --apply migrates). Removed in '
  'flutter_edge_ai_diagnostics 0.2.0.',
)
typedef FlutterGemmaDiagnostics = FlutterEdgeAiDiagnostics;
