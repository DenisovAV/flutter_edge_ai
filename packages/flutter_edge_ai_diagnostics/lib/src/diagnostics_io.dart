import 'dart:io';

import 'package:meta/meta.dart';

import 'android/proc_memory.dart';
import 'gpu_memory_reading.dart';
import 'ios/mach_memory.dart';
import 'memory_snapshot.dart';

/// Memory diagnostics read from the OS: Android, iOS and macOS.
abstract final class FlutterEdgeAiDiagnostics {
  /// Whether [memorySnapshot] can run on this platform. [gpuMemory] runs on
  /// the same platforms and returns null on iOS and macOS.
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

  /// Reads the GPU memory that is mapped into this process (experimental).
  ///
  /// Null means there is no reader for this device: iOS and macOS (not read
  /// yet) and a GPU with no `/dev/kgsl-3d0` (a Mali GPU, not measured). On an
  /// Adreno phone the answer is never null: a process that has not used the GPU
  /// yet (a headless engine, a background isolate, a read before the first
  /// frame) gets a reading of zeros, because the device node exists
  /// (`File('/dev/kgsl-3d0').existsSync()` is true from an app on a vivo 1933
  /// and a Galaxy S26+, although `typeSync` says not found).
  ///
  /// Throws [UnsupportedError] off Android, iOS and macOS, and
  /// `MemoryReadException` when `/proc/self/smaps` cannot be read or parsed.
  /// It reads the per-mapping `smaps`, which the kernel builds mapping by
  /// mapping while holding the process's `mmap_lock`, so it can stall the
  /// process's other `mmap` calls: on a vivo 1933 it took about 0.2 s before a
  /// model was loaded and 0.3 to 0.4 s after a GPU load (3,300 and 4,200
  /// mappings, screen on). The file is read asynchronously, but decoding and
  /// scanning it run on the calling isolate. Call it at a few points, not per
  /// frame or per token.
  @experimental
  static Future<GpuMemoryReading?> gpuMemory() async {
    if (Platform.isAndroid) return readGpuMemoryReading();
    if (Platform.isIOS || Platform.isMacOS) return null;
    throw UnsupportedError(
      'flutter_edge_ai_diagnostics supports Android, iOS and macOS, '
      'not ${Platform.operatingSystem}.',
    );
  }
}
