import 'package:meta/meta.dart';

/// One reading of this process's memory, taken from the OS rather than from
/// any inference engine.
///
/// Every field is nullable. A null means the value is not reported on this
/// platform or OS version, never zero. A read that should have worked and
/// failed throws `MemoryReadException` instead, so a broken read is never
/// reported as a documented gap. Fields added in later versions will be
/// nullable too.
@immutable
final class MemorySnapshot {
  /// Creates a snapshot. Apps get one from `FlutterEdgeAiDiagnostics`.
  const MemorySnapshot({
    required this.anonymousBytes,
    required this.availableBytes,
    required this.takenAt,
    this.fileBackedBytes,
  });

  /// Process memory measured as the iOS footprint or Android's
  /// `Private_Dirty + SwapPss`.
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
  ///   Singly mapped dirty file pages are included in `Private_Dirty` too;
  ///   clean anonymous pages and `Shared_Dirty` are not included.
  ///   This is not a kill threshold: lmkd decides from device-wide pressure
  ///   and process priority. GPU memory (KGSL, Mali, dmabuf) is mostly outside
  ///   smaps, so memory a model holds on the GPU is largely not counted here.
  ///
  /// Null only on an Android kernel without `smaps_rollup`. Vendor kernels
  /// may backport it. On iOS it is never null.
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

  /// Resident clean pages, mostly mapped files.
  ///
  /// - **Android:** `Private_Clean + Shared_Clean` from
  ///   `/proc/self/smaps_rollup`. A mapped model appears as its clean pages
  ///   become resident. The baseline includes every clean mapped file the
  ///   process has touched; read before loading and subtract. Shared pages
  ///   count in full, not proportionally.
  ///
  ///   Clean does not identify a page's backing: clean anonymous pages can
  ///   also be included, such as pages read back from zram and not written
  ///   since, or `MADV_FREE` pages. On zram's skip-swapcache path, a page can
  ///   lose its swap slot and leave `SwapPss`, moving memory from
  ///   [anonymousBytes] into this field. A delta is therefore not an exact
  ///   measure of mapped model weights. Singly mapped dirty file pages are
  ///   in `Private_Dirty` ([anonymousBytes]); `Shared_Dirty` is in neither.
  ///
  ///   Reclaimable file pages are not a kill threshold, but are not free:
  ///   weights read on every token must be read back from storage if dropped.
  ///   Android lmkd can treat that refault thrashing as a reason to kill.
  /// - **iOS:** null. This package does not read a corresponding value yet;
  ///   `TASK_VM_INFO.external` is a possible follow-up.
  ///
  /// Null on iOS, and on an Android kernel without `smaps_rollup`.
  final int? fileBackedBytes;

  /// When this snapshot was taken.
  final DateTime takenAt;

  @override
  bool operator ==(Object other) =>
      other is MemorySnapshot &&
      other.anonymousBytes == anonymousBytes &&
      other.availableBytes == availableBytes &&
      other.fileBackedBytes == fileBackedBytes &&
      other.takenAt == takenAt;

  @override
  int get hashCode =>
      Object.hash(anonymousBytes, availableBytes, fileBackedBytes, takenAt);

  @override
  String toString() =>
      'MemorySnapshot(anonymousBytes: $anonymousBytes, '
      'availableBytes: $availableBytes, '
      'fileBackedBytes: $fileBackedBytes, takenAt: $takenAt)';
}
