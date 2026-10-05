---
name: flutter-gemma-diagnostics
description: Use when measuring how much memory an on-device model costs with flutter_gemma_diagnostics — MemorySnapshot, anonymousBytes, availableBytes — on Android or iOS, when an app is killed for memory (iOS jetsam, Android lmkd) while loading or running a model, when choosing between model sizes for a device, or when RSS numbers do not add up. Also use when FlutterGemmaDiagnostics.memorySnapshot() throws MemoryReadException or UnsupportedError, or a snapshot field is null. For running the model itself, use flutter-gemma-inference.
---

# Memory diagnostics

## Rules

1. Depend on `flutter_gemma_diagnostics` and import it. It does not depend on `flutter_gemma` and reads the process, whichever engine runs in it.
2. Android and iOS only. Check `FlutterGemmaDiagnostics.isSupported` first: elsewhere `memorySnapshot()` throws `UnsupportedError` instead of returning empty values.
3. `null` and an exception mean different things. A null field is a value this platform does not have; `MemoryReadException` is a read that should have worked and failed. Do not catch the exception and carry on with zeros.
4. The two fields answer different questions per platform. On iOS `anonymousBytes` is `phys_footprint`, the number jetsam kills on, and `availableBytes` is this app's headroom before that limit. On Android there is no per-app limit: `availableBytes` is MemAvailable for the whole device, an optimistic upper bound, and lmkd kills well before it reaches zero. Never use it as an Android kill threshold.
5. On Android, GPU memory (KGSL, Mali, dmabuf) is mostly outside `anonymousBytes`. A model running on the GPU backend looks cheaper there than it is.
6. Weights read from an mmapped model file are clean file pages and are not counted; the same weights copied into the heap are. On iOS that difference, not RSS, is what decides whether the app survives.
7. A snapshot reads OS files or makes a kernel call on the calling isolate. Take one at a few points — before loading, after loading, during generation — not on every frame or token.
8. A pubspec section strips nothing from a release build. Put the package under `dev_dependencies` only when nothing in `lib/` imports it.

## Measure what a model costs

```sh
flutter pub add flutter_gemma flutter_gemma_litertlm flutter_gemma_diagnostics
```

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_diagnostics/flutter_gemma_diagnostics.dart';

int? grew(MemorySnapshot before, MemorySnapshot after) {
  if ((before.anonymousBytes, after.anonymousBytes)
      case (final int from, final int to)) {
    return to - from;
  }
  return null; // the platform does not report it
}

Future<InferenceModel> loadAndMeasure() async {
  if (!FlutterGemmaDiagnostics.isSupported) {
    return FlutterGemma.getActiveModel(maxTokens: 1024);
  }
  final before = await FlutterGemmaDiagnostics.memorySnapshot();
  final model = await FlutterGemma.getActiveModel(maxTokens: 1024);
  final loaded = await FlutterGemmaDiagnostics.memorySnapshot();
  debugPrint('model load: ${grew(before, loaded)} bytes the OS cannot reclaim, '
      '${loaded.availableBytes} still available');
  return model;
}
```

Sample during generation every so many chunks, not on each one:

```dart
Future<String> answerAndMeasure(InferenceModelSession session) async {
  final reply = StringBuffer();
  var chunks = 0;
  MemorySnapshot? peak;
  await for (final chunk in session.getResponseAsync()) {
    reply.write(chunk);
    if (++chunks % 32 == 0 && FlutterGemmaDiagnostics.isSupported) {
      final now = await FlutterGemmaDiagnostics.memorySnapshot();
      if ((now.anonymousBytes ?? 0) > (peak?.anonymousBytes ?? 0)) peak = now;
    }
  }
  debugPrint('highest sampled footprint: ${peak?.anonymousBytes}');
  return reply.toString();
}
```

## Null versus an exception

```dart
Future<void> report() async {
  try {
    final s = await FlutterGemmaDiagnostics.memorySnapshot();
    debugPrint('anonymous ${s.anonymousBytes ?? 'not reported here'}, '
        'available ${s.availableBytes ?? 'not reported here'}');
  } on MemoryReadException catch (e) {
    // The OS should have answered: a kernel, permission or I/O error.
    debugPrint('memory read failed: $e');
    rethrow;
  }
}
```

A field is null in exactly two cases:

- `anonymousBytes` on an Android kernel without `/proc/self/smaps_rollup` (mainline Linux added it in 4.14);
- `availableBytes` on iOS when `os_proc_available_memory()` returns 0. Apple returns 0 both on the simulator, where no limit applies, and when the limit is already exceeded; the two cannot be told apart.

## Choosing a model for the device

On iOS, compare the growth you measured for a model with `availableBytes` before loading it: if the model needs more than the headroom, jetsam kills the app during load. Large models also need two entitlements (see flutter-gemma-inference): **Increased Memory Limit** raises the jetsam limit, so `availableBytes` grows; **Extended Virtual Addressing** gives the app more address space to map the model and does not add headroom.

On Android there is no such number to compare against. Measure on the smallest device you support, and treat `availableBytes` as a best case.
