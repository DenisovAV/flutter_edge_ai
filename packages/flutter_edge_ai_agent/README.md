# flutter_edge_ai_agent

> **Renamed from [`flutter_gemma_agent`](https://pub.dev/packages/flutter_gemma_agent).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_agent/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

On-device agentic **skills** for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai).

This opt-in satellite package turns the inference core into an on-device agent:
the model is given a set of *skills* (`SKILL.md`), decides which to invoke via
flutter_edge_ai's existing function-calling, runs them, and feeds the results back
— fully offline.

It is reverse-engineered from [google-ai-edge/gallery](https://github.com/google-ai-edge/gallery)
(Apache-2.0) and is **Gallery-compatible**: their `SKILL.md` catalog parses
unmodified, and their JavaScript skills run as-is (the
`window.ai_edge_gallery_get_result` contract is preserved).

## Platform support

| Skill type | Android | iOS | macOS | Windows | Web | Linux |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **text-only** | ✅ | ✅ | ✅ | ✅ | ❌³ | ✅ |
| **MCP** (Streamable HTTP) | ✅ | ✅ | ✅ | ✅ | ❌³ | ✅ |
| **native-intent** | ✅ | ✅ | ✅ | ✅ | ❌³ | ✅ |
| **JS** (webview) | ✅ | ✅ | ✅ | ✅¹ | ❌³ | ❌² |

¹ Windows JS skills need the [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
(pre-installed on Windows 11; on Windows 10 ship the bootstrapper). See
[Setup](#setup).
² Linux has no embeddable webview, so JS skills return an `ErrorResult`
(`isAvailable` is false). text / native-intent / MCP skills work on Linux.
³ The agent is not supported on Web yet — the browser LLM runtimes don't
reliably emit tool calls, so the agent loop is disabled there (see the note below).

JS skills run in a headless, sandboxed webview. To grant a secure context (so
skills using `crypto.subtle` and other secure-context Web APIs work), the
package serves each skill's assets over a loopback HTTP server
(`http://127.0.0.1`, a W3C "potentially trustworthy" origin) — one mechanism that
works identically across all native engines (WebView2 / WKWebView / Android
WebView), verified on hardware. On web the skill runs in a sandboxed `<iframe>`.

> **Web is unverified.** The table shows where each skill *type* runs once
> invoked, and the pieces the loop needs are in place: the web `.litertlm` path
> does emit well-formed tool calls and does survive the call -> result -> continue
> round-trip (`example/integration_test/web_function_calling_test.dart`). What is
> missing is a run of the agent itself on web — nothing here has been driven
> end-to-end in a browser, and `sizeInTokens` is approximate there, which the
> loop's context balancing depends on. On web, native-intent skills open
> `mailto:` / `sms:` links and a Google Calendar event page rather than OS
> surfaces. The agent is verified on **Android, iOS, macOS, and Windows** — use
> those until a web run exists.

## What's in the box

- `Skill` + `SkillType` (`textOnly` / `js` / `intent` / `mcp`) and the
  `parseSkillMd` parser (YAML frontmatter + markdown body).
- `SkillRegistry` — holds available/selected skills and builds the cheap
  name+description discovery string for the system prompt (two-stage discovery).
- `SkillExecutor` probe-chain (mirrors flutter_edge_ai's engine registry) + sealed
  `SkillResult` (`TextResult` / `ImageResult` / `WidgetResult` / `WebviewResult`
  / `ErrorResult`).
- Concrete executors: `TextSkillExecutor` (0 deps), `JsSkillExecutor`
  (sandboxed headless webview — `flutter_inappwebview` on native, a `package:web`
  iframe on web), `NativeIntentExecutor` (whitelisted OS intents behind user/OS
  confirm), `McpSkillExecutor` (MCP tools over Streamable HTTP).
- `AgentLoop` + `AgentSession` — the orchestrator over flutter_edge_ai's existing
  function-calling, emitting a `Stream<AgentEvent>` (skill loads, tool calls,
  inline results, streamed text).
- Cross-platform UI: `AgentChatView`, adaptive `SkillManagerView` /
  `McpManagerView`, `SecretEditorDialog`, `SkillTesterView`, and the add-skill
  disclaimer.
- **Bundled starter skills** (ported verbatim from Gallery, Apache-2.0) — see
  below.

## Bundled starter skills

These are skills the **on-device model** runs at inference time — not the
[package skills](https://pub.dev/packages/flutter_edge_ai) `flutter_edge_ai` bundles
for your *coding assistant*. They ship under `assets/skills/`, which the `skills`
CLI does not scan, so `dart run skills@ get --all` never installs them.

Eight starter skills ship as package assets, spanning the JS, native-intent, and
text-only mechanisms (write your own `SKILL.md` for MCP):

| Skill | Type | What it does |
|---|---|---|
| `calculate-hash` | JS | Hash a piece of text |
| `qr-code` | JS (image) | Generate a QR code |
| `query-wikipedia` | JS (data) | Summarize a Wikipedia topic |
| `interactive-map` | JS (webview) | Show a location on an embedded map |
| `send-email` | intent | Open the OS mail composer |
| `create-calendar-event` | intent | Open the calendar event editor |
| `get-current-time` | intent | Report the current local date and time |
| `kitchen-adventure` | text-only | A text-adventure dungeon-master persona |

Load them with `AssetSkillSource` and wire the JS executor to their bundled HTML:

```dart
final source = AssetSkillSource();
final skills = await source.load();             // parses the bundled SKILL.md
final registry = SkillRegistry()..addAll(skills, selected: true);

final js = JsSkillExecutor(sourceFor: source.jsSkillSourceFor);
```

`load()` returns one skill per bundled name or throws a `BundledSkillLoadError` (a
`StateError`) whose `failures` names each skill that did not load and why. On web,
a deployment that does not serve `assets/packages/flutter_edge_ai_agent/` causes it.

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';

// 1. Register the inference engine at app start. (Skill executors can also be
//    registered here via `skillExecutors:` — see "Registering executors" below;
//    this example passes them to the AgentSession instead.)
await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
);

// 2. Install + load a function-calling model (Gemma 4 E2B/E4B recommended).
await FlutterEdgeAi
    .installModel(modelType: ModelType.gemma4, fileType: ModelFileType.litertlm)
    .fromNetwork(gemma4E2BUrl)
    .install();
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);

// 3. Load the bundled skills and build the agent session.
final source = AssetSkillSource();
final registry = SkillRegistry()..addAll(await source.load(), selected: true);

final session = await AgentSession.fromModel(
  model,
  registry: registry,
  executors: [
    TextSkillExecutor(),
    JsSkillExecutor(sourceFor: source.jsSkillSourceFor),
    NativeIntentExecutor(),
    // McpSkillExecutor(...) to also call remote MCP tools.
  ],
);

// 4. Mount the chat view.
//   AgentChatView(session: session)
// e.g. "Calculate the hash of hello" or "Show Paris on interactive map".
```

See `packages/flutter_edge_ai/example` (the **Agent Skills** screen) for a
runnable demo.

## Asking about a photo

`ask` takes an optional image, so the model can pick a skill from what it saw
rather than from the text alone. Build the session with `supportImage: true`
(and back it with a multimodal model):

```dart
final session = await AgentSession.fromModel(
  model,
  registry: registry,
  supportImage: true, // required — and the model must be multimodal
);

await for (final event in session.ask('what is this?', imageBytes: photo)) {
  // …
}
```

Passing `imageBytes` to a session built without `supportImage: true` fails the
returned stream with an `ArgumentError` instead of quietly answering as if there
were no image — the flag is what's checked; that the model is actually
multimodal stays your responsibility (it can't be introspected from Dart).

## SKILL.md format

```yaml
---
name: kebab-case-id
description: One-line summary the model uses to pick the skill.
metadata:
  homepage: https://optional
  require-secret: true
  require-secret-description: how to obtain the key
---
# Title
## Instructions
Call the `run_js` tool with: data: { field: Type }
```

JS skills additionally ship `scripts/index.html` exposing
`window.ai_edge_gallery_get_result(data, secret)` returning a JSON string
(`{ result | image | webview | error }`). Secrets are injected as the JS
`secret` argument and **never** placed in the model prompt.

The model does not choose which script runs — `run_js` always runs the skill's
own `scripts/index.html` (or the `scriptName` its `SKILL.md` declares), resolved
by `JsSkillExecutor`. Its tool schema therefore takes only `data` (no
`scriptName`): a required script-name field only made the model invent a
filename, and honouring one would let it name any file under `scripts/`.

## Registering executors

Two equivalent ways to wire executors:

```dart
// A) Pass them per session (shown in the Quick start above):
AgentSession.fromModel(model, registry: registry, executors: [...]);

// B) Register them globally once, then omit `executors:` — fromModel reads the
//    core registry (mirrors how inference engines are registered):
await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
  skillExecutors: [TextSkillExecutor(), JsSkillExecutor(sourceFor: ...), NativeIntentExecutor()],
);
final session = await AgentSession.fromModel(model, registry: registry);
```

## Setup

Most skills need no platform setup. For the platform-specific bits:

- **Windows** — JS skills require the
  [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
  (pre-installed on Windows 11; bundle the bootstrapper for Windows 10).
- **iOS** — the `create-calendar-event` intent opens the calendar editor via
  `add_2_calendar`, which needs a usage description in `ios/Runner/Info.plist`:
  ```xml
  <key>NSCalendarsUsageDescription</key>
  <string>Create calendar events from the agent.</string>
  ```
  Local notifications (`schedule_notification`) prompt for permission at runtime.
- **Android** — `flutter_local_notifications` requires core-library desugaring in
  `android/app/build.gradle(.kts)`:
  ```kotlin
  android { compileOptions { isCoreLibraryDesugaringEnabled = true } }
  dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4") }
  ```
- **Android, AGP 9** — `flutter_inappwebview_android` 1.1.3, the latest stable
  release, still calls `getDefaultProguardFile('proguard-android.txt')`, which AGP 9
  rejects while configuring the project. Until a stable release fixes it, add to
  `android/gradle.properties`:
  ```properties
  android.r8.proguardAndroidTxt.disallowed=false
  ```
  AGP deprecates this opt-out and plans to remove it in AGP 10.

## Third-party attribution

The bundled starter skills (`calculate-hash`, `qr-code`, `query-wikipedia`,
`interactive-map`, `send-email`, `create-calendar-event`, `get-current-time`,
`kitchen-adventure`) and the `SKILL.md` format are derived from
[google-ai-edge/gallery](https://github.com/google-ai-edge/gallery), licensed
under the [Apache License 2.0](https://github.com/google-ai-edge/gallery/blob/main/LICENSE).

## License

MIT — see [LICENSE](LICENSE). Bundled starter skills are Apache-2.0 (see above).
