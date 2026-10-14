import 'dart:io';

import 'android/proc_memory.dart';
import 'ios/mach_memory.dart';
import 'memory_snapshot.dart';

/// Memory diagnostics read from the OS: Android, iOS and macOS.
abstract final class FlutterEdgeAiDiagnostics {
  /// Whether [memorySnapshot] can run on this platform.
  static bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// Reads this process's memory from the OS.
  ///
  /// Throws [UnsupportedError] off Android, iOS and macOS rather than returning
  /// a snapshot of nulls: the numbers only mean something where the OS keeps
  /// them. Throws `MemoryReadException` when the OS read itself
  /// fails; a null field is reserved for a value that does not exist here.
  ///
  /// On Android the `/proc` files are read asynchronously, so calling this from
  /// the UI isolate does not block it. iOS and macOS reads are Mach calls
  /// that take microseconds.
  static Future<MemorySnapshot> memorySnapshot() async {
    if (Platform.isAndroid) return readProcMemorySnapshot();
    if (Platform.isIOS || Platform.isMacOS) return readMachMemorySnapshot();
    throw UnsupportedError(
      'flutter_edge_ai_diagnostics supports Android, iOS and macOS, '
      'not ${Platform.operatingSystem}.',
    );
  }
}
