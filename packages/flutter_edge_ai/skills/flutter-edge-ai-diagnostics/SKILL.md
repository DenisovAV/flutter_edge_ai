---
name: flutter-edge-ai-diagnostics
description: Use when measuring how much memory an on-device model costs with flutter_edge_ai_diagnostics — MemorySnapshot, anonymousBytes, anonymousPeakBytes, fileBackedBytes, availableBytes, GpuMemoryReading — on Android, iOS, macOS, Linux or Windows, when an app is killed for memory (iOS jetsam, Android lmkd) while loading or running a model, when choosing between model sizes for a device, or when RSS numbers do not add up. Also use when FlutterEdgeAiDiagnostics.memorySnapshot() throws MemoryReadException or UnsupportedError, or a snapshot field is null. For running the model itself, use flutter-edge-ai-inference.
---

# Memory diagnostics

## Rules

1. Depend on `flutter_edge_ai_diagnostics` and import it. It does not depend on `flutter_edge_ai` and reads the process, whichever engine runs in it.
2. Android, iOS, macOS, Linux and Windows only. Check `FlutterEdgeAiDiagnostics.isSupported` first: elsewhere `memorySnapshot()` throws `UnsupportedError` instead of returning empty values.
3. `null` and an exception mean different things. A null field is a value this package does not report on this platform; `MemoryReadException` is a read that should have worked and failed. Do not catch the exception and carry on with zeros.
4. The fields answer different questions per platform. On iOS `anonymousBytes` is `phys_footprint`, the number jetsam kills on, and `availableBytes` is this app's headroom before that limit. macOS uses the same `phys_footprint` for `anonymousBytes` but has no per-app limit, so there is no kill threshold and `availableBytes` is null. `anonymousPeakBytes` (iOS, macOS and Windows, null on Android and Linux) is the kernel's lifetime high-water mark of that figure (the footprint, or commit on Windows): it is never reset, so read a snapshot before you start and treat it as an upper bound for the operation. On Android there is no per-app limit: `availableBytes` is MemAvailable for the whole device, an optimistic upper bound, and lmkd kills well before it reaches zero. Never use it as an Android kill threshold. Linux reads the same files as Android; its `availableBytes` is machine-wide MemAvailable and ignores a cgroup `memory.max`, so inside a container it overstates what the app may use. On Windows `anonymousBytes` is the commit charge (PagefileUsage = PrivateUsage): private memory the app owns wherever it is, counted when allocated and not when touched, so it reads higher than the resident figure and is not comparable with the other platforms (FunctionGemma 270M on the CPU: +389 to +392 MiB commit against +102 to +105 MiB private working set at load, and most of the memory arrives with the first prompt); `anonymousPeakBytes` is PeakPagefileUsage; `availableBytes` is `ullAvailPhys` for the whole machine, an upper bound with no per-app limit behind it.
5. On Android, GPU memory (KGSL, Mali, dmabuf) is mostly outside `anonymousBytes`; on Adreno most of it is counted in `fileBackedBytes` instead (see 6). A model running on the GPU backend looks cheaper in `anonymousBytes` alone than it is. `FlutterEdgeAiDiagnostics.gpuMemory()` (experimental, Adreno only) returns a `GpuMemoryReading`, or null when the device has no reader (always on iOS, macOS, Linux and Windows, and on a phone with no `/dev/kgsl-3d0`, a Mali GPU for one; an Adreno process that has not used the GPU yet gets zeros); it is not a `MemorySnapshot` field. Its `inAnonymousBytes` and `inFileBackedBytes` are already inside those two counters; to subtract the second from `fileBackedBytes`, take both back to back while idle and treat the difference as approximate, since two reads taken apart can make it negative. It covers only the GPU memory mapped into the process, and costs 0.2 to 0.4 s on the device tried: the kernel holds the process's `mmap_lock` while it builds `smaps`, so do not call it per frame or per token. It is a reading, not a delta: it includes the app's own rendering (about 6 MiB in a Flutter app), so take one before loading the model and subtract. `gpuMemory()`, `GpuMemoryReading` and `GpuMemorySource` are `@experimental`: using them draws the `experimental_member_use` analyzer warning (add `// ignore: experimental_member_use` at the call site), and `GpuMemorySource` will gain values, so a `switch` over `reading.source` needs a default case.
6. On Android and Linux `fileBackedBytes` is `Private_Clean + Shared_Clean`: resident clean pages (mapped files on a CPU backend, and GPU driver buffers on some GPU backends; on Adreno most of a GPU model's memory is a `/dev/kgsl-3d0` mapping, mostly clean pages, not the model file). It can also include clean anonymous pages, so a delta is not an exact count of model weights. Reclaimable file pages are not a kill threshold, but are not free: weights read on every token must be read back from storage if dropped, and lmkd can treat that refault thrashing as a reason to kill. On Linux GPU memory is in neither field: on an integrated GPU it is system RAM the snapshot does not show (FunctionGemma 270M: 700 to 835 MiB of Intel `drm-resident-system0`, device mappings 0 MiB). A page swapped out and read back lands in Private_Clean (512 MiB did, on Linux 7.0). On Windows it is `WorkingSetSize − PrivateWorkingSetSize`: resident pages that are not private, DLL pages included, so not model weights (a LiteRT-LM CPU model is mapped at load and faulted in by the first prompt; ORT-GenAI's weights land in the private working set instead); it is null on a Windows that does not fill the extended struct. Windows dedicated GPU memory is in neither field and `gpuMemory()` returns null there. iOS and macOS are null because the package does not read this value there yet.
7. A snapshot walks kernel state: on Android the `/proc` reads are asynchronous (they do not block the isolate) but cost about 150 ms on a low-end device, and before Linux 5.10 they stall the process's mmap calls; on Linux about 3.7 ms per resident GiB (1.7 ms idle, 30 ms with 7 GiB resident, one machine); on iOS and macOS they are microsecond Mach calls; on Windows they are two `kernel32` calls, not timed. Take one at a few points — before loading, after loading, during generation — and never faster than about once a second, not on every frame or token.
8. A pubspec section strips nothing from a release build. Put the package under `dev_dependencies` only when nothing in `lib/` imports it.

## Interpret resident clean pages

GPU backends: on a GPU backend on Adreno, the driver's buffers are mapped through `/dev/kgsl-3d0` and are mostly clean pages, so they are counted here too. In one run on the vivo 1933 (Adreno 616, kernel 4.9) a Gemma 4 E2B GPU load raised that mapping from 6 to 981 MiB (988 after one prompt), matching `dumpsys meminfo`'s Gfx dev (989 MiB); about 115 MiB of it was dirty, which is in `anonymousBytes`, and all file mappings together (model, libraries, others) were about 260 MiB (Pss). With a GPU backend `fileBackedBytes` is therefore not a model-file figure: compare with a run of the same app on CPU, or subtract the `inFileBackedBytes` of a `FlutterEdgeAiDiagnostics.gpuMemory()` reading from `fileBackedBytes` (experimental, see rule 5). One device and one run each; other GPU drivers (Mali) were not measured.

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

A field is null in these cases:

- `anonymousBytes` and `fileBackedBytes` on an Android or Linux kernel without `/proc/self/smaps_rollup`. Mainline Linux added it in 4.14, but vendor kernels may backport it;
- `fileBackedBytes` on iOS and macOS: this package does not read a corresponding value yet;
- `availableBytes` always on macOS, which has no per-app limit, and on iOS when `os_proc_available_memory()` returns 0. Apple returns 0 both on the simulator, where no limit applies, and when the limit is already exceeded; the two cannot be told apart;
- `fileBackedBytes` on a Windows that does not fill PrivateWorkingSetSize (the extended struct);
- `anonymousPeakBytes` always on Android and Linux, and on an iOS or macOS version whose `task_info` reply predates the field.

`gpuMemory()` returns null on iOS, macOS, Linux and Windows, and on an Android phone with no `/dev/kgsl-3d0` (a Mali GPU, for one; `existsSync` tests it, `typeSync` says not found); on an Adreno phone a process that has not used the GPU yet gets a zero reading; a missing or unparseable `/proc/self/smaps` throws `MemoryReadException`; `outsideSnapshotBytes` is always null in this version.

## Choosing a model for the device

On iOS, compare the growth you measured for a model with `availableBytes` before loading it: if the model needs more than the headroom, jetsam kills the app during load. Large models also need the memory entitlements listed in flutter-edge-ai-inference. Two of them change what you measure: **Increased Memory Limit** raises the jetsam limit, so `availableBytes` grows; **Extended Virtual Addressing** gives the app more address space to map the model and does not add headroom.

On Android there is no such number to compare against. Measure on the smallest device you support, and treat `availableBytes` as a best case. Include generation: a model whose weights repeatedly refault from storage can cause thrashing and contribute to an lmkd kill even though its file pages are reclaimable.

On macOS there is no per-app limit either, and `availableBytes` is null: `anonymousBytes` and `anonymousPeakBytes` say how much the app holds, so compare them with the Mac's physical memory.
