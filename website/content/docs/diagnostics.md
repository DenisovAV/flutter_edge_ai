---
title: Memory Diagnostics
description: "Read process memory diagnostics on Android, iOS and macOS: footprint, resident clean pages and available memory, with flutter_edge_ai_diagnostics."
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_diagnostics` helps explain what an on-device model costs in
memory. It reads process memory counters and available memory from the OS on
**Android, iOS and macOS**, returning a `MemorySnapshot`. It has no native code and no
dependency on `flutter_edge_ai` — it measures the process, whichever engine runs
in it.

## Why not the memory number your profiler shows?

The first "memory used" number people reach for is usually **RSS**, the
*resident set size* — the `RES` column in `top`, `ps -o rss`: every page of the
app that is sitting in physical RAM right now. It is the obvious thing to look
at when a model makes an app heavy, and for a model it answers the wrong
question. (Xcode's memory gauge is the exception: on iOS it already shows the
footprint this package reports.)

RSS adds together two kinds of memory that the OS treats in opposite ways.

**File-backed pages the OS can take back.** LiteRT-LM maps a `.litertlm` file
into memory (`mmap`) instead of reading it into a buffer. Pages of the weights
that the model has touched count in RSS, but they are still just a view of the
file on disk. When memory gets tight the OS drops them and reads them from the
file again later. They are reclaimable, but not free: a model reads weights
on every token, so dropped pages must be read back from storage. Android lmkd
can kill under refault thrashing; the kernel does not necessarily discard every
file page before reclaiming anonymous memory.

**Anonymous memory without a reloadable model file.** Everything the app built itself
and that exists nowhere else: the heap, a copy of the weights in a buffer or on
the GPU, the KV cache, activations. The OS can compress or swap anonymous pages,
but it cannot simply discard live contents and reload them from the model file.

Mapped weights and weights copied into the heap can show similar RSS while
producing different footprint readings. A mapped model still needs a working
set that fits the device to avoid repeated storage reads. On iOS, jetsam enforces
its per-app limit on the footprint rather than RSS.

So this package does not report RSS. It reports:

- **`anonymousBytes`** — the platform's footprint or `Private_Dirty + SwapPss`;
- **`fileBackedBytes`** (Android) — resident clean pages: mapped files on a CPU backend, and GPU driver buffers too on some GPU backends. Not read on iOS or macOS yet, so null there;
- **`anonymousPeakBytes`** (iOS and macOS) — the highest footprint since the process started. Null on Android;
- **`availableBytes`** — headroom on iOS, a device-wide estimate on Android, null on macOS.

Take readings before loading, after loading, and during generation. Their
changes help explain the model's memory cost, with the limits below.

## Setup

```
dependencies:
  flutter_edge_ai_diagnostics: ^0.3.0
```

This page describes 0.3.0 (coming soon to pub.dev), which adds macOS and
`anonymousPeakBytes`; 0.2.2, the current release, reads Android and iOS without
the peak.

If only `test/` or `integration_test/` uses it, put it under `dev_dependencies`
instead. Neither section strips anything from a release build: what keeps the
package out is not importing it from `lib/`.

```dart
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';

if (FlutterEdgeAiDiagnostics.isSupported) {
  final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
  print(snapshot.anonymousBytes);
  print(snapshot.availableBytes);
}
```

## What each field means

| Field | iOS and macOS | Android |
|---|---|---|
| `anonymousBytes` | `phys_footprint` from `task_info(TASK_VM_INFO)`: on iOS the value jetsam enforces, including IOKit/GPU (Metal) allocations and compressed memory; on macOS the figure Activity Monitor calls "Memory", with no kill limit behind it | `Private_Dirty + SwapPss` from `/proc/self/smaps_rollup`. GPU memory (KGSL, Mali, dmabuf) is mostly outside it; on Adreno most of it is in `fileBackedBytes` instead |
| `fileBackedBytes` | null: not read on iOS or macOS yet | `Private_Clean + Shared_Clean` from `/proc/self/smaps_rollup`: resident clean pages (mapped files on a CPU backend, plus GPU driver buffers on some GPU backends, see below). Counts shared pages in full |
| `anonymousPeakBytes` | `ledger_phys_footprint_peak` from the same `task_info` reply: the highest `phys_footprint` since the process started (a lifetime mark, never reset) | null: the kernel keeps no anonymous-only peak |
| `availableBytes` | iOS: `os_proc_available_memory()`, headroom before **this app** hits its limit; null on macOS, which has no per-app limit | `MemAvailable` from `/proc/meminfo`: available on **the whole device**, an optimistic upper bound |

On Android, clean does not mean exclusively file-backed. `Private_Clean` can include anonymous pages read back from zram and not written since, and `MADV_FREE` pages. On zram's skip-swapcache path, a page can lose its swap slot and leave `SwapPss`. Loading a model under memory pressure can therefore move cold heap memory from `anonymousBytes` into `fileBackedBytes`; the delta is not an exact count of mapped weights.

**GPU backends.** On a GPU backend on Adreno, the driver's buffers are mapped through `/dev/kgsl-3d0` and are mostly clean pages, so they are counted here too. In one run on the vivo 1933 (Adreno 616, kernel 4.9) a Gemma 4 E2B GPU load raised that mapping from 6 to 981 MiB (988 after one prompt), matching `dumpsys meminfo`'s Gfx dev (989 MiB); about 115 MiB of it was dirty, which is in `anonymousBytes`, and all file mappings together (model, libraries, others) were about 260 MiB (Pss). With a GPU backend `fileBackedBytes` is therefore not a model-file figure: compare with a run of the same app on CPU, or subtract `GpuMemoryReading.inFileBackedBytes` from `FlutterEdgeAiDiagnostics.gpuMemory()` (experimental, see below). One device and one run each; other GPU drivers (Mali) were not measured.

The baseline includes every clean mapped file the process has touched. Take a reading before loading and subtract, while interpreting both counters together. Singly mapped dirty file pages count in `Private_Dirty` (inside `anonymousBytes`); `Shared_Dirty` is in neither field. Clean pages and dirty pages do not form a complete split of anonymous and file-backed memory.

`fileBackedBytes` is null on iOS and macOS because this package does not read a corresponding value there yet. `TASK_VM_INFO` has an `external` field; evaluating it is a follow-up.

The platforms enforce memory differently, and the numbers reflect it:

- **iOS** gives each app a hard limit. `anonymousBytes` is what that limit is
  measured against, and `availableBytes` is how far away it is.
- **Android** has no per-app limit. lmkd kills based on device-wide pressure and
  process priority, and starts well before `MemAvailable` reaches zero. There,
  `anonymousBytes` is what the app holds, not a kill threshold — and a model on
  the GPU backend looks cheaper than it is, because GPU memory is mostly not in
  it.

## Measure what a model costs

Take a snapshot before loading, after loading, and a few times during
generation. On Android, neither process counter alone measures the model's
entire memory cost.

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';

Future<InferenceModel> loadAndMeasure() async {
  if (!FlutterEdgeAiDiagnostics.isSupported) {
    return FlutterEdgeAi.getActiveModel(maxTokens: 1024);
  }
  final before = await FlutterEdgeAiDiagnostics.memorySnapshot();
  final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
  final loaded = await FlutterEdgeAiDiagnostics.memorySnapshot();

  if ((before.anonymousBytes, loaded.anonymousBytes)
      case (final int from, final int to)) {
    debugPrint('model load: anonymousBytes delta ${to - from} bytes');
  }
  debugPrint('still available: ${loaded.availableBytes}');
  return model;
}
```

On Android a snapshot walks the process's page tables: the reads are
asynchronous, so they do not block the isolate, but one costs about 150 ms on a
low-end device (and before Linux 5.10 it stalls the process's mmap calls). On iOS
it is a microsecond Mach call. Either way, sample during generation on a timer
(at most once a second) rather than every so many chunks, and never on every
frame.

On iOS, compare what a model needs with `availableBytes` before loading it: if
it needs more than the headroom, jetsam kills the app during load. The
**Increased Memory Limit** entitlement raises that limit; **Extended Virtual
Addressing** does not add headroom, it gives the app more address space to map
a large model. Large models need both — see
[Installation → iOS](/docs/installation#ios). On Android
there is no per-app number to compare against: measure on the smallest device
you support and treat `availableBytes` as a best case.

## Null versus an exception

- **A null field** means the value is not reported on this platform or OS version:
  - `anonymousBytes` and `fileBackedBytes` on an Android kernel without
    `/proc/self/smaps_rollup`. Mainline Linux added it in 4.14, but vendor
    kernels may backport it;
  - `fileBackedBytes` on iOS and macOS: the package does not read a corresponding value yet;
  - `anonymousPeakBytes` on Android, always (the kernel keeps no anonymous-only
    peak), and on an iOS or macOS version whose `task_info` reply predates the
    field;
  - `availableBytes` on macOS, always: it has no per-app limit;
  - `availableBytes` on iOS when the call returns 0. Apple returns 0 both when
    no limit applies (the simulator) and when the limit is already exceeded, and
    the two cannot be told apart.
- **`MemoryReadException`** means the value should exist and the read failed: a
  kernel error, a permission or I/O error, or a file that lacks a field it
  always carries. Do not turn it into zeros.
- **`UnsupportedError`** is thrown by `memorySnapshot()` off Android, iOS and macOS,
  rather than returning empty values. Check `FlutterEdgeAiDiagnostics.isSupported`
  first.

## Platforms

Android, iOS and macOS. Everything is read through `dart:io` and `dart:ffi`, so the
package has no Kotlin, Swift, Gradle or podspec.

Verified by writing 256 MiB and checking that `anonymousBytes` moves by that
amount: vivo 1933 (Android 11), Pixel 8a (Android 15), Galaxy A34 (Android 16)
and the iPhone 17 Pro simulator (iOS 26.5). These are earlier allocation checks.
The Linux host test writes and flushes a 64 MiB file on the checkout's
filesystem, then maps and reads it: `fileBackedBytes` rises without a comparable
rise in `anonymousBytes`. The Android integration test checks the field is
positive.

With version 0.2.2 on vivo 1933 (Android 11, kernel 4.9), the opt-in Gemma 4 E2B test measured `fileBackedBytes` in MiB:

| Active backend | Before load | After load | After one prompt | After close |
|---|---:|---:|---:|---:|
| CPU | 103.6 | 800.5 | 1043.2 | 102.3 |
| GPU | 102.3 | 1390.3 | 1413.2 | 116.1 |

At load and after the prompt, `Private_Clean + Shared_Clean − (Rss − Anonymous)` was negative on both backends. This gives no positive lower bound for clean anonymous pages in this run; it does not establish their absence. Values depend on the device and what pages were already resident.

`gpuMemory()` is experimental and Adreno-only; a Mali reading, GPU memory on iOS and macOS, and `fileBackedBytes` on iOS from `TASK_VM_INFO.external`, are not done.

## GPU memory (experimental)

`FlutterEdgeAiDiagnostics.gpuMemory()` returns a `GpuMemoryReading`, or null when there is no reader for the device. It is a separate call, not a `MemorySnapshot` field, because it costs more and may change.

| Field | Meaning |
|---|---|
| `inAnonymousBytes` | `Private_Dirty` of the process's `kgsl-3d0` mappings: already in `anonymousBytes` |
| `inFileBackedBytes` | `Private_Clean + Shared_Clean` of the same mappings: already in `fileBackedBytes`; subtract it to get the non-GPU file-backed memory |
| `outsideSnapshotBytes` | GPU memory held for the process without a mapping in it. Always null in this version: the kernel counters for it are under `/sys/class/kgsl`, which an app could not read on the one device tried |

- **What it covers.** Only the Adreno memory that is mapped into the process. On a vivo 1933 with FunctionGemma 270M on the GPU, `dumpsys meminfo` listed Gfx dev 363,080 kB, GL mtrack 365,960 kB and Graphics 749,592 kB, and the reading was 363,080 kB (340,736 dirty + 22,344 clean): about half of Graphics. A leak in GPU buffers the process never maps would not show here. Whether GL mtrack counts the same pages again was not determined.
- **Platforms.** Android with an Adreno GPU. Null on an Android process that maps no `kgsl-3d0` (a Mali GPU, for one; not measured), and on iOS and macOS, where it is not read yet (`task_vm_info.ledger_tag_graphics_footprint` and `MTLDevice.currentAllocatedSize` exist; Apple's GPU memory is already inside `phys_footprint`). Elsewhere it throws `UnsupportedError`.
- **How it is read.** `/proc/self/smaps`, matching `kgsl-3d0` anywhere in a mapping's name, as AOSP's libmeminfo does, so the `/kgsl-3d0` name kernels from 6.6 use is covered (not tried on such a kernel). The file is read as Latin-1, and malformed input throws `MemoryReadException` instead of giving a number.
- **Cost.** The kernel builds per-mapping `smaps` mapping by mapping and holds the process's mmap lock while it does, on every kernel. On the vivo it took about 0.2 s before a model was loaded and 0.3 to 0.4 s with one on the GPU (3,300 and 4,200 mappings, screen on). The read is asynchronous but the scan runs on the calling isolate. Call it at a few points, not per frame or per token.
- **A reading, not a delta.** It includes what the app's own rendering maps (about 6 MiB in a Flutter app). Take one before loading a model and subtract.

## Teach your AI assistant

The `flutter-edge-ai-diagnostics` agent skill ships inside `flutter_edge_ai`. Install
it with the others — see [Package Skills](/docs/package-skills).
