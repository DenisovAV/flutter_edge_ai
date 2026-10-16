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
³ Not supported on Web — never verified end-to-end, and the example app
disables it (see the note below).

JS skills run in a headless, sandboxed webview. To grant a secure context (so
skills using `crypto.subtle` and other secure-context Web APIs work), the
package serves each skill's assets over a loopback HTTP server
(`http://127.0.0.1`, a W3C "potentially trustworthy" origin) — one mechanism that
works identically across all native engines (WebView2 / WKWebView / Android
WebView), verified on hardware. On web the skill runs in a sandboxed `<iframe>`.

> **Not supported on Web** — never verified end-to-end, and the example app
> disables it. Some pieces the loop needs are in place: the web `.litertlm` path
> does emit well-formed tool calls and does survive the call -> result -> continue
> round-trip (`example/integration_test/web_function_calling_test.dart`). What is
> missing is a run of the agent itself on web — nothing here has been driven
> end-to-end in a browser, and `sizeInTokens` is approximate there, which the
> loop's context balancing depends on. The executors keep web arms (native-intent
> skills open `mailto:` / `sms:` links and a Google Calendar event page rather
> than OS surfaces). The agent is verified on **Android, iOS, macOS, and
> Windows** — use those.

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
  inline results, streamed text, a retry after an empty answer).
- Cross-platform UI: `AgentChatView`, adaptive `SkillManagerView` /
  `McpManagerView`, `McpToolCallPermissionDialog`, `SecretEditorDialog`,
  `SkillTesterView`, and the add-skill disclaimer.
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

The app also depends on an inference engine, here `flutter_edge_ai_litertlm`,
which provides `LiteRtLmEngine`:

```yaml
dependencies:
  flutter_edge_ai: ^2.4.0
  flutter_edge_ai_agent: ^0.3.0
  flutter_edge_ai_litertlm: ^1.14.0
```

```dart
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

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
    // McpSkillExecutor(clients: [...], permissionHook: ...) for remote MCP
    // tools — a call is denied unless the hook allows it or the tool is
    // marked `alwaysAllow`, which skips the hook.
  ],
);

// 4. Mount the chat view.
//   AgentChatView(session: session)
// e.g. "Calculate the hash of hello" or "Show Paris on interactive map".
```

See `packages/flutter_edge_ai/example` (the **Agent Skills** screen) for a
runnable demo.

`AgentSession.fromModel` also takes `modelType` (default `ModelType.gemma4`;
pass yours for any other model), `maxOutputTokens`, `temperature`, `topK`,
`topP` and `randomSeed`. Left unset (since 0.2.8), the engine resolves the
sampling values — on `.litertlm` from the bundle's sampler, then the family's
defaults — instead of the old greedy `topK: 1`. Pass `topK: 1` for greedy
decoding; built-in AI already decodes greedily when it is unset.

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

## Asking with a recording

`ask` also takes the recording itself, for a model with an audio encoder
(Gemma 4 E2B/E4B): the spoken question goes to the model as audio, with no
speech-to-text. Load the model and build the session with `supportAudio: true`:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  supportAudio: true, // loads the audio encoder
);
final session = await AgentSession.fromModel(
  model,
  registry: registry,
  supportAudio: true, // required
);

// wav: a WAV file, 16 kHz mono 16-bit PCM
await for (final event in session.ask('', audioBytes: wav)) {
  // …
}
```

The text may be empty or add to the recording, and an image can go with it. A
`.litertlm` model decodes an audio file, so pass a WAV, not bare PCM samples.
A session built without `supportAudio: true` fails the stream with an
`ArgumentError`, as do empty bytes; nothing reaches the chat history. Audio
input is native-only. After a stopped turn (a cancelled subscription) a
`.litertlm` chat is rebuilt from text, so the recordings of earlier turns are
gone from its context.

## When the model answers nothing

Right after `loadSkill` a small model sometimes ends the turn without a word:
the generation that should answer has no text. The loop then asks once more:
it emits an `EmptyAnswerRetryEvent`, adds a user message to the same chat and
generates again with the same tools. If the answer is still empty, the turn
ends with an `EmptyAnswerEvent` instead of a plain `DoneEvent`.

```dart
final session = await AgentSession.fromModel(
  model,
  registry: registry,
  emptyAfterSkillRetries: 1, // the default; 0 turns the retry off
  emptyAfterSkillNudge: defaultEmptyAfterSkillNudge, // or your own text
);

await for (final event in session.ask(question)) {
  switch (event) {
    case EmptyAnswerRetryEvent(:final nudge):
      // The nudge is in the chat's history now; mirror it if you keep one.
      history.add(Message(text: nudge, isUser: true));
    case EmptyAnswerEvent(:final skillName):
      showError('No answer after loading $skillName');
    case DoneEvent(:final text):
      showAnswer(text);
    default:
      break;
  }
}
```

- `EmptyAnswerEvent` extends `DoneEvent` (with empty `text`), so a `DoneEvent`
  case still matches it; put its case first to tell the two apart.
  `EmptyAnswerRetryEvent` is new in 0.3.0: an exhaustive `switch` over
  `AgentEvent` with no `default` needs a case for it.
- The retry counts against `maxIterations`; when no generation is left there
  is none.
- Only an empty answer right after a `loadSkill` that found its skill is
  retried. One after an intent, JS or MCP result ends with a plain
  `DoneEvent('')`, as before. With 0 retries such a turn still ends with an
  `EmptyAnswerEvent`.
- To stop a turn, flip `ask`'s `isCancelled` or cancel the subscription
  before `chat.stopGeneration()`; a stopped empty generation is otherwise
  retried.
- FunctionGemma apps should pass `emptyAfterSkillRetries: 0`: core clears a
  FunctionGemma chat's history after every text reply, so the nudge reaches a
  blank session and is answered without the question.

## Choosing the system prompt

`AgentSession.fromModel` builds the system prompt from `systemPromptTemplate`,
replacing its `__SKILLS__` placeholder with the selected skills' names and
descriptions (`AgentSession.buildSystemPrompt`). Two templates ship:

- `defaultAgentSystemPrompt` (the default) — Gallery's prompt: look for a skill
  on every request, load it, follow it. For an agent whose requests are mostly
  skill requests.
- `onDemandAgentSystemPrompt` — call `loadSkill` only when a request needs one
  of the skills, and answer everything else directly with no tool call. For an
  assistant that also answers plain questions and questions about a photo, on
  a small model that otherwise calls tools for them (Gemma 4 E2B invented
  intents such as `get_country_capital` under the default).

```dart
final session = await AgentSession.fromModel(
  model,
  registry: registry,
  systemPromptTemplate: onDemandAgentSystemPrompt,
);
```

Neither template is benchmarked here: try both on your model and your
requests. Any template of your own works as long as it keeps `__SKILLS__`.

## SKILL.md format

```yaml
---
name: kebab-case-id
description: One-line summary the model uses to pick the skill.
metadata:
  homepage: https://optional
  require-secret: true
  require-secret-description: how to obtain the key
  my-app-option: true   # any key of your own, see below
---
# Title
## Instructions
Call the `run_js` tool with: skillName: kebab-case-id, data: a JSON string { field: Type }
```

The skill's type comes from the tool its body names, in any letter case:
`run_js`, `runSkill` or `runJs` → JS; `run_intent` or `runIntent` → intent;
`run_mcp` or `runMcp` → MCP (checked in that order); none → text-only. A
`scriptName: other.html` in the body picks a script other than
`scripts/index.html`. The loop takes those spellings as call names too: a call
to `run_js` or Gallery's `runJs` runs as `runSkill`, `run_intent` as
`runIntent`, and `run_mcp` or Gallery's `runMcpTool` as `runMcp`.

Every other key under `metadata:` is kept in `skill.metadata.extra` with its
YAML type: strings, numbers, booleans, and lists and maps as unmodifiable Dart
`List`s and `Map`s. The package reads none of them; your app owns the keys it
reads (for example an opt-in of its own, such as "this skill's result may be
shown as is"). A frontmatter that is not valid YAML is read by a tolerant line
parser instead, which yields strings only.

A text-only skill calls no tool. When the model loads one and then calls
`runIntent` with an intent the app cannot run, the tool result says the skill
calls no tool and asks for the answer from its instructions, rather than
listing the intents it could try next. This works only with
`NativeIntentExecutor` (or with no intent executor at all): an intent executor
of your own has its errors reach the model unchanged.

JS skills additionally ship `scripts/index.html` exposing
`window.ai_edge_gallery_get_result(data, secret)` returning a JSON string
(`{ result | image | webview | error }`). Secrets are injected as the JS
`secret` argument and **never** placed in the model prompt.

The model does not choose which script runs — `run_js` always runs the skill's
own `scripts/index.html` (or the `scriptName` its `SKILL.md` declares), resolved
by `JsSkillExecutor`. Its tool, `runSkill` (the `run_js` spelling SKILL.md uses
is accepted too), therefore takes only `skillName` and `data`, with no
`scriptName`: a required script-name field only made the model invent a
filename, and honouring one would let it name any file under `scripts/`.

## Adding your own intents

`NativeIntentExecutor` runs six built-in intents (`send_email`, `send_text`,
`create_calendar_event`, `read_calendar_events`, `schedule_notification`,
`get_current_date_and_time`). An app adds its own through `handlers:`; the
built-ins keep running next to them. `validators:` checks an intent's
parameters before its handler runs: return null when they are valid,
otherwise the reason, which goes back to the model.

```dart
final intents = NativeIntentExecutor(
  handlers: {
    'start_timer': (params) async {
      final seconds = params['seconds'] as int;
      await timers.start(Duration(seconds: seconds));
      return TextResult('Timer set for $seconds seconds.');
    },
  },
  validators: {
    'start_timer': (params) =>
        params['seconds'] is int ? null : 'missing integer "seconds".',
  },
);
// get_current_date_and_time, send_email, … still run next to start_timer.
```

- An added intent without a validator is not checked: its handler gets the
  decoded parameters as the model sent them.
- A built-in intent keeps its own checks (`validateIntentParams`), also when
  you replace its handler; a validator you give for it runs after them, and
  both must pass.
- A validator for an intent with no handler throws `ArgumentError`.

The skill that uses the intent names it in its body, e.g. ``Call the
`runIntent` tool with intent: start_timer and parameters: {"seconds": 60}``.
When the model also passes the loaded skill's `skillName` to `runIntent`
(small models often do), the intent it names still runs, and the skill is the
one whose secret the executor gets. With `intent` present the executor always
gets a stand-in `Skill(name: intent)` with no instructions or metadata, even
when `skillName` names a registered skill (`runMcp` does the same with
`toolName`).

## Skills or a knowledge base?

An app with skills and a knowledge base can decide before `ask()` whether a
question is for a skill or for the documents, so a device question does not
arrive with documentation excerpts the model then answers from. Core's
experimental `Decider` (`flutter_edge_ai` 2.4.0, `EmbeddingModel.createDecider`)
picks one of several options for an input; this package does not depend on it.

```dart
// Decider is @experimental: its use draws the experimental_member_use warning.
final embedder = await FlutterEdgeAi.getActiveEmbedder();
final route = await embedder.createDecider(
  options: [
    for (final skill in registry.getSelected())
      DeciderOption(skill.name, description: skill.description),
    DeciderOption('docs', description: 'Questions the app documentation answers'),
  ],
  // Descriptions alone cannot calibrate an abstain threshold.
  calibration: const EmbeddingDeciderCalibration.none(),
);

final answer = await route.choose(DeciderInput(EmbeddingInput.text(question)));
final prompt = answer.choice == 'docs'
    ? '${await excerptsFor(question)}\n\n$question'
    : question;
await for (final event in session.ask(prompt)) {
  // …
}
```

A few example requests per option (`examples:`) make the choice far more
accurate than descriptions alone; the `flutter-edge-ai-decisions` package skill
covers options, calibration and abstaining.

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
