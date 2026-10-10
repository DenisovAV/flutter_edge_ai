---
title: Memory Diagnostics
description: "Read process memory diagnostics on Android and iOS: footprint, resident clean pages and available memory, with flutter_edge_ai_diagnostics."
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_diagnostics` helps explain what an on-device model costs in
memory. It reads process memory counters and available memory from the OS on
**Android and iOS**, returning a `MemorySnapshot`. It has no native code and no
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
- **`fileBackedBytes`** (Android) — resident clean pages, mostly mapped files. Not read on iOS yet, so null there;
- **`availableBytes`** — headroom on iOS, a device-wide estimate on Android.

Take readings before loading, after loading, and during generation. Their
changes help explain the model's memory cost, with the limits below.

## Setup

```
dependencies:
  flutter_edge_ai_diagnostics: ^0.2.2
```

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

| Field | iOS | Android |
|---|---|---|
| `anonymousBytes` | `phys_footprint` from `task_info(TASK_VM_INFO)`: the value jetsam enforces, including IOKit/GPU (Metal) allocations and compressed memory | `Private_Dirty + SwapPss` from `/proc/self/smaps_rollup`. GPU memory (KGSL, Mali, dmabuf) is mostly outside it |
| `fileBackedBytes` | null: not read on iOS yet | `Private_Clean + Shared_Clean` from `/proc/self/smaps_rollup`: resident clean pages, mostly mapped files. Counts shared pages in full |
| `availableBytes` | `os_proc_available_memory()`: headroom before **this app** hits its limit | `MemAvailable` from `/proc/meminfo`: available on **the whole device**, an optimistic upper bound |

On Android, clean does not mean exclusively file-backed. `Private_Clean` can include anonymous pages read back from zram and not written since, and `MADV_FREE` pages. On zram's skip-swapcache path, a page can lose its swap slot and leave `SwapPss`. Loading a model under memory pressure can therefore move cold heap memory from `anonymousBytes` into `fileBackedBytes`; the delta is not an exact count of mapped weights.

The baseline includes every clean mapped file the process has touched. Take a reading before loading and subtract, while interpreting both counters together. Singly mapped dirty file pages count in `Private_Dirty` (inside `anonymousBytes`); `Shared_Dirty` is in neither field. Clean pages and dirty pages do not form a complete split of anonymous and file-backed memory.

`fileBackedBytes` is null on iOS because this package does not read a corresponding value there yet. `TASK_VM_INFO` has an `external` field; evaluating it is a follow-up.

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
  - `fileBackedBytes` on iOS: the package does not read a corresponding value yet;
  - `availableBytes` on iOS when the call returns 0. Apple returns 0 both when
    no limit applies (the simulator) and when the limit is already exceeded, and
    the two cannot be told apart.
- **`MemoryReadException`** means the value should exist and the read failed: a
  kernel error, a permission or I/O error, or a file that lacks a field it
  always carries. Do not turn it into zeros.
- **`UnsupportedError`** is thrown by `memorySnapshot()` off Android and iOS,
  rather than returning empty values. Check `FlutterEdgeAiDiagnostics.isSupported`
  first.

## Platforms

Android and iOS. Everything is read through `dart:io` and `dart:ffi`, so the
package has no Kotlin, Swift, Gradle or podspec.

Verified by writing 256 MiB and checking that `anonymousBytes` moves by that
amount: vivo 1933 (Android 11), Pixel 8a (Android 15), Galaxy A34 (Android 16)
and the iPhone 17 Pro simulator (iOS 26.5). These are earlier allocation checks.
The Linux host test writes and flushes a 64 MiB file on the checkout's
filesystem, then maps and reads it: `fileBackedBytes` rises without a comparable
rise in `anonymousBytes`. The Android integration test checks the field is
positive; its iOS null assertion has not been run for this change.

With version 0.2.2 on vivo 1933 (Android 11, kernel 4.9), the opt-in Gemma 4 E2B test measured `fileBackedBytes` in MiB:

| Active backend | Before load | After load | After one prompt | After close |
|---|---:|---:|---:|---:|
| CPU | 103.6 | 800.5 | 1043.2 | 102.3 |
| GPU | 102.3 | 1390.3 | 1413.2 | 116.1 |

At load and after the prompt, `Private_Clean + Shared_Clean − (Rss − Anonymous)` was negative on both backends. This gives no positive lower bound for clean anonymous pages in this run; it does not establish their absence. Values depend on the device and what pages were already resident.

Planned: `anonymousPeakBytes` on iOS, `anonymousBytes` on macOS, and an
experimental `gpuBytes`.

## Teach your AI assistant

The `flutter-edge-ai-diagnostics` agent skill ships inside `flutter_edge_ai`. Install
it with the others — see [Package Skills](/docs/package-skills).
