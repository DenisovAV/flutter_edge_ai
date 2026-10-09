# flutter_edge_ai_builtin_ai

> **Renamed from [`flutter_gemma_builtin_ai`](https://pub.dev/packages/flutter_gemma_builtin_ai).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_builtin_ai/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

Built-in OS AI engine for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai): runs inference
against the **system/browser-provided** on-device model instead of a downloaded model file —
Gemini Nano via ML Kit GenAI (AICore) on Android, Apple Foundation Models on iOS/macOS, Windows AI
Foundry (Phi Silica) on Windows, and Gemini Nano via the Chrome **Prompt API** on Web. Opt-in
package: add it only if you want your app to use whatever model the platform already ships, with no
model file to download or bundle.

Because the platform owns the weights, there's nothing to fetch: installation just records which
built-in model you want to use, and `BuiltInAi.ensureReady()` makes sure the feature itself is
turned on (and downloaded, the first time it's used).

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-builtin-ai`, covers availability, the user gesture the web arm needs, and falling back to a downloaded model.

## 0.3.0: the native layer moved out

Since **0.3.0** this package is a **thin adapter, not a Flutter plugin**. It declares no
`flutter: plugin:` block, ships no Kotlin/Swift/C++ and no pigeon — the OS backends now come from
[**`flutter_local_ai`**](https://pub.dev/packages/flutter_local_ai), which this package depends on
and maps onto flutter_edge_ai's `InferenceEngineProvider` / `InferenceModel` / `InferenceModelSession`
contracts.

**Your Dart code does not change.** `BuiltInAi`, `BuiltInAiEngine`, `BuiltInAiModels`,
`BuiltInAiAvailability`, `BuiltInAiUnavailableException` and `BuiltInAiHuggingFaceResolver` keep
their names, members and signatures; only the import moves with the rename, from
`package:flutter_gemma_builtin_ai/…` to `package:flutter_edge_ai_builtin_ai/…`. The rest is build-level:

- **`pub get` regenerates the plugin registrants and the `Podfile.lock`** — this package leaves
  them, `flutter_local_ai` enters. CI that runs a frozen `pod install --deployment` fails until the
  lockfile is re-committed.
- **The macOS deployment floor rises from 10.15 to 12.0** (`flutter_local_ai`'s podspec and
  `Package.swift`). A macOS 11 target fails in CocoaPods/SPM resolution with a message that names
  the pod, not this package — raise the Runner's deployment target to 12.0.
- **iOS no longer floors at 15.0 because of this package** (`flutter_local_ai` builds from 13.0),
  but core `flutter_edge_ai` still requires 15.0, so an app's effective floor is unchanged.
- **`package:flutter_gemma_builtin_ai/pigeon.g.dart` is gone** along with the channel it wrapped.
  It was generated plumbing; nothing in the documented API referenced it.
- **Windows is newly supported**, through `flutter_local_ai`'s Windows AI Foundry backend, and
  `BuiltInAiModels` gains `windowsAiFoundry`, `chromePromptApi`, `all` and `forCurrentPlatform`
  alongside the two specs it already had.

## Supported platforms & OS floors

Every row is a property of the running device, OS and build — not of the package. Probe it with
`BuiltInAi.availability()` before creating a model.

| Platform | Built-in model | Runtime API | Devices & requirements |
|----------|----------------|-------------|------------------------|
| Android | Gemini Nano | ML Kit GenAI / AICore (`genai-prompt` 1.0.0-beta4) | Pixel 9+, Galaxy S25+. **`minSdk 26`** and **Kotlin 2.3.21** in your app (see [Android setup](#android-setup)). |
| iOS / macOS | Apple Foundation Models | FoundationModels framework | iPhone 15 Pro+, Apple Silicon Macs, Apple Intelligence enabled in **Settings → Apple Intelligence & Siri**. Inference needs **OS 26+** at runtime — below that the plugin reports `unavailableOsTooOld`, so you can still ship a fallback. The plugin itself builds from **iOS 13.0 / macOS 12.0**, so it links and runs on older OSes. |
| Windows | Phi Silica | Windows AI Foundry (Windows App SDK 2.0+) | Windows 11 25H2+ on Copilot+ class hardware (or a supported GPU), in a packaged app. The build resolves the App SDK projection itself; a build that could not reports `unavailableDeviceUnsupported`. See [Windows setup](#windows-setup). |
| Web | Gemini Nano | Chrome **Prompt API** (`self.LanguageModel`) | Desktop Chrome / Chromium-Edge only — **not** Chrome-Android/iOS, **not** Firefox/Safari. ~22 GB free disk + a GPU with >4 GB VRAM (or a 16 GB-RAM CPU-only path). See [Web setup](#web-setup). |
| Linux | — | — | No OS built-in model. `availability()` reports `unavailableDeviceUnsupported`; fall back to a downloaded model. |

Vision (image input) requires **OS 27 plus an OS 27 SDK / Swift 6.4 compiler** on Apple platforms —
on OS 26 Apple Foundation Models is text-only, and that OS 27 branch is not device-verified yet.
Android Gemini Nano supports vision on every supported device. **Windows and Web are text-only**:
creating a model with `supportImage: true` there throws `LocalAiUnsupportedException` rather than
silently dropping the image.

## Quick start

Register the engine at startup, alongside any other engines your app uses:

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';

void main() async {
  await FlutterEdgeAi.initialize(
    inferenceEngines: const [BuiltInAiEngine()],
  );
  runApp(MyApp());
}
```

Install a built-in model. Built-in models have no file to download, so installation just records
the identity — pass `fileType: ModelFileType.builtIn` and use `.fromBundled(...)` with one of the
ready-made specs' `name`:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.general,
  fileType: ModelFileType.builtIn,
).fromBundled(BuiltInAiModels.geminiNano.name).install();
```

`BuiltInAiModels` carries `geminiNano`, `appleFoundationModels`, `windowsAiFoundry` and
`chromePromptApi` — plus `all`, and `forCurrentPlatform`, which is null on Linux and Fuchsia, where
there is no OS model to install:

```dart
final spec = BuiltInAiModels.forCurrentPlatform;
if (spec == null) {
  // No built-in model on this platform — install a downloaded one instead.
}
```

Each spec is a plain `InferenceModelSpec` whose source is an **identity token, not a file**: the
engine is selected by `fileType == ModelFileType.builtIn` alone, never by the name.

Before creating the model, make sure the OS feature is actually ready — this also drives the
Android on-device download the first time the feature is used. It can be a sizeable system
download, so ask the user first:

```dart
await BuiltInAi.ensureReady(
  onProgress: (percent) => print('Preparing built-in AI: $percent%'),
);
```

Then load and use the model exactly like any other flutter_edge_ai engine:

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final session = await model.createSession();
await session.addQueryChunk(const Message(text: 'Hello!', isUser: true));
final response = await session.getResponse();
```

## Feature parity vs. downloaded-model engines

| Feature | Android (Gemini Nano) | iOS / macOS (Apple FM) | Windows (AI Foundry) | Web (Chrome Prompt API) |
|---------|------------------------|-------------------------|----------------------|--------------------------|
| Streaming responses | ✅ incremental | ✅ incremental | ⚠️ one final chunk | ✅ incremental |
| Vision (image input) | ✅ | ✅ OS 27 + OS 27 SDK (text-only on OS 26) | ❌ | ❌ |
| Audio input | ❌ | ❌ | ❌ | ❌ |
| Function calling | ✅ (prompt-based) | ✅ (prompt-based) | ✅ (prompt-based) | ✅ (prompt-based) |
| Thinking mode | ❌ | ❌ | ❌ | ❌ |
| `sizeInTokens` | ✅ native token count | ✅ on OS 26.4+, built with Xcode 26.4+ (estimate otherwise) | ❌ estimate | ✅ `measureContextUsage` |
| `maxOutputTokens` | ✅ | ✅ | ❌ ignored | ❌ ignored (warns once) |
| LoRA weights | ❌ | ❌ | ❌ | ❌ |
| Concurrent sessions (`openSession`) | ✅ | ✅ | ✅ | ✅ |

`sizeInTokens` on Apple needs BOTH conditions. `SystemLanguageModel.tokenCount` is
`@available(iOS 26.4, macOS 26.4)`, so the declaration is absent from earlier SDKs —
a package built with Xcode 26.1 cannot call it at all, and one built with 26.4+ still
falls back when RUNNING on an older OS. Where no tokenizer is reachable — that case, and
Windows, which exposes none at all — the count is a `text.length / 4` estimate.

On Web, `sizeInTokens` needs an **open session** (the Prompt API measures usage against one) and
uses `measureContextUsage`, falling back to the legacy `measureInputUsage` on older Chrome builds.

Audio input, LoRA, and `loraPath` throw `UnsupportedError` — the OS models expose none of them.
`enableThinking` is accepted for API parity and ignored, with a one-time log warning.

"Prompt-based" function calling means tool definitions are woven into the prompt (by core
`InferenceChat`) rather than using a native structured tool-calling API. Native tool declarations
are deliberately **not** forwarded to the OS runner: handing the same tools to both would run two
competing tool loops for one turn. Gemini Nano handles single-turn calls; multi-turn agent chaining
is not supported on Web (see `flutter_edge_ai_agent`).

### Reaching what flutter_edge_ai's interface has no slot for

Native tool calling (Apple, OS 26+) and schema-constrained JSON output are `flutter_local_ai`
features with no equivalent in flutter_edge_ai's `InferenceModelSession`. They stay available through
`flutter_local_ai`'s own API — `LocalAi`, `LocalAiModel.create()`, `LocalAiSession` — which you can
use alongside this engine, since it is the same package driving the same native host:

```dart
import 'package:flutter_local_ai/flutter_local_ai.dart';

final caps = await LocalAi.capabilities();
if (caps.supportsToolCalling && caps.supportsStructuredOutput) {
  // Apple Foundation Models today. Open a LocalAiSession with tools/schema.
}
```

Gate on `LocalAi.capabilities()` rather than on `Platform.isX`: the same binary answers differently
across OS versions.

To reach the exact native model or session this engine is driving, cast to `BuiltInAiModel` /
`BuiltInAiSession` and read `localAiModel` / `localAiSession`. Both are **`@experimental`**: they
return `flutter_local_ai` types, which may change with that package's next major release without a
breaking release of this one.

## Android setup

`flutter_local_ai` declares **`minSdk 26`** (the ML Kit GenAI / AICore floor) — raise your app's
`android/app/build.gradle(.kts)` `minSdk` to 26 or the manifest merger fails with a
`uses-sdk:minSdkVersion` conflict. The ML Kit Prompt API `beta4` artifact carries Kotlin 2.3
metadata, so the app needs **Kotlin 2.3.21** and the current `compilerOptions` DSL:

```kotlin
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}
```

Let the Prompt API resolve its own common and coroutine dependencies rather than pinning older
versions. Unlike flutter_edge_ai's own plugins, `flutter_local_ai` applies the Kotlin Gradle Plugin
itself, so `android.builtInKotlin=true` is not usable in an app that depends on it.

## Windows setup

Nothing to configure to *build*: `flutter build windows` resolves the Windows App SDK's C++/WinRT
projection itself — from the local NuGet cache, or downloaded from nuget.org into the build tree —
through `flutter_local_ai`. When it cannot (no network and no cache) the build prints a
`flutter_local_ai:` warning and the app reports `unavailableDeviceUnsupported`, so it still compiles
and your fallback runs. The environment variables `FLUTTER_LOCAL_AI_WINDOWS_AI` (`AUTO` by default,
`ON`, `OFF`) and `FLUTTER_LOCAL_AI_NUGET_DOWNLOAD=OFF` steer it; see
[`flutter_local_ai`'s Windows setup](https://pub.dev/packages/flutter_local_ai).

Running needs Windows 11 25H2+ on a Copilot+ PC (or a supported GPU) and a packaged app — see
[Microsoft's setup guide](https://learn.microsoft.com/en-us/windows/ai/apis/get-started). This path
still needs Windows device validation.

## Web setup

Unlike `flutter_edge_ai_litertlm`'s web arm, there is **no CDN `<script>` tag to add to
`web/index.html`** — the Chrome Prompt API is a bare global (`self.LanguageModel`) the browser
itself exposes; there is nothing to load. What you need instead is for the browser to have the
feature **enabled**:

- **Production**: register your origin for the [Prompt API origin
  trial](https://developer.chrome.com/origintrials) and add the issued token to `web/index.html`:
  ```html
  <meta http-equiv="origin-trial" content="YOUR_TOKEN_HERE">
  ```
- **Local development**: enable `chrome://flags/#prompt-api-for-gemini-nano` in your own Chrome and
  restart the browser.

⚠️ **Verify before you ship**: whether the Prompt API is still origin-trial/flag-gated on plain web
pages, or has shipped in stable Chrome without a token, changes over time (it has been stable in
*Chrome Extensions* since Chrome 138, but its status on ordinary web pages is the thing to check
against the Chrome version your users actually run). `BuiltInAi.availability()` reports
`unavailableDeviceUnsupported` on any browser/version where the feature isn't on — always probe
before creating a model rather than assuming it's available.

Chrome fixes sampling when a session is created, and its `tools` option is behind an experimental
flag and does not route reliably, so tool declarations are never handed to it natively.

## Troubleshooting

`BuiltInAi.availability()` / `BuiltInAi.ensureReady()` report a `BuiltInAiAvailability` status
(surfaced via `BuiltInAiUnavailableException.status` when `ensureReady()` fails). The enum is shared
across every platform, and no platform but Windows AI Foundry produces all seven values: ML Kit
has no "too old" or "switched off" state, Apple never says `downloadable` (the OS fetches its own
assets, so a model that isn't ready reports `downloading`), and Chrome reports four states with no
reason attached.

| Status | Meaning | User-facing remedy | Web notes |
|--------|---------|---------------------|-----------|
| `available` | Ready to use now. | — | — |
| `downloadable` | Feature exists but isn't downloaded yet. | Call `BuiltInAi.ensureReady()` — it triggers the download and reports progress via `onProgress`. | On Web, `ensureReady()` reports a *real* percentage from the browser's `downloadprogress` event. |
| `downloading` | A download is already in progress. | Call `BuiltInAi.ensureReady()` and wait; it polls until ready or the `timeout` elapses. | Same on Web. |
| `unavailableDeviceUnsupported` | This device/browser doesn't have AICore (Android), Apple Intelligence hardware (Apple), a configured App SDK (Windows), or the Prompt API (Web) — and always on Linux, which has no OS model. | Fall back to a bundled model — the device can't run the built-in one. | Also returned when `'LanguageModel' in self` is `false` — wrong browser, wrong platform, or the feature isn't enabled (see [Web setup](#web-setup)). |
| `unavailableOsTooOld` | The OS version is below what the built-in model requires. | Prompt the user to update the OS, or fall back to a bundled model. | Never returned on Web. |
| `unavailableDisabled` | The feature exists but is turned off. | Ask the user to enable it: Apple Intelligence in **Settings → Apple Intelligence & Siri** (iOS/macOS), or the Windows AI feature in Windows Settings. | Only Apple and Windows report it. ML Kit has no "switched off" state, so Android folds this into `unavailableOther`; Chrome folds it into `unavailableDeviceUnsupported`/`unavailableOther`. |
| `unavailableOther` | Unclassified failure — including a probe that timed out. | Fall back to a bundled model; check device/console logs for detail. | Chrome's `'unavailable'` maps here — the browser doesn't report *why* (disk floor, VRAM, flag/origin-trial missing). |

`availability()` never throws and never hangs — a probe that doesn't return within
`BuiltInAi.debugProbeTimeout` resolves to `unavailableOther`. `ensureReady()` throws
`BuiltInAiUnavailableException` immediately for every `unavailable*` status (no download is
attempted); it only drives a download from `downloadable`/`downloading`.

`FlutterEdgeAi.getActiveModel(...)` throws the same exception when the OS model isn't
`available` — readiness is a precondition of model creation, not something it waits out.
