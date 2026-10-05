import 'package:meta/meta.dart';

/// One reading of this process's memory, taken from the OS rather than from
/// any inference engine.
///
/// Every field is nullable. A null means the value does not exist on this
/// platform or OS version, never zero. A read that should have worked and
/// failed throws `MemoryReadException` instead, so a broken read is never
/// reported as a documented gap. Fields added in later versions will be
/// nullable too.
@immutable
final class MemorySnapshot {
  /// Creates a snapshot. Apps get one from `FlutterGemmaDiagnostics`.
  const MemorySnapshot({
    required this.anonymousBytes,
    required this.availableBytes,
    required this.takenAt,
  });

  /// Memory the OS charges to this process and cannot reclaim by dropping
  /// file pages.
  ///
  /// On both platforms, weights read from an mmapped model file are clean
  /// file pages and are not counted.
  ///
  /// - **iOS:** `phys_footprint` from `task_info(TASK_VM_INFO)`, the value
  ///   jetsam enforces its per-app limit against, so on iOS this is the number
  ///   that decides whether the app is killed. It includes IOKit and GPU
  ///   (Metal) allocations and compressed memory.
  /// - **Android:** `Private_Dirty + SwapPss` from `/proc/self/smaps_rollup`.
  ///   `SwapPss` counts pages moved to zRAM, which still belong to the app.
  ///   This is not a kill threshold: lmkd decides from device-wide pressure
  ///   and process priority. GPU memory (KGSL, Mali, dmabuf) is mostly outside
  ///   smaps, so memory a model holds on the GPU is largely not counted here.
  ///
  /// Null only on Android kernels older than 4.14, which have no
  /// `smaps_rollup`. On iOS it is never null.
  final int? anonymousBytes;

  /// Memory still available before the OS starts reclaiming or killing.
  ///
  /// The two platforms answer different questions, because they enforce
  /// memory differently:
  ///
  /// - **iOS:** `os_proc_available_memory()`, the headroom left before *this
  ///   app* reaches its jetsam limit. A per-app number.
  /// - **Android:** `MemAvailable` from `/proc/meminfo`, the kernel's estimate
  ///   of memory available on *the whole device*. Android has no per-app hard
  ///   limit. Treat it as an optimistic upper bound: lmkd starts killing well
  ///   before it reaches zero.
  ///
  /// Null only on iOS when the call returns 0: Apple returns 0 both when no
  /// limit applies (the simulator) and when the limit is already exceeded,
  /// and the two cannot be told apart. On Android it is never null.
  final int? availableBytes;

  /// When this snapshot was taken.
  final DateTime takenAt;

  @override
  bool operator ==(Object other) =>
      other is MemorySnapshot &&
      other.anonymousBytes == anonymousBytes &&
      other.availableBytes == availableBytes &&
      other.takenAt == takenAt;

  @override
  int get hashCode => Object.hash(anonymousBytes, availableBytes, takenAt);

  @override
  String toString() =>
      'MemorySnapshot(anonymousBytes: $anonymousBytes, '
      'availableBytes: $availableBytes, takenAt: $takenAt)';
}
