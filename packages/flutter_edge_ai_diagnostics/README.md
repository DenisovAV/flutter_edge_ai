# flutter_edge_ai_diagnostics

> **Renamed from [`flutter_gemma_diagnostics`](https://pub.dev/packages/flutter_gemma_diagnostics).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_diagnostics/` imports; nothing on the device
> changes. `FlutterGemmaDiagnostics` is now `FlutterEdgeAiDiagnostics` (0.2.0 drops the old
> name); `dart fix --apply` renames it. See the [migration guide](https://flutteredge.ai/docs/migration).

Opt-in memory diagnostics for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai) apps, read from the OS on Android, iOS, macOS, Linux and Windows.

## Why not the memory number your profiler shows?

The first "memory used" number people reach for is usually **RSS**, the *resident set size* — the `RES` column in `top`, `ps -o rss`: every page of the app that is sitting in physical RAM right now. For a model it answers the wrong question, because it adds together two kinds of memory that the OS treats in opposite ways. (Xcode's memory gauge is the exception: on iOS it already shows the footprint this package reports.)

**File-backed pages the OS can take back.** LiteRT-LM maps a `.litertlm` file into memory (`mmap`) instead of reading it into a buffer. Pages of the weights the model has touched count in RSS, but they are still just a view of the file on disk: when memory gets tight the OS drops them and reads them again later. They are reclaimable, but not free: a model reads weights on every token, so dropped pages must be read back from storage. Android lmkd can kill under refault thrashing; the kernel does not necessarily discard every file page before reclaiming anonymous memory.

**Anonymous memory without a reloadable model file.** Everything the app built itself and that exists nowhere else: the heap, a copy of the weights in a buffer or on the GPU, the KV cache, activations. There is no model file to reload these contents from. The OS can compress or swap anonymous pages, but it cannot simply discard live contents.

In RSS the two look the same. Mapped weights and weights copied into the heap can show similar RSS while producing different footprint readings. A mapped model still needs a working set that fits the device to avoid repeated storage reads. On iOS, jetsam enforces its per-app limit on the footprint rather than RSS.

This package reports `anonymousBytes` (the iOS and macOS footprint, the Windows commit charge, or `Private_Dirty + SwapPss` on Android and Linux), `anonymousPeakBytes` on iOS, macOS and Windows (the lifetime peak of that figure), `fileBackedBytes` on Android, Linux and Windows (resident clean pages: mapped files on a CPU backend, plus GPU driver buffers on some GPU backends; on Windows the working set that is not private), and `availableBytes` (headroom on iOS, a machine-wide estimate on Android, Linux and Windows, null on macOS). Take readings before loading, after loading, and during generation. Their changes help explain the model's memory cost, with the limits below.

## Usage

```yaml
dependencies:
  flutter_edge_ai_diagnostics: ^0.6.0
```

If you only use it from `integration_test/` or `test/`, put it under `dev_dependencies` instead. Note that neither section strips anything from a release build: what keeps it out is not importing it from `lib/`.

```dart
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';

if (FlutterEdgeAiDiagnostics.isSupported) {
  final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
  print(snapshot.anonymousBytes);
  print(snapshot.availableBytes);
}
```

Each Android snapshot walks the process's page tables (about 150 ms on a low-end device with a 4.9 kernel, and before Linux 5.10 it stalls the process's mmap calls), so do not poll faster than about once a second. The read is asynchronous, which moves the wait off your isolate but not the kernel's cost.

On Linux the same walk costs about 3.7 ms per resident GiB (1.7 ms idle, about 30 ms with 7 GiB resident), measured on one machine. Call it at a few points, not per frame or per token. On Windows a snapshot is two `kernel32` calls; their cost has not been timed.

Take a snapshot before loading a model, after loading it, and during generation. On Android and Linux, neither process counter alone measures the model's entire memory cost.

## What each field means

| Field | iOS and macOS | Android and Linux | Windows |
|---|---|---|---|
| `anonymousBytes` | `phys_footprint` from `task_info(TASK_VM_INFO)`: on iOS the value jetsam enforces, including IOKit/GPU (Metal) allocations and compressed memory; on macOS the figure Activity Monitor calls "Memory", with no kill limit behind it | `Private_Dirty + SwapPss` from `/proc/self/smaps_rollup`. GPU memory (KGSL, Mali, dmabuf) is mostly outside it; on Adreno most of it is in `fileBackedBytes` instead. On desktop Linux GPU memory is in neither field (see below) | `PagefileUsage` of `K32GetProcessMemoryInfo`, the commit charge (Microsoft documents it as `PrivateUsage`): private memory the process owns, resident, compressed or paged out. Counted when allocated, not when touched, so it reads higher than the other platforms' figures (see below) |
| `fileBackedBytes` | null: not read on iOS or macOS yet | `Private_Clean + Shared_Clean` from `/proc/self/smaps_rollup`: resident clean pages (mapped files on a CPU backend, plus GPU driver buffers on some GPU backends, see below). Counts shared pages in full | `WorkingSetSize − PrivateWorkingSetSize`: the resident pages that are not private, DLL pages included. Null on a Windows that does not fill the extended struct |
| `anonymousPeakBytes` | `ledger_phys_footprint_peak` from the same `task_info` reply: the highest `phys_footprint` since the process started (a lifetime mark, never reset) | null: the kernel keeps no anonymous-only peak | `PeakPagefileUsage`: the highest commit since the process started (a lifetime mark, never reset) |
| `availableBytes` | iOS: `os_proc_available_memory()`, headroom before **this app** hits its limit; null on macOS, which has no per-app limit | `MemAvailable` from `/proc/meminfo`: available on **the whole device or machine**, an optimistic upper bound. On Linux it ignores a cgroup `memory.max` | `ullAvailPhys` from `GlobalMemoryStatusEx`: available on **the whole machine**, an upper bound for this app; it ignores a job object's memory limit |

On Android and Linux, clean does not mean exclusively file-backed. `Private_Clean` can include anonymous pages read back from swap (zram on Android) and not written since, and `MADV_FREE` pages. On zram's skip-swapcache path, a page can lose its swap slot and leave `SwapPss`. Loading a model under memory pressure can therefore move cold heap memory from `anonymousBytes` into `fileBackedBytes`; the delta is not an exact count of mapped weights. On Linux 7.0, 512 MiB swapped out and read back showed as 512 MiB of `Private_Clean` with `Swap` 0.

**Windows commit.** `anonymousBytes` is the commit charge: memory is counted when it is allocated, not when it is touched, so it reads higher than the resident figure and is not comparable with the other platforms. On one machine (i5-12450H, Windows 11 build 26200, debug build of the example) a FunctionGemma 270M `.litertlm` (284 MB) on the CPU raised commit by 389 to 392 MiB at load and 527 to 531 MiB after the first prompt (three fresh processes each), while the private working set rose by 102 to 105 and 225 to 229 MiB. So most of a model's memory arrives with the first prompt, not at load: on the CPU the weights are mapped at load (`fileBackedBytes` 113 to 138 MiB) and faulted in by the prompt (402 MiB). ORT-GenAI's weights landed in the private working set instead (Phi-3.5-mini: 3,302 MiB private against 193 MiB file-backed). On the GPU (RTX 3050) the load raised commit by 1,075 to 1,083 MiB. Trimming the working set (`EmptyWorkingSet`) emptied the private working set but left commit unchanged, and minimizing the window changed nothing without memory pressure; what it does under pressure is not measured.

**Windows GPU memory.** Dedicated GPU memory is not in either field, and `gpuMemory()` returns null on Windows: DXGI `QueryVideoMemoryInfo` is not read yet. The RTX 3050 run above peaked at 505 to 511 MiB of per-adapter `\GPU Process Memory`, which includes the app window's own.

**Linux GPU memory.** On desktop Linux, GPU memory is in neither field. On an integrated GPU it is still system RAM that the snapshot does not show: FunctionGemma 270M cost 700 to 835 MiB of Intel `drm-resident-system0` (from `/proc/self/fdinfo`) while its device mappings were 0 MiB. `gpuMemory()` returns null on Linux.

**GPU backends.** On a GPU backend on Adreno, the driver's buffers are mapped through `/dev/kgsl-3d0` and are mostly clean pages, so they are counted here too. In one run on the vivo 1933 (Adreno 616, kernel 4.9) a Gemma 4 E2B GPU load raised that mapping from 6 to 981 MiB (988 after one prompt), matching `dumpsys meminfo`'s Gfx dev (989 MiB); about 115 MiB of it was dirty, which is in `anonymousBytes`, and all file mappings together (model, libraries, others) were about 260 MiB (Pss). With a GPU backend `fileBackedBytes` is therefore not a model-file figure: compare with a run of the same app on CPU, or subtract `GpuMemoryReading.inFileBackedBytes` from `FlutterEdgeAiDiagnostics.gpuMemory()` (experimental, see below). One device and one run each; other GPU drivers (Mali) were not measured.

The baseline includes every clean mapped file the process has touched. Take a reading before loading and subtract, while interpreting both counters together. Singly mapped dirty file pages count in `Private_Dirty` (inside `anonymousBytes`); `Shared_Dirty` is in neither field. Clean pages and dirty pages do not form a complete split of anonymous and file-backed memory.

`fileBackedBytes` is null on iOS and macOS because this package does not read a corresponding value there yet. `TASK_VM_INFO` has an `external` field; evaluating it is a follow-up.

The platforms enforce memory differently, and the numbers reflect it:

- **iOS** gives each app a hard limit. `anonymousBytes` is what that limit is measured against, and `availableBytes` is how far away it is.
- **Android** has no per-app limit. lmkd kills based on device-wide pressure and process priority, and starts well before `MemAvailable` reaches zero. There, `anonymousBytes` is what the app holds, not a kill threshold.
- **Linux** has no per-app limit either; the OOM killer acts on machine-wide (or cgroup) pressure. `anonymousBytes` is what the app holds, not a kill threshold.
- **Windows** has no per-app limit like jetsam's either. `anonymousBytes` is what the app has committed, not a kill threshold, and `availableBytes` is machine-wide.

## Null versus an exception

- **A null field** means the value is not reported on this platform or OS version:
  - `anonymousBytes` and `fileBackedBytes` on an Android or Linux kernel without `/proc/self/smaps_rollup`. Mainline Linux added it in 4.14, but vendor kernels may backport it;
  - `fileBackedBytes` on iOS and macOS: the package does not read a corresponding value yet, and on a Windows that does not fill `PrivateWorkingSetSize` (the extended struct; not tested on one);
  - `anonymousPeakBytes` on Android and Linux, which keep no anonymous-only peak, and on an iOS or macOS version whose `task_info` reply predates the field;
  - `gpuMemory()` returns null when the device has no reader: always on iOS, macOS, Linux and Windows, and on an Android phone with no `/dev/kgsl-3d0` (a Mali GPU, for one; not measured; see GPU memory). On an Adreno phone it returns zeros before the process has used the GPU;
  - `availableBytes` on macOS, which has no per-app limit;
  - `availableBytes` on iOS when the call returns 0. Apple returns 0 both when no limit applies (the simulator) and when the limit is already exceeded, and the two cannot be told apart.
- **`MemoryReadException`** means the value should exist and the read failed: a kernel error, a permission or I/O error, or a file that lacks a field it always carries. On Linux this includes a confined app (a Snap under AppArmor) that is refused `/proc/self/smaps_rollup`; on Windows, a `K32GetProcessMemoryInfo` that fails with every struct size, or a reply that lacks a field every Windows writes.
- **`UnsupportedError`** is thrown by `memorySnapshot()` and `gpuMemory()` off Android, iOS, macOS, Linux and Windows, rather than returning empty values.

## Platforms

Android, iOS, macOS, Linux and Windows. Everything is read through `dart:io` and `dart:ffi`, so the package has no Kotlin, Swift, Gradle, podspec or CMake, and no dependency on `flutter_edge_ai` itself: it measures the process, whichever engine runs in it.

The Linux host test writes and flushes a 64 MiB file on the checkout's filesystem, then maps and reads it: `fileBackedBytes` rises without a comparable rise in `anonymousBytes`. The Windows tests decode hand-built replies on every host (the sentinel that tells a field the OS did not write from a small value, the fallback from the extended struct to the basic one, a failed call), and on a `windows-latest` runner a host group reads `kernel32` and checks that commit follows an allocation that is not touched. The example app's integration test asserts the field is positive on Android and Linux, null on iOS and macOS, and positive or null on Windows.

With version 0.2.2 on vivo 1933 (Android 11, kernel 4.9), the opt-in Gemma 4 E2B test measured `fileBackedBytes` in MiB:

| Active backend | Before load | After load | After one prompt | After close |
|---|---:|---:|---:|---:|
| CPU | 103.6 | 800.5 | 1043.2 | 102.3 |
| GPU | 102.3 | 1390.3 | 1413.2 | 116.1 |

At load and after the prompt, `Private_Clean + Shared_Clean − (Rss − Anonymous)` was negative on both backends. This gives no positive lower bound for clean anonymous pages in this run; it does not establish their absence. Values depend on the device and what pages were already resident.

Earlier 256 MiB allocation checks for `anonymousBytes` ran on:

- Android: vivo 1933 (Android 11), Pixel 8a (Android 15) and Galaxy A34 (Android 16);
- iOS: iPhone 17 Pro simulator (iOS 26.5).

## GPU memory (experimental)

`FlutterEdgeAiDiagnostics.gpuMemory()` returns a `GpuMemoryReading`, or null when there is no reader for this device. It is a separate call, not a `MemorySnapshot` field, because it costs more and may change.

| Field | Meaning |
|---|---|
| `inAnonymousBytes` | `Private_Dirty` of the process's `kgsl-3d0` mappings: already in `anonymousBytes` |
| `inFileBackedBytes` | `Private_Clean + Shared_Clean` of the same mappings: already in `fileBackedBytes`; subtract it to get the non-GPU file-backed memory |
| `outsideSnapshotBytes` | GPU memory held for the process without a mapping in it. Always null in this version: the per-process counters under `/sys/class/kgsl` are closed to an app on the two devices tried (a vivo 1933 and a Galaxy S26+), and `page_alloc` there counts the whole device |

- **What it covers.** Only the Adreno memory that is mapped into the process. On a vivo 1933 with FunctionGemma 270M on the GPU, `dumpsys meminfo` listed Gfx dev 363,080 kB, GL mtrack 365,960 kB and Graphics 749,592 kB, and the reading was 363,080 kB (340,736 dirty + 22,344 clean): about half of Graphics. A leak in GPU buffers the process never maps would not show here. Whether GL mtrack counts the same pages again was not determined.
- **When it is null.** The device has no reader: iOS, macOS, Linux and Windows always (Windows not read yet: DXGI `QueryVideoMemoryInfo` is the follow-up; iOS and macOS not read yet: `task_vm_info.ledger_tag_graphics_footprint` and `MTLDevice.currentAllocatedSize` exist, and Apple's GPU memory is already inside `phys_footprint`), and an Android phone with no `/dev/kgsl-3d0` (a Mali GPU, for one; `File('/dev/mali0').existsSync()` is false on the Adreno phones tried, a Mali phone was not tried). On an Adreno phone it is never null: a process that has not used the GPU yet (a headless engine, a background isolate, a read before the first frame) gets zeros, because `File('/dev/kgsl-3d0').existsSync()` is true from an app on a vivo 1933 and a Galaxy S26+ (`typeSync` and `statSync` say not found, so the code uses `existsSync`). Off Android, iOS, macOS, Linux and Windows it throws `UnsupportedError`; on Linux and Windows it returns null and the kgsl reader is never enabled.
- **How it is read.** `/proc/self/smaps`, matching `kgsl-3d0` anywhere in a mapping's name, as AOSP's libmeminfo does, so the `/kgsl-3d0` name that some kernels may use is covered (AOSP added it for kernel 6.6); a 6.12 Galaxy S26+ still uses `/dev/kgsl-3d0`, and no device with the shorter name was tried. The file is read as Latin-1, and malformed input, or a missing `smaps` (it exists on every Android kernel), throws `MemoryReadException` instead of giving a number.
- **Cost.** The kernel builds per-mapping `smaps` mapping by mapping while holding the process's `mmap_lock`, so it can stall the process's other `mmap` calls, on every kernel; do not call it per frame or per token. On the vivo it took about 0.2 s before a model was loaded and 0.3 to 0.4 s with one on the GPU (3,300 and 4,200 mappings, screen on). The file is read asynchronously, but decoding and scanning it run on the calling isolate.
- **A reading, not a delta.** It includes what the app's own rendering maps (about 6 MiB in a Flutter app). Take one before loading a model and subtract.
- **Subtracting it from a snapshot is approximate.** `fileBackedBytes` and `inFileBackedBytes` come from two reads of `/proc` a fraction of a second apart, and a GPU mapping grows by hundreds of MiB while a model loads (6 to 981 MiB for Gemma 4 E2B), so the difference can come out negative. Take both back to back while the app is idle, and treat the difference as approximate; the same holds for `inAnonymousBytes` and `anonymousBytes`. `Shared_Dirty` pages of the GPU mappings are in neither.

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package does not depend on `flutter_edge_ai`, so they come with it only when your app depends on `flutter_edge_ai` too. One of them, `flutter-edge-ai-diagnostics`, covers what each field means per platform, null versus `MemoryReadException`, and how to measure what a model costs.

## Roadmap

`gpuMemory()` is experimental and Adreno-only; a Mali reading, GPU memory on iOS, macOS, Linux and Windows (DXGI `QueryVideoMemoryInfo`), and `fileBackedBytes` on iOS from `TASK_VM_INFO.external`, are not done.
