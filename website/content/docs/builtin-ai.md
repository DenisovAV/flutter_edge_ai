---
title: Built-in AI
description: Run the device's own OS/browser AI as an engine — Gemini Nano (Android + Chrome), Phi-4-mini (Edge), Apple Foundation Models (iOS/macOS) and Phi Silica (Windows) — with no model to download, plus the availability-probe → open-model fallback pattern.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

flutter_edge_ai's engines are **pluggable**: you register them in
`FlutterEdgeAi.initialize(...)`, and the registry picks one per model by its
declared `ModelFileType`. One of those engines is `flutter_edge_ai_builtin_ai` —
it runs the model the **operating system (or browser) already ships**, so there
is **nothing to download**: installation only records which built-in model you
want, and the platform owns the weights.

## Runtimes & devices

| Platform | Built-in model | Runtime | Minimum devices |
|----------|----------------|---------|-----------------|
| Android | **Gemini Nano** | ML Kit GenAI / AICore | Pixel 9+, Galaxy S25+ (`minSdk 26`) |
| iOS / macOS | **Apple Foundation Models** (Apple Intelligence) | FoundationModels framework | iOS 26+ / macOS 26+ on iPhone 15 Pro+, Apple Silicon Macs — Apple Intelligence enabled |
| Windows | **Phi Silica** | Windows AI Foundry (Windows App SDK) | Windows 11 25H2+ on a Copilot+ PC (or a supported GPU), in a packaged app |
| Web | **Gemini Nano** in Chrome, **Phi-4-mini** in Edge | **Prompt API** (`self.LanguageModel`) | Desktop Chrome; Microsoft Edge with a flag (see [Web setup](#web-setup)) |

> **Note:** in Chrome the Prompt API *is* Gemini Nano — the browser runs the same
> on-device model, exposed through a JS API. Edge implements the same API with
> Microsoft's own model, Phi-4-mini: the same calls, a different model. **Linux
> has no OS built-in model** — there `availability()` reports
> `unavailableDeviceUnsupported` and you fall back to a downloaded model
> (see [the fallback pattern](#the-fallback-pattern)). Windows runs Phi Silica
> since 0.3.0; a Windows build that could not resolve the Windows App SDK
> reports `unavailableDeviceUnsupported` too.

Availability is a runtime property of the device/OS/browser — never assume it at
build time; always probe with `BuiltInAi.availability()` /
`BuiltInAi.ensureReady()` before creating the model.

## Setup

Add the package and register `BuiltInAiEngine()` at startup, alongside any other
engines your app uses:

```
dependencies:
  flutter_edge_ai: latest_version
  flutter_edge_ai_builtin_ai: latest_version   # OS/browser built-in AI
```

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: const [BuiltInAiEngine()],
);
```

> **Android:** the package's native layer, `flutter_local_ai`, declares
> `minSdk 26` (the ML Kit GenAI / AICore floor) — raise your app's
> `android/app/build.gradle(.kts)` `minSdk` to 26 or the manifest merger fails.
> It also applies the Kotlin Gradle Plugin itself and needs Kotlin 2.3.21, so
> `android.builtInKotlin=true` is not usable in an app that depends on it.
>
> **Apple:** since 0.3.0 this package is no longer a Flutter plugin; its native
> layer is `flutter_local_ai`, which builds from iOS 13.0 / macOS 12.0. A macOS
> app below 12.0 fails at `pod install`, and CI that runs a frozen
> `pod install --deployment` has to re-lock `Podfile.lock` once.
>
> **Windows:** nothing to configure to build — see the package README's
> Windows setup for the environment switches and runtime requirements.

## Install a built-in model

Built-in models have no file to fetch, so installation just records the
identity — pass `fileType: ModelFileType.builtIn` and use one of the ready-made
specs from `BuiltInAiModels`:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.general,
  fileType: ModelFileType.builtIn,
).fromBundled(BuiltInAiModels.geminiNano.name).install();
```

`BuiltInAiModels` carries `geminiNano` (Android), `appleFoundationModels`
(iOS/macOS), `windowsAiFoundry` (Windows) and `chromePromptApi` (web), plus
`all` and `forCurrentPlatform` — the spec for the running platform, or `null` on
Linux. They are plain `InferenceModelSpec`s you can also reference directly when
building your own model list.

## Probe availability (and download, if needed)

`BuiltInAi.availability()` reports whether the OS model is ready.
`BuiltInAi.ensureReady()` makes sure the feature is on — and drives the on-device
download the first time it is used (Android, Windows and web), reporting progress:

```dart
final status = await BuiltInAi.availability();
// available · downloadable · downloading · unavailable* (device/OS/disabled/other)

await BuiltInAi.ensureReady(
  onProgress: (percent) => debugPrint('Preparing built-in AI: $percent%'),
);
// Throws BuiltInAiUnavailableException for any unavailable* status.
```

**On web, call `ensureReady()` from a user gesture** — straight from a button's
tap handler, with no other `await` in front of it. While the model still has to
be downloaded, the browser refuses to start the session that downloads it unless
the user has interacted with the page (`NotAllowedError: Requires a user gesture
when availability is "downloading" or "downloadable"`). Chrome and Edge both
enforce this.

## The fallback pattern

The point of a pluggable engine: **use the built-in model when the device
supports it (zero download, private, fast); otherwise fall back to a downloaded
open model** — through the same API, without rewriting the app.

The fallback below registers a second engine, so add its package too — e.g.
`flutter_edge_ai_litertlm` (for `LiteRtLmEngine`), or `flutter_edge_ai_mediapipe` /
`flutter_edge_ai_onnx`:

```dart
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: const [
    BuiltInAiEngine(),   // flutter_edge_ai_builtin_ai
    LiteRtLmEngine(),    // flutter_edge_ai_litertlm — the fallback
  ],
);

// Does this device have a usable built-in model? (null spec: Linux)
final spec = BuiltInAiModels.forCurrentPlatform;
final builtInReady = spec != null &&
    await BuiltInAi.availability() == BuiltInAiAvailability.available;

if (builtInReady) {
  // Built-in: nothing to download.
  await FlutterEdgeAi.installModel(
    modelType: ModelType.general,
    fileType: ModelFileType.builtIn,
  ).fromBundled(spec.name).install();
} else {
  // Fallback: install an open model (Gemma / Qwen / Phi …).
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
  ).fromNetwork('https://…/gemma3-1b-it.litertlm').install();
}

// From here the code is identical regardless of which engine backs the model:
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final session = await model.createSession();
await session.addQueryChunk(const Message(text: 'Hello!', isUser: true));
final response = await session.getResponse();
```

## Capabilities & limits

| Feature | Android (Gemini Nano) | iOS / macOS (Apple FM) | Windows (Phi Silica) | Web (Chrome Prompt API) |
|---------|------------------------|-------------------------|----------------------|--------------------------|
| Streaming | ✅ | ✅ | ⚠️ one final chunk | ✅ |
| Function calling | ✅ prompt-based | ✅ prompt-based | ✅ prompt-based | ✅ prompt-based |
| Vision (image input) | ✅ | ⚠️ OS 27 + an OS 27 SDK only (not device-verified); text-only on OS 26 | ❌ | ❌ |
| Audio · Thinking · LoRA | ❌ | ❌ | ❌ | ❌ |
| `sizeInTokens` | ✅ native count | ✅ on OS 26.4+, built with Xcode 26.4+ (estimate otherwise) | ❌ estimate | ✅ `measureContextUsage` |
| `maxOutputTokens` | ✅ | ✅ | ❌ ignored | ❌ ignored (warns once) |

- **Function calling is prompt-based** — tool definitions are woven into the
  prompt by core `InferenceChat`, on every platform. Apple's native tool calling
  and schema-constrained output are reachable only through the `@experimental`
  `BuiltInAiModel.localAiModel` / `BuiltInAiSession.localAiSession`, which may
  change with `flutter_local_ai`'s next major release. On Web, Chrome's native Prompt-API tool use is experimental
  and not production-usable (Chrome 151), so it too goes through the prompt-based
  path. Gemini Nano handles single-turn calls; multi-turn agent chaining is not
  supported on Web (see [Agent Skills](/docs/agent)).
- **`sizeInTokens` on Apple needs two things at once.**
  `SystemLanguageModel.tokenCount` is `@available(iOS 26.4, macOS 26.4)`, so the
  declaration is missing from earlier SDKs entirely — a build on Xcode 26.1
  cannot reference it, and a build on 26.4+ still falls back when running on an
  older OS. Either way the count comes from core's `text.length / 4` estimate.

- **Windows and web are text-only.** `supportImage: true` there fails when the
  model is created, not when the first image is sent.
- **Edge:** measured on Edge 151 (macOS) with Phi-4-mini — streaming, stopping
  and `measureContextUsage` work through the same calls, and the context window
  is 9216 tokens. Function calling on Phi-4-mini has not been tested.

## Web setup

There is **no CDN `<script>` tag** — the Chrome Prompt API is a browser global
(`self.LanguageModel`). What it needs is the feature *enabled*:

- **Production:** register your origin for the [Prompt API origin
  trial](https://developer.chrome.com/origintrials) and add the token to
  `web/index.html`:
  ```
  <meta http-equiv="origin-trial" content="YOUR_TOKEN_HERE">
  ```
- **Local dev:** enable `chrome://flags/#prompt-api-for-gemini-nano` and restart
  Chrome. Floor: desktop Chrome on Windows, macOS 13+, Linux or ChromeOS Plus;
  22 GB free disk; a GPU with more than 4 GB VRAM, or 16 GB RAM and 4 CPU cores.
- **Microsoft Edge:** open `edge://flags`, enable **Prompt API for on-device
  language model** and restart. The model is Phi-4-mini, not Gemini Nano, and
  needs Windows 10/11 or macOS 13.3+, 20 GB free disk and 5.5 GB VRAM; it
  downloads on first use (about 5 minutes on a fast connection). Verified on
  stable Edge 151 on macOS. Edge Dev 154–155 exposes the API but cannot run the
  model ([MSEdgeExplainers#1392](https://github.com/MicrosoftEdge/MSEdgeExplainers/issues/1392)).

`BuiltInAi.availability()` reports `unavailableDeviceUnsupported` on any
browser/version without the Prompt API, and `unavailableOther` when the API is
there but the browser cannot run the model — always probe before creating a model.

See the [`flutter_edge_ai_builtin_ai` package](/docs/packages) for the full API.

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-builtin-ai`](/docs/package-skills), the skill that teaches it availability, the user gesture the web arm needs, and falling back to a downloaded model.
