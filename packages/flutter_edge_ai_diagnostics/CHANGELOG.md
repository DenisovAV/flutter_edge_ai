## 0.5.0
- Linux: `memorySnapshot()` reads `/proc` as on Android; `gpuMemory()` returns null there.

## 0.4.0
- Android (Adreno): experimental `FlutterEdgeAiDiagnostics.gpuMemory()`, the GPU memory mapped into the process.

## 0.3.0
- iOS and macOS: `anonymousPeakBytes`, the lifetime footprint peak; macOS `anonymousBytes` and `memorySnapshot()` supported.

## 0.2.2
- Android: `fileBackedBytes` reports resident clean pages, mostly mapped files; null on iOS.

## 0.2.1
- Android `/proc` reads are asynchronous, so a snapshot no longer blocks the calling isolate.

## 0.2.0
- **Breaking:** remove the `FlutterGemmaDiagnostics` alias; `dart fix --apply` still migrates.

## 0.1.0
- Renamed from `flutter_gemma_diagnostics`; `dart fix --apply` migrates.
- First release: `anonymousBytes` and `availableBytes` read from the OS on Android and iOS.
