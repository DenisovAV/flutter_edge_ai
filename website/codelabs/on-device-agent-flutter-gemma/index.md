author: Sasha Denisov
summary: On-Device Agents in Flutter — SKILL.md Skills with Gemma 4
id: on-device-agent-flutter-gemma
categories: flutter, ai, gemma, agents
environments: android, ios, macos, windows
status: Published

# On-Device Agents in Flutter: SKILL.md Skills with Gemma 4

## Overview
Duration: 3

### What you'll build

An assistant that runs on the device and does things instead of only talking
about them. It reads the time from the device clock, opens your calendar with
an event filled in, drafts an email, splits a restaurant bill exactly and
draws a QR code. The model is Gemma 4 E2B and it runs locally: no server sees
your requests or writes the answers. Three things do reach the network: the
model is downloaded once, a skill that hands off to another app passes it what
you asked for — the browser, on desktop, for a calendar event — and the bundled
QR skill loads its drawing library from a CDN.

The assistant is an **agent**: a model in a loop that can use **skills**. A
skill is a folder with a `SKILL.md` — a name, a one-line description and
instructions — and, for some kinds, a little code. You will write two skills
of your own and use five that `flutter_edge_ai_agent` bundles.

### What you'll learn

* What a skill is, and how the agent finds the right one without reading all
  of them on every turn
* The kinds of skill: instructions only, native intents, JavaScript, and MCP
* How to write a skill and ship it in your app's assets
* How the agent reports what it did, step by step
* What each platform needs: Android desugaring and loopback traffic, the
  macOS server entitlement, the iOS calendar usage description

### What you'll need

* Flutter 3.44 or newer
* A device to run on, with about 3 GB free for the model:
  * an Android phone with 6 GB of RAM or more, Android 11 (API 30) or newer —
    a phone, not an x86 emulator: the runtime ships for arm64 only
  * an iPhone, with an Apple Developer team to sign it (Step 1)
  * a Mac with Apple Silicon
  * a Windows PC on x86_64, with the NuGet CLI (Step 2)
* The [Function Calling codelab](/codelabs/function-calling-flutter-gemma)
  helps: an agent is a function-calling loop. It is not required.

`flutter_edge_ai_agent` runs on Android, iOS, macOS and Windows. On Linux the
text, intent and MCP skills work and JavaScript skills do not. It is not
supported on the web, and the model this codelab downloads is a native one;
the app builds for the web and says so instead of downloading it.

### Get the code

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/on-device-agent-flutter-gemma
ls
```

```text
step_01_starter/      a plain chat on Gemma 4 E2B — no agent yet
step_02_first_skill/  after Step 2 — the agent and a text-only skill
step_03_intents/      after Step 3 — plus three native-intent skills
complete/             after Step 4 — plus JavaScript skills
```

Each folder is a complete Flutter app. If you get lost, diff your work against
the folder for the step you are on.

## Step 1: A model that only talks
Duration: 6

Open `step_01_starter` and run it:

```bash
cd step_01_starter
flutter run
```

The first screen downloads Gemma 4 E2B, 2.59 GB, from Hugging Face. The
repository is ungated, so no token is needed. It happens once: the next launch
finds the file and goes straight to the chat.

On an iPhone, open `ios/Runner.xcworkspace` in Xcode first. Under **Signing &
Capabilities** pick your own team and change the bundle identifier: the one
the app ships with, `dev.fluttergemma.agent`, can be registered to one team
only. The app also carries `ios/Runner/Runner.entitlements`, which lifts the
memory ceiling iOS puts on an app; 2.6 GB of weights do not fit under the
default one.

On Android the app needs Android 11 (API 30) or newer:
`android/app/build.gradle.kts` sets `minSdk = 30`, because the LiteRT-LM
runtime calls C library functions older versions of Android do not have.

The chat is the plain one from the getting-started codelab. `lib/chat_page.dart`
opens the model and a chat:

```dart
final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final chat = await inference.createChat(
  modelType: widget.model.modelType,
  maxOutputTokens: 512,
);
```

`maxTokens` is the context window — prompt, history and reply together — not
the length of the answer. 4096 leaves room for what an agent adds to the
conversation in the next steps.

Now ask it two things:

```text
What time is it?
```

```text
Put lunch with Anna tomorrow at 1 pm in my calendar.
```

The answers are fluent and wrong. The model has no clock, so it guesses a
time or explains that it cannot know. It has no calendar either, so it either
says it cannot help or, worse, says it added the event. Nothing happened.

A model on its own can only produce text. To act, it needs code the app runs
on its behalf, and a way to know that code exists. That is what the rest of
this codelab adds.

## Step 2: The agent and your first skill
Duration: 12

### What a skill is

A skill is a folder with a `SKILL.md` file:

```text
assets/skills/packing-list/
  SKILL.md
```

The file has two parts. The front matter says what the skill is for; the body
says how to do it. Create
`assets/skills/packing-list/SKILL.md`:

```markdown
---
name: packing-list
description: Builds a packing list for a trip. Use when the user asks what to pack, or names a trip and its length.
---

# Packing list

## Instructions

You help the user pack for one trip.

1. You need three facts: where they are going, for how many nights, and what
   they will mostly do there (work, hiking, beach, a city). If one is missing,
   ask for it in a single short question and stop.
2. Once you have all three, answer with the list and nothing else. Group it
   under these headings, in this order: **Documents**, **Clothes**,
   **Toiletries**, **Electronics**, **For the activity**.
3. Clothes: one set per night, plus one spare. Write the number next to each
   item, for example `T-shirts × 4`.
4. Put passport and tickets first under Documents when the trip crosses a
   border; otherwise an ID card.
5. Keep each item to a few words. No explanations, no closing remarks.
```

This is a **text-only** skill: instructions and nothing to run. The model
reads them and follows them. The `name` must match the folder's name, and the
`description` is the most important line in the file, for a reason the next
section explains.

### How the agent finds a skill

An app can have dozens of skills, and their instructions would not fit in the
model's context together. So the agent works in two stages:

1. The system prompt lists every skill by **name and description only**.
2. When a request fits one, the model calls the `loadSkill` tool with its
   name, gets the full instructions back, and follows them.

The description is all the model sees when it decides. "Builds a packing list
for a trip" plus when to use it gets the skill picked; "Packing helper" does
not. Write descriptions the way you would write a search query you want to
match.

### Add the agent

Add the package to `pubspec.yaml`, and list the skill's folder so Flutter
bundles it:

```yaml
dependencies:
  flutter_edge_ai: ^2.4.0
  flutter_edge_ai_litertlm: ^1.14.0
  flutter_edge_ai_agent: ^0.4.0

flutter:
  assets:
    - assets/skills/packing-list/
```

On Android, the agent package brings `flutter_local_notifications`, which
needs core library desugaring. In `android/app/build.gradle.kts`:

```kotlin
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

and, because the webview package it uses still calls a ProGuard default that
AGP 9 rejects, in `android/gradle.properties`:

```properties
android.r8.proguardAndroidTxt.disallowed=false
```

On Windows, that webview package downloads the WebView2 SDK at build time with
the NuGet CLI, which Visual Studio does not put on the `PATH`. Install it
(`winget install Microsoft.NuGet`) and open a new terminal, or the build stops
with `Nuget is not installed!`.

### Load your skills and open the agent

Create `lib/skills.dart`. The package loads the skills it bundles itself;
skills your app ships are read with the same parser:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';

const appSkillNames = ['packing-list'];

Future<List<Skill>> loadAppSkills({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final skills = <Skill>[];
  for (final name in appSkillNames) {
    final path = 'assets/skills/$name/SKILL.md';
    final Skill skill;
    try {
      skill = parseSkillMd(await assets.loadString(path));
    } catch (error) {
      throw StateError('$path could not be read: $error');
    }
    if (skill.name != name) {
      throw StateError(
        '$path is named "${skill.name}"; the name must match the folder.',
      );
    }
    skills.add(skill);
  }
  return skills;
}

Future<AgentSession> openAgent(
  InferenceModel model, {
  required ModelType modelType,
}) async {
  final registry = SkillRegistry()
    ..addAll(await loadAppSkills(), selected: true);
  return AgentSession.fromModel(
    model,
    registry: registry,
    executors: [TextSkillExecutor()],
    modelType: modelType,
    maxOutputTokens: 512,
  );
}
```

Three objects:

* `SkillRegistry` holds the skills and which of them are switched on.
  `selected: true` switches them on; the agent lists only selected skills.
* An **executor** runs one kind of skill. `TextSkillExecutor` answers for
  text-only skills. The next steps add more.
* `AgentSession.fromModel` opens a chat on the model with the agent's tools
  and the skill list in the system prompt. `modelType` is the model's family —
  it decides how tool calls are written and read — so pass the one of the
  model you loaded.

### Show what the agent does

`AgentSession.ask` does not return text. It returns a stream of events,
because an agent's turn is several things in a row: it loads a skill, calls a
tool, reads the result and answers. `lib/agent_page.dart` replaces the chat
page. Most of it is the chat page over again — loading, the composer, the
bubbles, closing what it opened — so copy it from
`step_02_first_skill/lib/agent_page.dart` and read the parts that are new.

The page sends a question and folds each event into the reply bubble:

```dart
await for (final event in agent.ask(text, isCancelled: () => !mounted)) {
  if (!mounted) return;
  setState(() => _apply(reply, event));
}
```

`isCancelled` stops the loop at its next step once the page is gone, instead
of letting it run a tool — open a mail composer — for nobody.

```dart
void _apply(_Turn reply, AgentEvent event) {
  if (event is! TextChunkEvent && event is! DoneEvent) reply.text = '';
  switch (event) {
    case SkillLoadEvent(:final skillName, :final found):
      if (found) reply.steps.add('📖 loaded skill $skillName');
    case ToolCallEvent(:final toolName, :final args):
      reply.steps.add('🔧 $toolName $args');
    case ToolResultEvent(:final result):
      if (result is! ErrorResult) reply.steps.add('↩️ ${_describe(result)}');
    case TextChunkEvent(:final text):
      reply.text += text;
    case DoneEvent(:final text):
      reply.text = text;
      if (text.trim().isEmpty) {
        reply.steps.add('∅ the model ended the turn without an answer');
      }
    case EmptyAnswerRetryEvent():
      reply.steps.add('↻ asked again');
    case MaxIterationsEvent(:final iterations):
      reply.steps.add('⏹ stopped after $iterations steps');
    case AgentErrorEvent(:final message):
      reply.steps.add('⚠️ $message');
  }
}
```

`AgentEvent` is sealed, so the switch is exhaustive: a new kind of event in a
later version of the package is a compile error here, not a step that goes
missing from the screen. `EmptyAnswerRetryEvent` is one, from 0.3.0: the model
loaded a skill and then said nothing, and the package asks it once more.

Three rules shape it:

* **Every event but text is a step.** Loading a skill, calling a tool, reading
  its result: text that streamed in before one of them was the model working
  toward that step — or the call itself in raw form — not the answer, so the
  text starts over.
* **`DoneEvent` is the answer.** It carries the text after the last step,
  whole. When it is empty, the bubble says so instead of sitting there blank.
* **One line per failure.** A skill that is not found, or a tool that fails,
  is followed by an `AgentErrorEvent`; the bubble shows that one and skips
  the duplicate.

The page keeps one session for the whole conversation, so a skill can ask a
follow-up question and get the answer. Everything stays in its context window,
though — each loaded skill, each tool result — and a few skill turns fill 4096
tokens. A **New conversation** button starts over without reloading the model:

```dart
Future<void> _newConversation() async {
  final agent = _agent;
  if (agent == null || _busy) return;
  await agent.chat.clearHistory();
  if (mounted) setState(_turns.clear);
}
```

Closing an `AgentSession` closes only its chat; the model is the page's, so
the page closes both, the agent first.

Point the gate in `lib/main.dart` at `AgentPage` instead of `ChatPage`, and
run. Then ask:

```text
I'm going to Lisbon for 4 nights for a conference. What should I pack?
```

Under the reply you will see `📖 loaded skill packing-list`, and the answer
follows the skill's rules: the five headings, clothes for four nights plus a
spare. Then ask something unrelated, such as "Tell me a joke", and watch the
steps: there should be none. Both times the model decided from the skill
descriptions alone, which is why a vague description shows up here first.

If you want to see your work from this step, compare it with
`step_02_first_skill`.

## Step 3: Let the agent act
Duration: 10

Instructions change what the model says. To change what happens on the
device, a skill has to call something.

### Native intents

`flutter_edge_ai_agent` has a fixed set of **intents** — operations it knows
how to run on each platform:

| Intent | What happens |
|---|---|
| `get_current_date_and_time` | returns the device's date and time |
| `create_calendar_event` | opens the calendar's event editor, filled in |
| `send_email` | opens the mail composer with recipient, subject and text |
| `send_text` | opens the SMS composer |
| `schedule_notification` | schedules a local notification, once the app turns it on |
| `read_calendar_events` | answers only if you inject a handler for it |

This app sets up the three its skills use. `send_text` needs the `sms` scheme
declared the way `mailto` is below, and `schedule_notification` stays off
until the app initializes `flutter_local_notifications` itself and passes
`NativeIntentExecutor(notifications:)` (see the [agent docs](/docs/agent#setup)).

An intent that changes something opens an OS screen and stops there. The
model fills in the event or the email; the user presses Save or Send. An
agent that can draft is useful; one that can send in your name without asking
is a liability.

The package bundles skills that use these intents. A skill whose instructions
tell the model to call `run_intent` is an **intent skill**, and
`NativeIntentExecutor` runs it. In `lib/skills.dart`:

```dart
const packageSkillNames = [
  'get-current-time',
  'create-calendar-event',
  'send-email',
];

Future<AgentSession> openAgent(
  InferenceModel model, {
  required ModelType modelType,
}) async {
  final bundled = AssetSkillSource(names: packageSkillNames);
  final registry = SkillRegistry()
    ..addAll(await loadAppSkills(), selected: true)
    ..addAll(await bundled.load(), selected: true);
  return AgentSession.fromModel(
    model,
    registry: registry,
    executors: [TextSkillExecutor(), NativeIntentExecutor()],
    modelType: modelType,
    maxOutputTokens: 512,
  );
}
```

`AssetSkillSource` reads the skills from the package's own assets; you do not
copy them into your app. If a name is not one the package bundles, `load()`
throws and says which.

### Platform setup

On iOS 15 and 16 the calendar editor asks for calendar access first, and iOS
stops an app that asks without a usage description. (From iOS 17 the editor
opens without asking.) Its location field suggests places from the contacts,
and `add_2_calendar` warns that the app may crash there without a contacts
usage description. Add both to `ios/Runner/Info.plist`:

```xml
<key>NSCalendarsUsageDescription</key>
<string>The agent opens the calendar's event editor for events you ask it to create.</string>
<key>NSContactsUsageDescription</key>
<string>The calendar's event editor suggests locations from your contacts.</string>
```

The mail composer opens through a `mailto:` link, and the agent first asks
whether any app can open one. On Android 11 and newer, and on iOS, that
answer is "no" unless the app declares the scheme — the skill would report
that no mail app is installed. The calendar works the same way on Android:
the editor opens only if the app can see a calendar that inserts events. In
`android/app/src/main/AndroidManifest.xml`, inside `<queries>`:

```xml
<intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="mailto"/>
</intent>
<intent>
    <action android:name="android.intent.action.INSERT"/>
    <data android:mimeType="vnd.android.cursor.dir/event"/>
</intent>
<intent>
    <action android:name="android.intent.action.INSERT"/>
    <data android:mimeType="vnd.android.cursor.item/event"/>
</intent>
```

and in `ios/Runner/Info.plist`:

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>mailto</string>
</array>
```

On desktop — macOS, Windows and Linux — the calendar event opens as a Google
Calendar template in the browser, since there is no system event editor to
call.

### Try it

```text
What time is it?
```

```text
Add lunch with Anna tomorrow at 1 pm for an hour to my calendar.
```

```text
Email bob@example.com that I'm running ten minutes late.
```

The steps under each reply show the skill loading and the `runIntent` call
with its arguments. The answer to the first question is now the device's
time, not a guess. The second and third open the editor and the composer, and
wait for you.

Watch the steps closely and you will likely see a wrong turn. In test runs on
a Mac, Gemma 4 E2B loaded `get-current-time` and then called `runSkill` with
the skill's name, twice, instead of `runIntent` with the intent. The tool
answered with an error that lists the allowed intents; the model read it and
called `runIntent get_current_date_and_time` on its next try. Errors go back to the
model as results, and recovering from them is part of the loop — which is
also why the agent stops after `maxIterations` (10 by default) rather than
trying forever.

## Step 4: Write a JavaScript skill
Duration: 14

Some answers should be computed, not generated. A 2B model asked to split
84 dollars three ways with a 15% tip will usually get it right and sometimes
not, and it will sound equally sure both times. A **JavaScript skill** hands
the computation to code.

### The contract

A JS skill is a `SKILL.md` that tells the model to call `run_js`, plus a page
in `scripts/`. The agent loads the page in a headless webview and calls one
function on it:

```js
window['ai_edge_gallery_get_result'] = async (data, secret) => { ... };
```

`data` is the JSON string the model wrote. The function returns a JSON string
with exactly one of:

* `result` — text the model reads and answers from
* `image` — `{"base64": "data:image/png;base64,…"}`, shown to the user
* `webview` — `{"url": "https://…", "iframe": true}`, a page to show
* `error` — what went wrong, which the model reads too

The package tells a JS skill from a text-only one by its instructions: they
have to say `run_js`. A `SKILL.md` that names the tool `runSkill` instead —
the name the steps under a reply show — loads as text-only, and its script
never runs.

The name is the one Google's AI Edge Gallery uses, so its skills run here
unmodified.

### The skill

Create `assets/skills/tip-split/SKILL.md`:

```markdown
---
name: tip-split
description: Splits a restaurant bill, with tip, between several people. Use when the user asks how much each person pays.
---

# Tip split

## Examples

* "Split 84 dollars between 3 of us with a 15% tip"
* "We are four, the bill is 120 euros, 10 percent tip — how much each?"

## Instructions

Never do the arithmetic yourself. Call the `run_js` tool with:

- skillName: `tip-split`
- data: a JSON string with these fields
  - total: the bill before tip, as a number
  - people: how many people share it, as a whole number
  - tip_percent: the tip in percent, as a number; 0 if the user gave none
  - no other fields

Then tell the user what each person pays, using the numbers the tool returned.
```

The instructions describe the JSON the script expects, field by field. That
is the whole interface between the model and your code: if a field is not
described here, the model will not send it.

Then `assets/skills/tip-split/scripts/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <title>Tip split</title>
  </head>
  <body>
    <script src="index.js"></script>
  </body>
</html>
```

and `assets/skills/tip-split/scripts/index.js`:

```js
window['ai_edge_gallery_get_result'] = async (data) => {
  try {
    const input = JSON.parse(data);
    const extra = Object.keys(input).filter(
      (key) => !['total', 'people', 'tip_percent'].includes(key));
    if (extra.length > 0) {
      return fail(`unexpected field ${extra.join(', ')}; the fields are ` +
        'total, people and tip_percent');
    }
    const total = toNumber(input.total);
    const people = toNumber(input.people);
    const tipPercent = toNumber(input.tip_percent);
    if (!(total > 0 && total < 1e9)) {
      return fail('"total" must be a number above 0 and below 1000000000');
    }
    if (!Number.isInteger(people) || people < 1 || people > 1000) {
      return fail('"people" must be a whole number from 1 to 1000');
    }
    if (!(tipPercent >= 0 && tipPercent <= 100)) {
      return fail('"tip_percent" must be a number from 0 to 100; send 0 ' +
        'when the user gave no tip');
    }
    const billCents = Math.round(total * 100);
    const totalCents = Math.round(total * (100 + tipPercent));
    const eachCents = Math.floor(totalCents / people);
    const extraCents = totalCents - eachCents * people;
    let result = `Each of ${people} pays ${money(eachCents)} ` +
      `(bill ${money(billCents)} + tip ${money(totalCents - billCents)} = ` +
      `${money(totalCents)}).`;
    if (extraCents > 0) {
      result += extraCents === 1
        ? ' One of them pays one cent more.'
        : ` ${extraCents} of them pay one cent more.`;
    }
    return JSON.stringify({result});
  } catch (e) {
    return fail(`could not split the bill: ${e.message}`);
  }
};

function toNumber(value) {
  if (typeof value === 'number') return value;
  if (typeof value === 'string' && value.trim() !== '') return Number(value);
  return NaN;
}

function money(cents) {
  return (cents / 100).toFixed(2);
}

function fail(message) {
  return JSON.stringify({error: message});
}
```

Nothing is guessed. A tip sent under another key and read as 0, or 2.5 people
rounded to 3, is a plausible wrong answer the model would pass on with
confidence; instead the `error` names the field, and the model calls again.
Numbers sent as strings — `"84"` — are accepted. The money is counted in
cents, so the shares add up to the bill, and a cent that does not divide
evenly is said, not rounded away.

List both folders in `pubspec.yaml` — asset folders are not recursive:

```yaml
    - assets/skills/tip-split/
    - assets/skills/tip-split/scripts/
```

### Run JS skills

Add `'tip-split'` to `appSkillNames`, two bundled JS skills to
`packageSkillNames`:

```dart
const appSkillNames = ['packing-list', 'tip-split'];

const packageSkillNames = [
  'get-current-time',
  'create-calendar-event',
  'send-email',
  'calculate-hash',
  'qr-code',
];
```

and a `JsSkillExecutor`, which needs to know where each skill's page is: in
the package's assets for a bundled skill, in yours for your own.

```dart
executors: [
  TextSkillExecutor(),
  NativeIntentExecutor(),
  JsSkillExecutor(sourceFor: (skill) => _jsSourceFor(skill, bundled)),
],
```

```dart
JsSkillSource _jsSourceFor(Skill skill, AssetSkillSource bundled) =>
    packageSkillNames.contains(skill.name)
    ? bundled.jsSkillSourceFor(skill)
    : JsSkillSource.asset(
        'assets/skills/${skill.name}/scripts/${skill.scriptName}',
      );
```

`qr-code` answers with an image. The model only learns that an image was
made; showing it is the app's job. In `agent_page.dart`, keep the bytes when
a result arrives and draw them in the bubble:

```dart
case ToolResultEvent(:final result):
  if (result is! ErrorResult) reply.steps.add('↩️ ${_describe(result)}');
  if (result is ImageResult) reply.images.add(result.bytes);
```

The `images` list on `_Turn` and the `Image.memory` loop in the bubble are in
`complete/lib/agent_page.dart`.

### Platform setup

The executor serves the skill's page from a small HTTP server inside the
app, on `127.0.0.1`, and the webview loads it from there. That traffic stays
on the device — what the page then fetches is up to the page: the bundled
`qr-code` loads its QR library from cdnjs, so it needs the network. Two
platforms need to be told the loopback server is allowed.

**Android** blocks cleartext HTTP by default. Allow it for the loopback
address only. Create `android/app/src/main/res/xml/network_security_config.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
        <domain includeSubdomains="false">localhost</domain>
    </domain-config>
</network-security-config>
```

and point the application at it in `AndroidManifest.xml`:

```xml
<application
    android:networkSecurityConfig="@xml/network_security_config"
    ...>
```

**macOS** apps are sandboxed, and opening a listening socket needs the
server entitlement. Flutter's template puts it in `DebugProfile.entitlements`
only, so JS skills work in `flutter run` and fail in a release build. Add it
to `macos/Runner/Release.entitlements` as well:

```xml
<key>com.apple.security.network.server</key>
<true/>
```

**Windows** needs the WebView2 runtime: Windows 11 has it, and on Windows 10
install Microsoft's Evergreen runtime. **iOS** needs nothing.

### Try it

```text
Split a bill of 84 dollars between 3 people with a 15% tip.
```

```text
Calculate the hash of the text: hello
```

```text
Make a QR code for https://flutteredge.ai
```

The first answer says 32.20 each, and the steps show `runSkill` with the JSON
the model wrote and the line your script returned. The QR code appears in the
bubble — when the device is online, since its library comes from a CDN.

A JS skill can also need an API key — a weather service, say. Its `SKILL.md`
declares `require-secret: true` under `metadata`. The app stores the key with
`SecretStore.set(skillName, key)` (`SecretEditorDialog` asks the user for it)
and passes the store to `AgentSession.fromModel(secretStore: ...)`; the agent
hands the key to your function as `secret`. It never goes into the prompt. In
0.3.0 it does go into the page the loopback server sends to the webview, and
that server does not check who asks while the skill runs: treat such a key as
one another app on the same device could read.

## Step 5: Skills on a server, with MCP
Duration: 5

The last kind of skill runs elsewhere. An **MCP** skill calls a tool on a
[Model Context Protocol](https://modelcontextprotocol.io) server over
Streamable HTTP — your notes service, a ticket system, anything that exposes
an MCP endpoint. The model still runs on the device; only the tool call goes
over the network.

This codelab's app does not include it, because it needs a server of your
own. With one, the wiring is a client and an executor:

```dart
final client = McpClient(
  config: const McpServerConfig(url: 'https://your-server.example/mcp'),
);
await client.connect();

final mcp = McpSkillExecutor(
  clients: [client],
  permissionHook: (request) async {
    final answer = await McpToolCallPermissionDialog.show(
      context,
      toolName: request.toolName,
      argumentJson: request.input,
    );
    return answer != McpPermissionResult.deny;
  },
);
```

and a `SKILL.md` whose instructions tell the model to call `run_mcp` with the
server's tool name and the input it expects. Add `mcp` to the executors.
Closing the agent does not close the client, which holds its own HTTP
connection: call `client.close()` where the page closes the agent.

Mind the `permissionHook`. Without one, the executor **denies every call**:
a tool on a server can change things outside the device, and the default is
that the user agrees to each call. `McpToolCallPermissionDialog` shows the
tool and its arguments. This hook allows the one call it was asked about,
whichever allow button the user pressed; it does not remember anything. What
skips the prompt for good is the tool's `alwaysAllow` flag in the server's
`McpServerConfig`, and `McpManagerView` is a ready-made screen where the user
connects servers and switches that flag per tool.

## What's next
Duration: 2

### What you built

* An agent on Gemma 4 E2B that picks a skill from its description and loads
  only the one it needs
* A text-only skill, three intent skills, your own JavaScript skill and two
  bundled ones
* A screen that shows each step the agent took

### Where to go from here

* `AgentChatView(session: session)` is a ready-made version of the chat page
  you wrote, and `SkillManagerView` lets the user switch skills on and off.
* The package bundles more skills: `query-wikipedia` (needs the network),
  `interactive-map` (answers with a webview) and `kitchen-adventure`, a
  text-only persona.
* Skills from Google's AI Edge Gallery use the same `SKILL.md` and the same
  JavaScript contract, so they run here as they are.

### Reference

* [flutter_edge_ai_agent](https://pub.dev/packages/flutter_edge_ai_agent) on
  pub.dev
* [Agent skills documentation](/docs/agent)
* [Function Calling with On-Device Models in Flutter](/codelabs/function-calling-flutter-gemma),
  the loop underneath an agent
