---
title: Agent Skills
description: On-device agentic skills for flutter_edge_ai — give the model a SKILL.md catalog and let it pick and run skills through the tool-calling loop, fully offline.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_agent` is an opt-in satellite package that turns the inference
core into an on-device **agent**: you give the model a set of *skills*
(`SKILL.md` files), and it decides which to invoke through flutter_edge_ai's
existing function-calling, runs them, and feeds the results back — fully offline.

It is reverse-engineered from
[google-ai-edge/gallery](https://github.com/google-ai-edge/gallery) (Apache-2.0)
and is **Gallery-compatible**: their `SKILL.md` catalog parses unmodified, and
their JavaScript skills run as-is.

To build an agent step by step — a text-only skill, native intents and your
own JavaScript skill — follow the
[On-Device Agents codelab](/codelabs/on-device-agent-flutter-gemma).

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
  flutter_edge_ai: ^2.5.5
  flutter_edge_ai_agent: ^0.4.1
  flutter_edge_ai_litertlm: ^1.19.1   # an inference engine (LiteRtLmEngine)
```

The agent is **not supported on Web** — never verified end-to-end, and the example app disables it. See the note below.

## The four skill mechanisms

A skill is a Markdown file (`SKILL.md`) with YAML frontmatter and one of four
execution mechanisms:

| Skill type | What it does | Android | iOS | macOS | Windows | Web | Linux |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **text-only** | A persona / instruction the model follows directly | ✅ | ✅ | ✅ | ✅ | ❌³ | ✅ |
| **MCP** | Calls remote MCP tools over Streamable HTTP | ✅ | ✅ | ✅ | ✅ | ❌³ | ✅ |
| **native-intent** | Opens an OS surface (mail, SMS, calendar, notification) | ✅ | ✅ | ✅⁴ | ✅⁴ | ❌³ | ✅⁴ |
| **JS** | Runs the skill's JavaScript in a sandboxed headless webview | ✅ | ✅ | ✅ | ✅¹ | ❌³ | ❌² |

¹ Windows JS skills need the
[WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
(pre-installed on Windows 11). ² Linux has no embeddable webview, so JS skills
return an `ErrorResult`; text / native-intent / MCP skills work on Linux.
³ Not supported on Web — never verified end-to-end, and the example app
disables it (see the note below). ⁴ Only Android and iOS open the OS calendar
editor; macOS, Windows and Linux open a Google Calendar event page in the
browser, and Linux cannot schedule a notification.

JS skills run in a headless, sandboxed webview. To grant a secure context (so
skills using `crypto.subtle` and other secure-context Web APIs work), the package
serves each skill's assets over a loopback HTTP server (`http://127.0.0.1`, a W3C
"potentially trustworthy" origin) — one mechanism that works identically across
WebView2 / WKWebView / Android WebView, verified on hardware. On the web the skill
runs in a sandboxed `<iframe>`.

> **Not supported on Web** — never verified end-to-end, and the example app
> disables it. The web `.litertlm` path emits well-formed tool calls and
> survives the call → result → continue round-trip, but the agent loop itself
> has never run in a browser, and its context balancing leans on
> `sizeInTokens`, which is approximate on web. The agent is verified on
> **Android, iOS, macOS, and Windows**.

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
    .fromNetwork('https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm')
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

`load()` returns one skill per bundled name or throws a `BundledSkillLoadError` (a
`StateError`) whose `failures` names each skill that did not load and why. On web,
a deployment that does not serve `assets/packages/flutter_edge_ai_agent/` causes it.

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

## Asking with a recording

`ask` also takes the recording itself, for a model with an audio encoder
(Gemma 4 E2B/E4B): the spoken question goes to the model as audio, with no
speech-to-text in between, so the model hears the voice itself, not a transcript.

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

- **Both flags.** `supportAudio` on `getActiveModel` creates the engine with its
  audio encoder; on the session it lets the audio through. A session built
  without it fails the stream with `ArgumentError` before anything reaches the
  chat history, because the engine would otherwise drop the audio and the model
  would answer as if nothing was said. Empty bytes fail the same way.
- **A file, not samples.** A `.litertlm` model decodes an audio file, so pass a
  WAV (16 kHz mono 16-bit PCM in a RIFF container), not bare PCM. If you record
  bare PCM, add the 44-byte WAV header first; `VoiceSession.runAudioTurn` hands
  its responder a ready WAV.
- **Text and image.** The text may be empty or add to the recording, and an
  image can go in the same `ask`. Tool results later in the turn carry no media.
- **Native only.** No web engine takes audio input.
- **A stopped turn keeps the recordings (`flutter_edge_ai_litertlm`
  1.15.0).** After a cancelled subscription, a `.litertlm` chat is rewound to
  before the stopped turn and keeps the recordings of earlier turns. With
  1.14.0 and earlier, and on the NPU, it rebuilds its conversation from the
  turns' text, and they are gone from its context.

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

- **Upgrading to 0.3.0.** `EmptyAnswerRetryEvent` is a new `AgentEvent`: an
  exhaustive `switch` over `AgentEvent` with no `default` needs a case for it.
  `EmptyAnswerEvent` extends `DoneEvent` with an empty `text`, so a `DoneEvent`
  case still matches it; put its case first to tell the two apart.
- **The retry counts against `maxIterations`.** When no generation is left,
  there is none.
- **Only after a skill load.** An empty answer right after a `loadSkill` that
  found its skill is retried; one after an intent, JS or MCP result ends with a
  plain `DoneEvent('')`, as before. With 0 retries such a turn still ends with
  an `EmptyAnswerEvent`.
- **Stopping a turn.** Flip `ask`'s `isCancelled` or cancel the subscription
  before `chat.stopGeneration()`; a stopped empty generation is otherwise
  retried.
- **FunctionGemma.** Pass `emptyAfterSkillRetries: 0`: core clears a
  FunctionGemma chat's history after every text reply, so the nudge reaches a
  blank session and is answered without the question.

## Choosing the system prompt

`AgentSession.fromModel` builds the system prompt from `systemPromptTemplate`,
replacing its `__SKILLS__` placeholder with the selected skills' names and
descriptions. Two templates ship:

- `defaultAgentSystemPrompt` (the default) — Gallery's prompt: look for a skill
  on every request, load it, follow it. For an agent whose requests are mostly
  skill requests.
- `onDemandAgentSystemPrompt` — call `loadSkill` only when a request needs one
  of the skills, and answer everything else directly with no tool call. For an
  assistant that also answers plain questions and questions about a photo, on
  a small model that otherwise calls tools for them.

```dart
final session = await AgentSession.fromModel(
  model,
  registry: registry,
  systemPromptTemplate: onDemandAgentSystemPrompt,
);
```

Neither template is benchmarked here: try both on your model and your
requests. Any template of your own works as long as it keeps `__SKILLS__`.

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
| `create-calendar-event` | intent | Open the calendar event editor (on desktop, a Google Calendar page) |
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
  my-app-option: true   # any key of your own, see below
---
# Title
## Instructions
Call the `run_js` tool with: skillName: kebab-case-id, data: a JSON string { field: Type }
```

The skill's type comes from the tool its body names, in any letter case:
`run_js`, `runSkill` or `runJs` → JS; `run_intent` or `runIntent` → intent;
`run_mcp` or `runMcp` → MCP (checked in that order); none → text-only. The loop
takes those spellings as call names too: a call to `run_js` or Gallery's
`runJs` runs as `runSkill` (which takes `skillName` and `data`), `run_intent`
as `runIntent`, and `run_mcp` or Gallery's `runMcpTool` as `runMcp`.

Every other key under `metadata:` is kept in `skill.metadata.extra` with its
YAML type (strings, numbers, booleans, lists and maps). The package reads none
of them; your app owns the keys it reads. A frontmatter that is not valid YAML
is read by a tolerant line parser instead, which yields strings only.

A text-only skill calls no tool. When the model loads one and then calls
`runIntent` with an intent the app cannot run, the tool result says so and
asks for the answer from the skill's instructions. This works only with
`NativeIntentExecutor` (or with no intent executor at all): an intent executor
of your own has its errors reach the model unchanged.

JS skills additionally ship a script in `scripts/` — `index.html`, unless the
body names another (`scriptName: query.html`) — exposing
`window.ai_edge_gallery_get_result(data, secret)` returning a JSON string
(`{ result | image | webview | error }`). Secrets are injected as the JS
`secret` argument and **never** placed in the model prompt.

## Adding your own intents

`NativeIntentExecutor` runs six built-in intents (`send_email`, `send_text`,
`create_calendar_event`, `read_calendar_events`, `schedule_notification`,
`get_current_date_and_time`); `schedule_notification` runs only once the app
turns it on (see [Setup](#setup)), and the built-in `read_calendar_events`
reads no calendar: it answers with an error that asks for a handler of your
own. Add your own through `handlers:`; the
built-ins keep running next to them. `validators:` checks an intent's parameters before
its handler runs: null when they are valid, otherwise the reason, which goes
back to the model.

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
```

An added intent without a validator is not checked. A built-in intent keeps its
own checks, also when you replace its handler; a validator you give for it runs
after them, and both must pass. A validator for an intent with no handler
throws `ArgumentError`. When the model passes the loaded skill's `skillName` to
`runIntent` as well, the intent it names still runs. With `intent` present the
executor always gets a stand-in `Skill(name: intent)` with no instructions or
metadata, even when `skillName` names a registered skill (`runMcp` does the
same with `toolName`).

## Skills or a knowledge base?

An app with skills and a knowledge base can decide before `ask()` whether a
question is for a skill or for the documents, so a device question does not
arrive with documentation excerpts the model then answers from. The
experimental [`Decider`](/docs/decisions) (`flutter_edge_ai` 2.4.0,
`EmbeddingModel.createDecider`) picks one of several options for an input:
one option per skill (its description, plus a few example requests), one for
the documents. The agent package does not depend on it.

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

Most skills need no platform setup. The intents open OS surfaces, and those
need declarations in the app:

- **Android 11 and newer** — `send_email` and `send_text` ask url_launcher
  whether an app can open the link, and `create_calendar_event` asks
  `add_2_calendar` whether a calendar can insert the event. Both answers are
  "no" unless the app declares them in `android/app/src/main/AndroidManifest.xml`,
  as a child of `<manifest>`; the mail and SMS intents then report that no app
  is available, the calendar one that it could not open the event editor:
  ```
  <queries>
    <intent>
      <action android:name="android.intent.action.VIEW" />
      <data android:scheme="mailto" />
    </intent>
    <intent>
      <action android:name="android.intent.action.VIEW" />
      <data android:scheme="sms" />
    </intent>
    <intent>
      <action android:name="android.intent.action.INSERT" />
      <data android:mimeType="vnd.android.cursor.dir/event" />
    </intent>
    <intent>
      <action android:name="android.intent.action.INSERT" />
      <data android:mimeType="vnd.android.cursor.item/event" />
    </intent>
  </queries>
  ```
- **iOS** — the same check for mail and SMS, plus `add_2_calendar`'s usage
  descriptions (it recommends the contacts one: Apple's event editor offers
  location autocomplete), in `ios/Runner/Info.plist`:
  ```
  <key>LSApplicationQueriesSchemes</key>
  <array>
    <string>mailto</string>
    <string>sms</string>
  </array>
  <key>NSCalendarsUsageDescription</key>
  <string>Create calendar events from the agent.</string>
  <key>NSContactsUsageDescription</key>
  <string>Suggest locations for calendar events.</string>
  ```
- **Notifications** — since 0.4.0 `schedule_notification` is off until the
  app turns it on. The app sets up `flutter_local_notifications` itself and
  passes `NotificationIntentSettings`; without them the intent returns an error
  that says so and makes no plugin call. The agent never calls `initialize`: a
  second call would replace the app's notification callbacks, default icon and
  presentation options. It never asks for a permission either.
  ```
  // Once at startup, with the app's own callbacks and default icon.
  // initialize throws ArgumentError on a platform whose settings are missing.
  await FlutterLocalNotificationsPlugin().initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('app_icon'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      windows: WindowsInitializationSettings(
        appName: 'My App',
        appUserModelId: 'Com.Example.MyApp',
        guid: 'a GUID of your own',
      ),
    ),
  );

  final intents = NativeIntentExecutor(
    notifications: const NotificationIntentSettings(
      androidSmallIcon: 'ic_reminder', // optional; null = initialize's icon
    ),
  );
  ```
  Passing the settings without calling `initialize` crashes the app: on macOS
  when the intent schedules, on Android when a reminder without
  `androidSmallIcon` fires. An empty string in the settings throws
  `ArgumentError` when the executor is built.
  - Before it schedules, the intent checks the permissions and refuses, with a
    reason the model can pass on, when notifications are off for the app
    (Android `areNotificationsEnabled()`; iOS and macOS `checkPermissions()`
    with neither full nor provisional permission), when the user turned off its
    Android channel, or, on Android 12 and newer, when the app may not schedule
    exact alarms. Asking is the app's job: `requestNotificationsPermission()`
    on Android 13 and newer, `DarwinInitializationSettings()` or
    `requestPermissions()` on iOS and macOS. With provisional permission the
    reminder arrives quietly, with no banner or sound, and the intent's answer
    says so.
  - On Android the intent schedules an exact alarm (`exactAllowWhileIdle`). The
    app declares `SCHEDULE_EXACT_ALARM` in its manifest, and on Android 14 and
    newer the user must also grant it: it is off by default there, and the app
    asks with `requestExactAlarmsPermission()`. `USE_EXACT_ALARM` (Android 13
    and newer) needs no grant, but Google Play allows it only for alarm and
    calendar apps. With `NotificationIntentSettings(androidExactAlarm: false)`
    the intent schedules `inexactAllowWhileIdle` instead, which needs neither
    and may fire up to an hour late (later under battery saver or Doze); the
    intent never switches on its own. The plugin's receivers and
    `RECEIVE_BOOT_COMPLETED` go in the manifest as well: see
    [flutter_local_notifications' Android setup](https://pub.dev/packages/flutter_local_notifications#androidmanifestxml-setup).
    Its icon must survive resource shrinking in a release build: a drawable
    named only from Dart needs a `keep.xml`.
  - On iOS the plugin's setup also needs one line in `AppDelegate.swift`, in
    `didFinishLaunchingWithOptions`; without it iOS shows no reminder while the
    app is in the foreground:
    ```
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    ```
  - The intent refuses on the web and on Linux, where the plugin cannot
    schedule a notification, and a date and time that have already passed. A
    time without a date that has passed today is scheduled for tomorrow. On
    Windows it has no permission to check and relies on the app's `initialize`.
  - It schedules the instant in UTC and leaves the time zone database and
    `tz.local` to the app.
  - `notifications:` together with a `schedule_notification` entry in
    `handlers:` throws `ArgumentError`.
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
- **Windows** — JS skills require the
  [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
  (pre-installed on Windows 11; bundle the bootstrapper for Windows 10). The
  webview plugin fetches its native dependencies with the
  [NuGet CLI](https://learn.microsoft.com/nuget/install-nuget-client-tools)
  while the app builds, so `nuget` has to be on the `PATH`.

<Warning>

Adding a skill grants the model the ability to run that skill's code or open OS
surfaces. Only load skills you trust — `require-secret` skill keys are stored in
memory and passed to the skill, never to the model prompt.

</Warning>

## Third-party attribution

The bundled starter skills and the `SKILL.md` format are derived from
[google-ai-edge/gallery](https://github.com/google-ai-edge/gallery), licensed
under the Apache License 2.0. `flutter_edge_ai_agent` itself is MIT-licensed.
