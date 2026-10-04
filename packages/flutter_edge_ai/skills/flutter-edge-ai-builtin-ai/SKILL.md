---
name: flutter-edge-ai-builtin-ai
description: Use when running the device's own model with flutter_edge_ai_builtin_ai — Gemini Nano on Android or in desktop Chrome, Phi-4-mini in Microsoft Edge, Apple Foundation Models on iPhone, iPad and Mac, Phi Silica on Windows — with nothing to download or bundle, or when falling back to a downloaded model where it is missing. Also use when BuiltInAiUnavailableException or a TimeoutException is thrown, availability reports "downloadable", web throws NotAllowedError about a user gesture, the Android build fails the manifest merge on minSdk, or the model is missing in Chrome. For models the app downloads itself, use flutter-edge-ai-inference.
---

# The built-in OS model

## Rules

1. The OS owns the weights, but the model is still installed — as an identity: `fileType: ModelFileType.builtIn` with `.fromBundled(...)`. The app downloads nothing.
2. Call `BuiltInAi.ensureReady()` before `getActiveModel()`, from a user action: the first call downloads the model and can take minutes, and on web the browser refuses to start that download without a user gesture. Call it straight from the tap handler, with no slow `await` in front of it. It throws `TimeoutException` after `timeout` — 10 minutes by default.
3. On web a missing gesture is **not** distinguishable by type: `ensureReady` rewraps it as `BuiltInAiUnavailableException` with `unavailableOther`, and only `.message` carries the browser's "NotAllowedError: Requires a user gesture". Read the message before concluding the device cannot do it — otherwise the fallback below downloads gigabytes for nothing.
4. Catch `BuiltInAiUnavailableException` and fall back to a downloadable model.
5. Android apps need `minSdk 26`, or the manifest merge fails, and Kotlin 2.3.21. The native layer, flutter_local_ai, applies the Kotlin Gradle Plugin itself, so `android.builtInKotlin=true` does not work in the app.
6. Linux has no built-in model: `BuiltInAiModels.forCurrentPlatform` is null there and `BuiltInAi.availability()` reports `BuiltInAiAvailability.unavailableDeviceUnsupported`. Windows runs Phi Silica through Windows AI Foundry on Copilot+ hardware, in a packaged app; a Windows build that could not resolve the Windows App SDK reports the same unavailable state, so the fallback below covers it.

## Setup with a fallback

```sh
flutter pub add flutter_edge_ai flutter_edge_ai_builtin_ai flutter_edge_ai_litertlm
```

```dart
import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: [BuiltInAiEngine(), LiteRtLmEngine()],
);

final spec = BuiltInAiModels.forCurrentPlatform; // null on Linux

Future<InferenceModel> downloadGemma() async {
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  ).fromNetwork(
    // 2.6 GB — ask first. On web: gemma-4-E2B-it-web.litertlm
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
  ).install();
  return FlutterEdgeAi.getActiveModel(maxTokens: 1024);
}

InferenceModel model;
if (spec == null) {
  model = await downloadGemma();
} else {
  try {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.builtIn,
    ).fromBundled(spec.name).install();
    // onProgress reports real percentages on web only: ML Kit gives no byte
    // total on Android, and Apple downloads nothing — ensureReady just waits.
    await BuiltInAi.ensureReady(onProgress: (int percent) => print('$percent%'));
    model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
  } on BuiltInAiUnavailableException {
    model = await downloadGemma();
  } on TimeoutException {
    model = await downloadGemma();
  }
}
```

The latest install is the one `getActiveModel` loads, so the fallback replaces the built-in model. Sessions and chats then work as in the flutter-edge-ai-inference skill.

## Checking before offering the feature

```dart
final availability = await BuiltInAi.availability();
final usable = availability == BuiltInAiAvailability.available ||
    availability == BuiltInAiAvailability.downloadable ||
    availability == BuiltInAiAvailability.downloading;
```

`downloadable` and `downloading` mean "not yet" — `ensureReady` finishes the job. The `unavailable*` states describe the device now, not forever:

| State | Meaning |
| --- | --- |
| `BuiltInAiAvailability.unavailableDeviceUnsupported` | the hardware cannot run it — and on web, that the browser exposes no Prompt API at all, including desktop Chrome with the flag off |
| `BuiltInAiAvailability.unavailableOsTooOld` | an OS update would enable it; on Apple the floor is OS 26 |
| `BuiltInAiAvailability.unavailableDisabled` | the user can turn it on in system settings (Apple Intelligence on Apple devices) |
| `BuiltInAiAvailability.unavailableOther` | anything else: a probe that timed out after 20 seconds, or Chrome's reasonless "unavailable", which in practice is its disk and VRAM floor — worth asking again later |

## Platforms

| Platform | Model | Needs |
| --- | --- | --- |
| Android | Gemini Nano (AICore) | Pixel 9+, Galaxy S25+; `minSdk 26` |
| iOS, macOS | Apple Foundation Models | iOS 26+ / macOS 26+ on an iPhone 15 Pro or newer, or an Apple Silicon Mac, with Apple Intelligence on. It builds from iOS 13 / macOS 12, so a macOS app needs a 12.0 deployment target; below OS 26 it reports `unavailableOsTooOld` |
| Windows | Phi Silica (Windows AI Foundry) | Windows 11 25H2+ on a Copilot+ PC or a supported GPU, in a packaged app. Streams one final chunk and ignores `maxOutputTokens` |
| Web | Gemini Nano (Chrome Prompt API) | desktop Chrome — not mobile browsers, Firefox or Safari |
| Web | Phi-4-mini (Edge Prompt API) | Microsoft Edge with the Prompt API flag on; Edge Dev 154–155 exposes the API but cannot run the model |

Images work on Android, one per message, and only when asked for: `getActiveModel(maxTokens: 4096, supportImage: true)` **and** `createChat(supportImage: true)`. With the default `supportImage: false` the image is dropped with no warning. Windows and web are text-only, and Apple is text-only on OS 26: `supportImage: true` there fails when `getActiveModel` creates the model, not mid-conversation — so do not build an image path there.

## Web

There is no script to add: the Prompt API is part of the browser. It has to be enabled.

- Production — register the origin for the Prompt API origin trial and add the token to `web/index.html`:

```html
<meta http-equiv="origin-trial" content="YOUR_TOKEN_HERE">
```

- Local development — enable `chrome://flags/#prompt-api-for-gemini-nano` and restart Chrome.
- Microsoft Edge — enable `edge://flags` → "Prompt API for on-device language model" and restart. Both browsers use `BuiltInAiModels.chromePromptApi`, which is what `forCurrentPlatform` returns on web: the spec names the API, and the browser picks the model.

## Trade-offs

No choice of weights, no LoRA, and capabilities that vary by OS version. The right pick when zero download and zero disk matter more than choosing the model.

Tool calls go through the prompt on every platform. Apple's native tool calling and schema-constrained output are reachable only through `BuiltInAiModel.localAiModel` / `BuiltInAiSession.localAiSession` — `@experimental`, and they change with flutter_local_ai's next major release.
