---
name: flutter-edge-ai-diagnostics
description: Use when measuring how much memory an on-device model costs with flutter_edge_ai_diagnostics — MemorySnapshot, anonymousBytes, fileBackedBytes, availableBytes — on Android or iOS, when an app is killed for memory (iOS jetsam, Android lmkd) while loading or running a model, when choosing between model sizes for a device, or when RSS numbers do not add up. Also use when FlutterEdgeAiDiagnostics.memorySnapshot() throws MemoryReadException or UnsupportedError, or a snapshot field is null. For running the model itself, use flutter-edge-ai-inference.
---

# Memory diagnostics

## Rules

1. Depend on `flutter_edge_ai_diagnostics` and import it. It does not depend on `flutter_edge_ai` and reads the process, whichever engine runs in it.
2. Android and iOS only. Check `FlutterEdgeAiDiagnostics.isSupported` first: elsewhere `memorySnapshot()` throws `UnsupportedError` instead of returning empty values.
3. `null` and an exception mean different things. A null field is a value this package does not report on this platform; `MemoryReadException` is a read that should have worked and failed. Do not catch the exception and carry on with zeros.
4. The fields answer different questions per platform. On iOS `anonymousBytes` is `phys_footprint`, the number jetsam kills on, and `availableBytes` is this app's headroom before that limit. On Android there is no per-app limit: `availableBytes` is MemAvailable for the whole device, an optimistic upper bound, and lmkd kills well before it reaches zero. Never use it as an Android kill threshold.
5. On Android, GPU memory (KGSL, Mali, dmabuf) is mostly outside `anonymousBytes`. A model running on the GPU backend looks cheaper there than it is.
6. On Android `fileBackedBytes` is `Private_Clean + Shared_Clean`: resident clean pages, mostly mapped files. It can also include clean anonymous pages, so a delta is not an exact count of model weights. Reclaimable file pages are not a kill threshold, but are not free: weights read on every token must be read back from storage if dropped, and lmkd can treat that refault thrashing as a reason to kill. iOS is null because the package does not read this value there yet.
7. A snapshot walks kernel state: on Android the `/proc` reads are asynchronous (they do not block the isolate) but cost about 150 ms on a low-end device, and before Linux 5.10 they stall the process's mmap calls; on iOS they are microsecond Mach calls. Take one at a few points — before loading, after loading, during generation — and never faster than about once a second, not on every frame or token.
8. A pubspec section strips nothing from a release build. Put the package under `dev_dependencies` only when nothing in `lib/` imports it.

## Interpret resident clean pages

The baseline includes every clean mapped file the process has touched. Take a reading before loading and subtract; shared pages count in full, not proportionally. Singly mapped dirty file pages are in Private_Dirty (inside `anonymousBytes`); Shared_Dirty is in neither field.

Clean anonymous pages can appear in Private_Clean, including pages read back from zram and not written since, and MADV_FREE pages. On zram's skip-swapcache path, pages can lose their swap slots and leave SwapPss. Under model-load pressure, cold heap memory can therefore move from `anonymousBytes` into `fileBackedBytes`. Interpret both counters together; neither alone measures all model memory or predicts an Android kill.

With version 0.2.2 on vivo 1933 (Android 11, kernel 4.9), Gemma 4 E2B `fileBackedBytes` in MiB was 103.6 → 800.5 → 1043.2 → 102.3 on CPU and 102.3 → 1390.3 → 1413.2 → 116.1 on GPU, measured before load, after load, after one prompt, and after close. The actual backend matched the request. `Private_Clean + Shared_Clean − (Rss − Anonymous)` was negative after load and after the prompt on both backends, so this run gave no positive lower bound for clean anonymous pages. It does not establish that none were present.

On iOS, TASK_VM_INFO has an `external` field; evaluating it is a follow-up. A null `fileBackedBytes` does not imply that iOS lacks such accounting.

## Measure what a model costs

```sh
flutter pub add flutter_edge_ai flutter_edge_ai_litertlm flutter_edge_ai_diagnostics
```

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';

int? grew(MemorySnapshot before, MemorySnapshot after) {
  if ((before.anonymousBytes, after.anonymousBytes)
      case (final int from, final int to)) {
    return to - from;
  }
  return null; // the platform does not report it
}

Future<InferenceModel> loadAndMeasure() async {
  if (!FlutterEdgeAiDiagnostics.isSupported) {
    return FlutterEdgeAi.getActiveModel(maxTokens: 1024);
  }
  final before = await FlutterEdgeAiDiagnostics.memorySnapshot();
  final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
  final loaded = await FlutterEdgeAiDiagnostics.memorySnapshot();
  debugPrint('model load: anonymousBytes delta ${grew(before, loaded)} bytes, '
      '${loaded.availableBytes} still available');
  return model;
}
```

Sample during generation at most once a second, not on each chunk:

```dart
Future<String> answerAndMeasure(InferenceModelSession session) async {
  final reply = StringBuffer();
  final sinceLast = Stopwatch()..start();
  MemorySnapshot? peak;
  await for (final chunk in session.getResponseAsync()) {
    reply.write(chunk);
    if (sinceLast.elapsed >= const Duration(seconds: 1) &&
        FlutterEdgeAiDiagnostics.isSupported) {
      sinceLast.reset();
      final now = await FlutterEdgeAiDiagnostics.memorySnapshot();
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
    final s = await FlutterEdgeAiDiagnostics.memorySnapshot();
    debugPrint('anonymous ${s.anonymousBytes ?? 'not reported here'}, '
        'available ${s.availableBytes ?? 'not reported here'}');
  } on MemoryReadException catch (e) {
    // The OS should have answered: a kernel, permission or I/O error.
    debugPrint('memory read failed: $e');
    rethrow;
  }
}
```

A field is null in three cases:

- `anonymousBytes` and `fileBackedBytes` on an Android kernel without `/proc/self/smaps_rollup`. Mainline Linux added it in 4.14, but vendor kernels may backport it;
- `fileBackedBytes` on iOS: this package does not read a corresponding value yet;
- `availableBytes` on iOS when `os_proc_available_memory()` returns 0. Apple returns 0 both on the simulator, where no limit applies, and when the limit is already exceeded; the two cannot be told apart.

## Choosing a model for the device

On iOS, compare the growth you measured for a model with `availableBytes` before loading it: if the model needs more than the headroom, jetsam kills the app during load. Large models also need the memory entitlements listed in flutter-edge-ai-inference. Two of them change what you measure: **Increased Memory Limit** raises the jetsam limit, so `availableBytes` grows; **Extended Virtual Addressing** gives the app more address space to map the model and does not add headroom.

On Android there is no such number to compare against. Measure on the smallest device you support, and treat `availableBytes` as a best case. Include generation: a model whose weights repeatedly refault from storage can cause thrashing and contribute to an lmkd kill even though its file pages are reclaimable.
