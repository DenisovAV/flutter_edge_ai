---
title: Agent Skills
description: On-device agentic skills for flutter_edge_ai — give the model a SKILL.md catalog and let it pick and run skills through the tool-calling loop, fully offline.
image: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_agent` is an opt-in satellite package that turns the inference
core into an on-device **agent**: you give the model a set of *skills*
(`SKILL.md` files), and it decides which to invoke through flutter_edge_ai's
existing function-calling, runs them, and feeds the results back — fully offline.

It is reverse-engineered from
[google-ai-edge/gallery](https://github.com/google-ai-edge/gallery) (Apache-2.0)
and is **Gallery-compatible**: their `SKILL.md` catalog parses unmodified, and
their JavaScript skills run as-is.

<Info>
Agent skills build on function calling, so they need a function-calling-capable
model (Gemma 4 E2B/E4B recommended). See <a href="/docs/function-calling">Function
Calling</a> for the model support matrix.
</Info>

<Info>
Not to be confused with <a href="/docs/package-skills">Package Skills</a> — the
skills flutter_edge_ai bundles for <em>your coding assistant</em>, installed with
<code>dart run skills@ get --all</code>. The skills on this page are run by the
<em>on-device model</em> at runtime; those are read by the assistant that writes
your code. There is no bundled skill for <code>flutter_edge_ai_agent</code> itself.
</Info>

## Install

Add the core and the agent package. The agent builds on flutter_edge_ai's
function-calling loop, so you also register an inference engine from an engine
package (e.g. `flutter_edge_ai_litertlm`, which provides the `LiteRtLmEngine()`
used below).

```
dependencies:
  flutter_edge_ai: ^1.12.0
  flutter_edge_ai_agent: ^0.2.7
  flutter_edge_ai_litertlm: ^1.8.7   # an inference engine (LiteRtLmEngine)
```

The agent is **unverified on Web** — nothing disables it, but it has never been driven in a browser. See the note below.

## The four skill mechanisms

A skill is a Markdown file (`SKILL.md`) with YAML frontmatter and one of four
execution mechanisms:

| Skill type | What it does | Android | iOS | macOS | Windows | Web | Linux |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **text-only** | A persona / instruction the model follows directly | ✅ | ✅ | ✅ | ✅ | ❌³ | ✅ |
| **MCP** | Calls remote MCP tools over Streamable HTTP | ✅ | ✅ | ✅ | ✅ | ❌³ | ✅ |
| **native-intent** | Opens an OS surface (mail, SMS, calendar, notification) | ✅ | ✅ | ✅ | ✅ | ❌³ | ✅ |
| **JS** | Runs the skill's JavaScript in a sandboxed headless webview | ✅ | ✅ | ✅ | ✅¹ | ❌³ | ❌² |

¹ Windows JS skills need the
[WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
(pre-installed on Windows 11). ² Linux has no embeddable webview, so JS skills
return an `ErrorResult`; text / native-intent / MCP skills work on Linux.
³ Unverified on Web rather than disabled: nothing in the package gates on the
platform, and the web `.litertlm` path does emit well-formed tool calls. What is
missing is a run of the agent itself (see the note below). On web, native-intent
skills open `mailto:` / `sms:` links and a Google Calendar event page instead of
OS surfaces.

JS skills run in a headless, sandboxed webview. To grant a secure context (so
skills using `crypto.subtle` and other secure-context Web APIs work), the package
serves each skill's assets over a loopback HTTP server (`http://127.0.0.1`, a W3C
"potentially trustworthy" origin) — one mechanism that works identically across
WebView2 / WKWebView / Android WebView, verified on hardware. On the web the skill
runs in a sandboxed `<iframe>`.

> **Web is unverified.** The columns above describe where each skill *type* can
> execute once invoked, and the pieces the loop needs are in place: the web
> `.litertlm` path emits well-formed tool calls and survives the
> call → result → continue round-trip. What is missing is a run of the agent
> itself in a browser — that has never been done, and the loop's context
> balancing leans on `sizeInTokens`, which is approximate on web. On web,
> native-intent skills open `mailto:` / `sms:` links and a Google Calendar event
> page rather than OS surfaces. The agent is verified on **Android, iOS,
> macOS, and Windows** — use those until a web run exists. The example app
> disables the agent on web accordingly.

## Quick start

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

// 1. Register the inference engine (and, optionally, the skill executors).
await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
);

// 2. Install + load a function-calling model (Gemma 4 E2B/E4B recommended).
await FlutterEdgeAi
    .installModel(modelType: ModelType.gemma4, fileType: ModelFileType.litertlm)
    .fromNetwork(gemma4E2BUrl)
    .install();
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);

// 3. Load the bundled starter skills and build the agent session.
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

The package also ships an adaptive UI: `AgentChatView`, `SkillManagerView`,
`McpManagerView`, `SecretEditorDialog`, and `SkillTesterView`.

## Asking about a photo

`ask` takes an optional image, so the model can pick a skill from what it saw
rather than from the text alone:

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

`supportImage: true` is not optional here. Passing `imageBytes` to a session
built without it fails with `ArgumentError` instead of quietly answering as if
there were no image — the engines disagree on the unsupported case, and a silent
drop would give you a confident answer about a photo the model never saw. The
flag is what's checked; that the model is actually multimodal stays your
responsibility (it can't be introspected from Dart) — a text-only model behind
`supportImage: true` will simply ignore the image.

## Bundled starter skills

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

## SKILL.md format

```
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
Call the `run_js` tool with: script name: index.html, data: { field: Type }
```

JS skills additionally ship `scripts/index.html` exposing
`window.ai_edge_gallery_get_result(data, secret)` returning a JSON string
(`{ result | image | webview | error }`). Secrets are injected as the JS
`secret` argument and **never** placed in the model prompt.

## Registering executors

Two equivalent ways to wire executors — pass them per session, or register them
once globally and let `fromModel` read the core registry (mirrors how inference
engines are registered):

```dart
// Global registration (then omit `executors:` on fromModel):
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
- **iOS** — the `create-calendar-event` intent needs a usage description in
  `ios/Runner/Info.plist`:
  ```
  <key>NSCalendarsUsageDescription</key>
  <string>Create calendar events from the agent.</string>
  ```
- **Android** — `flutter_edge_ai_agent` depends on `flutter_local_notifications`,
  which requires core-library desugaring in `android/app/build.gradle(.kts)`.
  This is unconditional: an app that never uses the `schedule_notification`
  intent still fails to build without it. Kotlin DSL below; in Groovy the lines
  are `coreLibraryDesugaringEnabled true` and
  `coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'`.
  ```
  android { compileOptions { isCoreLibraryDesugaringEnabled = true } }
  dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4") }
  ```
- **Android, AGP 9** — `flutter_inappwebview_android` 1.1.3, the latest stable
  release, still calls `getDefaultProguardFile('proguard-android.txt')`, which AGP 9
  rejects while configuring the project, so the app fails to build. Until a stable
  release fixes it, add to `android/gradle.properties`:
  ```
  android.r8.proguardAndroidTxt.disallowed=false
  ```
  AGP deprecates this opt-out and plans to remove it in AGP 10.

<Warning>
Adding a skill grants the model the ability to run that skill's code or open OS
surfaces. Only load skills you trust — `require-secret` skill keys are stored in
memory and passed to the skill, never to the model prompt.
</Warning>

## Third-party attribution

The bundled starter skills and the `SKILL.md` format are derived from
[google-ai-edge/gallery](https://github.com/google-ai-edge/gallery), licensed
under the Apache License 2.0. `flutter_edge_ai_agent` itself is MIT-licensed.
