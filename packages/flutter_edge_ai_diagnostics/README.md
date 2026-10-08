# flutter_edge_ai_diagnostics

> **Renamed from [`flutter_gemma_diagnostics`](https://pub.dev/packages/flutter_gemma_diagnostics).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_diagnostics/` imports; nothing on the device
> changes. `FlutterGemmaDiagnostics` is now `FlutterEdgeAiDiagnostics` (0.2.0 drops the old
> name); `dart fix --apply` renames it. See the [migration guide](https://flutteredge.ai/docs/migration).

Opt-in memory diagnostics for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai) apps, read from the OS on Android and iOS.

## Why not the memory number your profiler shows?

The first "memory used" number people reach for is usually **RSS**, the *resident set size* — the `RES` column in `top`, `ps -o rss`: every page of the app that is sitting in physical RAM right now. For a model it answers the wrong question, because it adds together two kinds of memory that the OS treats in opposite ways. (Xcode's memory gauge is the exception: on iOS it already shows the footprint this package reports.)

**File-backed pages the OS can take back.** LiteRT-LM maps a `.litertlm` file into memory (`mmap`) instead of reading it into a buffer. Pages of the weights the model has touched count in RSS, but they are still just a view of the file on disk: when memory gets tight the OS drops them and reads them again later. They cost the app little, and nothing is killed for holding them.

**Anonymous memory the OS cannot take back.** Everything the app built itself and that exists nowhere else: the heap, a copy of the weights in a buffer or on the GPU, the KV cache, activations. There is no file to reload it from, so the OS can only reclaim it by killing the app.

In RSS the two look the same. A model mapped from its file can show a large RSS and be cheap; the same weights copied into memory show a similar RSS and are expensive. On iOS the difference decides the outcome: jetsam kills the app on its anonymous footprint, not on RSS.

So this package does not report RSS. It reports `anonymousBytes`, the memory the OS cannot take back, and `availableBytes`, how much is still available before the OS acts. To know what a model costs, take `anonymousBytes` before and after loading it and subtract.

## Usage

```yaml
dependencies:
  flutter_edge_ai_diagnostics: ^0.2.1
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

Take a snapshot before loading a model, after loading it, and during generation. The difference in `anonymousBytes` is what the model costs in memory the OS cannot reclaim.

## What each field means

| Field | iOS | Android |
|---|---|---|
| `anonymousBytes` | `phys_footprint` from `task_info(TASK_VM_INFO)`: the value jetsam enforces, including IOKit/GPU (Metal) allocations and compressed memory | `Private_Dirty + SwapPss` from `/proc/self/smaps_rollup`. GPU memory (KGSL, Mali, dmabuf) is mostly outside it |
| `availableBytes` | `os_proc_available_memory()`: headroom before **this app** hits its limit | `MemAvailable` from `/proc/meminfo`: available on **the whole device**, an optimistic upper bound |

The platforms enforce memory differently, and the numbers reflect it:

- **iOS** gives each app a hard limit. `anonymousBytes` is what that limit is measured against, and `availableBytes` is how far away it is.
- **Android** has no per-app limit. lmkd kills based on device-wide pressure and process priority, and starts well before `MemAvailable` reaches zero. There, `anonymousBytes` is what the app holds, not a kill threshold.

## Null versus an exception

- **A null field** means the value does not exist on this platform or OS version:
  - `anonymousBytes` on an Android kernel without `/proc/self/smaps_rollup` (mainline Linux added it in 4.14);
  - `availableBytes` on iOS when the call returns 0. Apple returns 0 both when no limit applies (the simulator) and when the limit is already exceeded, and the two cannot be told apart.
- **`MemoryReadException`** means the value should exist and the read failed: a kernel error, a permission or I/O error, or a file that lacks a field it always carries.
- **`UnsupportedError`** is thrown by `memorySnapshot()` off Android and iOS, rather than returning empty values.

## Platforms

Android and iOS. Everything is read through `dart:io` and `dart:ffi`, so the package has no Kotlin, Swift, Gradle or podspec, and no dependency on `flutter_edge_ai` itself: it measures the process, whichever engine runs in it.

Verified by writing 256 MiB and checking that `anonymousBytes` moves by that amount:

- Android: vivo 1933 (Android 11), Pixel 8a (Android 15) and Galaxy A34 (Android 16);
- iOS: iPhone 17 Pro simulator (iOS 26.5).

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package does not depend on `flutter_edge_ai`, so they come with it only when your app depends on `flutter_edge_ai` too. One of them, `flutter-edge-ai-diagnostics`, covers what each field means per platform, null versus `MemoryReadException`, and how to measure what a model costs.

## Roadmap

Planned in follow-up releases: `anonymousPeakBytes` (iOS), `anonymousBytes` on macOS, `fileBackedBytes` (Android), and an experimental `gpuBytes`.
