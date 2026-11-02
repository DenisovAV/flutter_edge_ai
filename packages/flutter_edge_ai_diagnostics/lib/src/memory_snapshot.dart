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
    this.anonymousPeakBytes,
  });

  /// Process memory measured as the iOS and macOS footprint, the Windows
  /// commit charge or the Android and Linux `Private_Dirty + SwapPss`.
  ///
  /// On every platform, weights read from an mmapped model file are clean
  /// file pages and are not counted.
  ///
  /// - **iOS:** `phys_footprint` from `task_info(TASK_VM_INFO)`, the value
  ///   jetsam enforces its per-app limit against, so on iOS this is the number
  ///   that decides whether the app is killed. It includes IOKit and GPU
  ///   (Metal) allocations and compressed memory.
  /// - **macOS:** the same `phys_footprint` call, the figure Activity Monitor
  ///   shows as "Memory". macOS has no per-app kill limit, so it measures what
  ///   the app holds, not distance from a threshold.
  /// - **Android:** `Private_Dirty + SwapPss` from `/proc/self/smaps_rollup`.
  ///   `SwapPss` counts pages moved to zRAM, which still belong to the app.
  ///   Singly mapped dirty file pages are included in `Private_Dirty` too;
  ///   clean anonymous pages and `Shared_Dirty` are not included.
  ///   This is not a kill threshold: lmkd decides from device-wide pressure
  ///   and process priority. GPU memory (KGSL, Mali, dmabuf) is mostly outside
  ///   smaps, so memory a model holds on the GPU is largely not counted here;
  ///   on Adreno most of it is counted in [fileBackedBytes] instead.
  ///
  /// - **Linux:** the same two `/proc/self/smaps_rollup` fields as Android.
  ///   GPU memory is in neither field on desktop Linux, and on an integrated
  ///   GPU it is system RAM that this snapshot does not show: a FunctionGemma
  ///   270M on the GPU cost 700 to 835 MiB of Intel `drm-resident-system0`
  ///   with the device mappings at 0 MiB.
  /// - **Windows:** the commit charge, `PagefileUsage` of
  ///   `K32GetProcessMemoryInfo` (Microsoft documents it as the same number as
  ///   `PrivateUsage`): the private memory the process owns, wherever it is
  ///   (resident, compressed or paged out), like `phys_footprint` on iOS and
  ///   `SwapPss` on Android. It counts memory when it is allocated, not when
  ///   it is touched, so it reads higher than the resident figure and is not
  ///   comparable with the other platforms: a FunctionGemma 270M load on the
  ///   CPU raised it by 389 to 392 MiB and the private working set by 102 to
  ///   105 MiB (one machine), and with the first prompt the rises reached 527
  ///   to 531 and 225 to 229 MiB: about three quarters of the commit arrives
  ///   at load, while slightly more than half of the private working set
  ///   (about 55%) and most of [fileBackedBytes] arrive with the first prompt.
  ///   On the GPU the load raised it by 1,075 to 1,083 MiB, so part of a GPU
  ///   model's memory may be in it; how much is not measured. After a GPU
  ///   model is closed it falls with a delay. On one machine (RTX 3050,
  ///   FunctionGemma 270M, debug build, two runs of four load/close cycles
  ///   per process) it stayed about 360 MiB above its start for about 2 s and
  ///   stopped falling by about 8 s, leaving about 65 MiB after the first
  ///   cycle in a process and at most about 16 MiB after later cycles.
  ///   Elsewhere, read it again until it stops falling before you compare.
  ///
  /// Null only on an Android or Linux kernel without `smaps_rollup`. Vendor
  /// kernels may backport it. On iOS, macOS and Windows it is never null.
  final int? anonymousBytes;

  /// Memory still available before the OS starts reclaiming or killing (on
  /// Windows, which kills nothing for low memory, see below).
  ///
  /// The platforms answer different questions, because they enforce
  /// memory differently:
  ///
  /// - **iOS:** `os_proc_available_memory()`, the headroom left before *this
  ///   app* reaches its jetsam limit. A per-app number.
  /// - **Android:** `MemAvailable` from `/proc/meminfo`, the kernel's estimate
  ///   of memory available on *the whole device*. Android has no per-app hard
  ///   limit. Treat it as an optimistic upper bound: lmkd starts killing well
  ///   before it reaches zero.
  /// - **Linux:** the same `MemAvailable`, machine-wide. It ignores a cgroup
  ///   `memory.max` (a container or a systemd scope with a limit): the limit
  ///   is the cgroup's, not this number.
  ///
  /// - **Windows:** `ullAvailPhys` from `GlobalMemoryStatusEx`, the physical
  ///   memory on *the whole machine* that can be reused without writing its
  ///   contents to disk first (the standby, free and zero lists). It is not
  ///   this app's headroom: Windows does not kill a process when RAM runs low,
  ///   and an allocation fails once the machine's commit reaches the commit
  ///   limit (RAM plus the page files), not when RAM runs out. That headroom
  ///   is `ullAvailPageFile` of the same call ("the maximum amount of
  ///   memory the current process can commit", per Microsoft), which this
  ///   package does not read.
  /// - **macOS:** null. `os_proc_available_memory()` is iOS-only and macOS has
  ///   no per-app limit to measure headroom against.
  ///
  /// Null on macOS, and on iOS when the call returns 0: Apple returns 0 both
  /// when no limit applies (the simulator) and when the limit is already
  /// exceeded, and the two cannot be told apart. On Android, Linux and Windows
  /// it is never null.
  final int? availableBytes;

  /// Resident clean pages on Android and Linux (mostly mapped files on a CPU
  /// backend, and GPU driver buffers too on some GPU backends), and the
  /// shareable working set on Windows (see below).
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
  ///   GPU backends: on Adreno, the driver's buffers are mapped through
  ///   `/dev/kgsl-3d0` and are mostly clean pages, so they are counted here.
  ///   In one run on a vivo 1933 (Adreno 616, kernel 4.9) a Gemma 4 E2B GPU
  ///   load raised that mapping from 6 to 981 MiB, and 988 MiB after one
  ///   prompt, matching `dumpsys meminfo`'s Gfx dev. About 115 MiB of it was
  ///   dirty (that part is in [anonymousBytes]); all file mappings together
  ///   (model, libraries, others) were about 260 MiB (Pss). With a GPU
  ///   backend this is not a model-file figure: compare with a CPU run of the
  ///   same app, or subtract the clean pages of the `/dev/kgsl*` mappings of
  ///   `/proc/self/smaps`. One device and one run each; other GPU drivers
  ///   (Mali) were not measured.
  ///
  ///   Reclaimable file pages are not a kill threshold, but are not free:
  ///   weights read on every token must be read back from storage if dropped.
  ///   Android lmkd can treat that refault thrashing as a reason to kill.
  /// - **Linux:** `Private_Clean + Shared_Clean`, as on Android, with the same
  ///   caveat about clean anonymous pages: a page read back from swap and not
  ///   written since is in `Private_Clean`, not in `SwapPss` (measured on
  ///   Linux 7.0: 512 MiB swapped out and read back showed as 512 MiB
  ///   `Private_Clean`, `Swap` 0), which moves memory from [anonymousBytes]
  ///   into this field, as zram readback does on Android.
  /// - **Windows:** `WorkingSetSize - PrivateWorkingSetSize`: the shareable
  ///   working set, every resident page that is not private to the process.
  ///   That is mapped files and DLL code, but also modified shared pages (a
  ///   written pagefile-backed section or shared view), so it is neither
  ///   "clean" nor "model weights". A LiteRT-LM model on the CPU is mapped at
  ///   load and faulted in by the first prompt (113 MiB before, 138 MiB after
  ///   the load and 402 MiB after the prompt, for a 284 MB file; the DLL pages
  ///   could not be told apart), while ORT-GenAI's weights landed in the
  ///   private working set and not here. Read before loading and subtract.
  ///   `EmptyWorkingSet` emptied the private working set (249.9 to 0.8 MiB)
  ///   and left commit unchanged; minimizing the window changed nothing
  ///   without memory pressure, and what it does under pressure is not
  ///   measured. Null when the OS does not fill `PrivateWorkingSetSize` (a
  ///   Windows that predates the extended struct; not tested on one).
  /// - **iOS and macOS:** null. This package does not read a corresponding
  ///   value yet; `TASK_VM_INFO.external` is a possible follow-up.
  ///
  /// Null on iOS and macOS, on an Android or Linux kernel without
  /// `smaps_rollup`, and on a Windows without the extended struct.
  final int? fileBackedBytes;

  /// The highest [anonymousBytes] this process has reached since it started.
  ///
  /// - **iOS and macOS:** `ledger_phys_footprint_peak` from the same
  ///   `task_info(TASK_VM_INFO)` reply as [anonymousBytes]. It is a lifetime
  ///   high-water mark kept by the kernel: it is not reset between a model's
  ///   load and its prompts, so a spike that happened before you started
  ///   measuring is in it. To attribute a peak to one operation, take a
  ///   snapshot before and compare, and treat the value as an upper bound.
  /// - **Windows:** `PeakPagefileUsage`, the highest commit charge since the
  ///   process started, the peak of the same quantity [anonymousBytes] holds
  ///   there. Also a lifetime mark: take a snapshot before and compare.
  /// - **Android and Linux:** null. The kernel keeps no peak of anonymous
  ///   memory; `VmHWM` includes file-backed pages and would be a different
  ///   number.
  ///
  /// Null on Android and Linux, and on an iOS or macOS version whose
  /// `task_info` reply predates the field. Never null on Windows.
  final int? anonymousPeakBytes;

  /// When this snapshot was taken.
  final DateTime takenAt;

  @override
  bool operator ==(Object other) =>
      other is MemorySnapshot &&
      other.anonymousBytes == anonymousBytes &&
      other.availableBytes == availableBytes &&
      other.fileBackedBytes == fileBackedBytes &&
      other.anonymousPeakBytes == anonymousPeakBytes &&
      other.takenAt == takenAt;

  @override
  int get hashCode => Object.hash(
    anonymousBytes,
    availableBytes,
    fileBackedBytes,
    anonymousPeakBytes,
    takenAt,
  );

  @override
  String toString() =>
      'MemorySnapshot(anonymousBytes: $anonymousBytes, '
      'availableBytes: $availableBytes, '
      'fileBackedBytes: $fileBackedBytes, '
      'anonymousPeakBytes: $anonymousPeakBytes, takenAt: $takenAt)';
}
