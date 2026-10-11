## 0.3.3
- Sampling parameters are nullable; unset ones keep `temperature: 0.8, topK: 1` (#572).
- Require `flutter_edge_ai` ^2.2.0.

## 0.3.2
- **Breaking:** `createChat(isThinking:)` is `enableThinking`; require `flutter_edge_ai` ^2.1.0.

## 0.3.1
- Require `flutter_edge_ai` 2.x.

## 0.3.0
- Renamed from `flutter_gemma_builtin_ai`.
- **Breaking:** a pure-Dart adapter over `flutter_local_ai` ^0.2.1; the `BuiltInAi*` API is unchanged.
- **Breaking:** no longer a plugin; re-lock `Podfile.lock`, and macOS apps need a 12.0 target.
- **Breaking:** requires Flutter 3.44 / Dart 3.12; `pigeon.g.dart` is gone.
- Windows support through Windows AI Foundry (Phi Silica).
- `supportImage: true` where there is no vision fails at model creation.
- `localAiModel` / `localAiSession` expose native tools and structured output (`@experimental`).

## 0.2.2
- Windows/Linux: `availability()` reports `unavailableDeviceUnsupported` instead of throwing.

## 0.2.1
- Add `BuiltInAiHuggingFaceResolver` (auto-registered from `BuiltInAiEngine`) so `resolveHuggingFace` reports that built-in OS models have no Hugging Face file (#454).
- fix: iOS/macOS builds failed on Xcode below 26.4 — `SystemLanguageModel.tokenCount` is absent from those SDKs and `#available` cannot gate a missing declaration (#460).

## 0.2.0
- Web support: Gemini Nano via the Chrome Prompt API (desktop Chrome/Edge).

## 0.1.1
- Android plugin no longer applies KGP — Flutter's Gradle plugin does (#440).
- iOS floor lowered to 15.0 — every Foundation Models call is `#available`-guarded (#441).

## 0.1.0
- Initial release: Gemini Nano (Android) + Apple Foundation Models (iOS/macOS) engine
