---
title: Memory Diagnostics
description: Measure what an on-device model costs in memory the OS cannot reclaim — the anonymous footprint and the memory still available, read from the OS on Android and iOS with flutter_edge_ai_diagnostics.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_diagnostics` answers one question: how much memory does this
model cost, in the terms the OS kills on? It reads two numbers straight from the
OS on **Android and iOS** and returns them as a `MemorySnapshot`. It has no
native code and no dependency on `flutter_edge_ai` — it measures the process,
whichever engine runs in it.

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
file again later. They cost the app little, and nothing is killed for holding
them.

**Anonymous memory the OS cannot take back.** Everything the app built itself
and that exists nowhere else: the heap, a copy of the weights in a buffer or on
the GPU, the KV cache, activations. There is no file to reload it from, so the
OS can only reclaim it by killing the app.

In RSS the two look the same. A model mapped from its file can show a large RSS
and be cheap; the same weights copied into memory show a similar RSS and are
expensive. On iOS the difference decides the outcome: jetsam kills the app on
its anonymous footprint, not on RSS.

So this package does not report RSS. It reports:

- **`anonymousBytes`** — the memory the OS cannot take back, the part that
  matters;
- **`availableBytes`** — how much is still available before the OS acts.

To know what a model costs, take `anonymousBytes` before and after loading it
and subtract.

## Setup

```
dependencies:
  flutter_edge_ai_diagnostics: ^0.2.0
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
| `availableBytes` | `os_proc_available_memory()`: headroom before **this app** hits its limit | `MemAvailable` from `/proc/meminfo`: available on **the whole device**, an optimistic upper bound |

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
generation. The growth in `anonymousBytes` is what the model costs in memory the
OS cannot reclaim.

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
    debugPrint('model load: ${to - from} bytes the OS cannot reclaim');
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

- **A null field** means the value does not exist on this platform or OS version:
  - `anonymousBytes` on an Android kernel without `/proc/self/smaps_rollup`
    (mainline Linux added it in 4.14);
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
and the iPhone 17 Pro simulator (iOS 26.5).

Planned: `anonymousPeakBytes` on iOS, `anonymousBytes` on macOS,
`fileBackedBytes` on Android, and an experimental `gpuBytes`.

## Teach your AI assistant

The `flutter-edge-ai-diagnostics` agent skill ships inside `flutter_edge_ai`. Install
it with the others — see [Package Skills](/docs/package-skills).
