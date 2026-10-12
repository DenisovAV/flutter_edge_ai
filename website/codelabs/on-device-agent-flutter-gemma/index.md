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
your requests or writes the answers. The model is downloaded once, and a skill
that hands off to another app — the browser, on desktop, for a calendar
event — passes it what you asked for.

The assistant is an **agent**: a model in a loop that can use **skills**. A
skill is a folder with a `SKILL.md` — a name, a one-line description and
instructions — and, for some kinds, a little code. You will write two skills
of your own and use four that `flutter_edge_ai_agent` bundles.

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
  * an Android phone with 6 GB of RAM or more, Android 11 (API 30) or newer
  * an iPhone, a Mac with Apple Silicon, or a Windows PC
* The [Function Calling codelab](/codelabs/function-calling-flutter-gemma)
  helps: an agent is a function-calling loop. It is not required.

`flutter_edge_ai_agent` runs on Android, iOS, macOS and Windows. On Linux the
text, intent and MCP skills work and JavaScript skills do not. It does not run
on the web; the app in this codelab builds for the web and says so instead of
starting an agent.

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
  flutter_edge_ai: ^2.2.0
  flutter_edge_ai_litertlm: ^1.12.0
  flutter_edge_ai_agent: ^0.2.8

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

### Load your skills and open the agent

Create `lib/skills.dart`. The package loads the skills it bundles itself;
skills your app ships are read with the same parser:

```dart
const appSkillNames = ['packing-list'];

Future<List<Skill>> loadAppSkills({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final skills = <Skill>[];
  for (final name in appSkillNames) {
    final skill = parseSkillMd(
      await assets.loadString('assets/skills/$name/SKILL.md'),
    );
    if (skill.name != name) {
      throw StateError(
        'assets/skills/$name/SKILL.md is named "${skill.name}"; '
        'the name must match the folder.',
      );
    }
    skills.add(skill);
  }
  return skills;
}

Future<AgentSession> openAgent(InferenceModel model) async {
  final registry = SkillRegistry()
    ..addAll(await loadAppSkills(), selected: true);
  return AgentSession.fromModel(
    model,
    registry: registry,
    executors: [TextSkillExecutor()],
    modelType: Models.gemma4.modelType,
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
  and the skill list in the system prompt.

### Show what the agent does

`AgentSession.ask` does not return text. It returns a stream of events,
because an agent's turn is several things in a row: it loads a skill, calls a
tool, reads the result and answers. `lib/agent_page.dart` replaces the chat
page and folds each event into the reply bubble:

```dart
await for (final event in agent.ask(text)) {
  setState(() => _apply(reply, event));
}
```

```dart
void _apply(_Turn reply, AgentEvent event) {
  switch (event) {
    case SkillLoadEvent(:final skillName, :final found):
      reply.steps.add(
        found ? '📖 loaded skill $skillName' : '❓ no skill named $skillName',
      );
    case ToolCallEvent(:final toolName, :final args):
      reply.steps.add('🔧 $toolName $args');
      reply.text = '';
    case ToolResultEvent(:final result):
      reply.steps.add('↩️ ${_describe(result)}');
    case TextChunkEvent(:final text):
      reply.text += text;
    case DoneEvent(:final text):
      if (text.isNotEmpty) reply.text = text;
    case MaxIterationsEvent(:final iterations):
      reply.steps.add('⏹ stopped after $iterations steps');
    case AgentErrorEvent(:final message):
      reply.steps.add('⚠️ $message');
  }
}
```

`AgentEvent` is sealed, so the switch is exhaustive: a new kind of event in a
later version of the package is a compile error here, not a step that goes
missing from the screen.

Two lines deserve a word. Text that streams in before a tool call is not the
answer — it is the model thinking aloud, or the call itself in raw form — so
a `ToolCallEvent` starts the text over. And `DoneEvent` carries the final
answer whole, which the bubble prefers to whatever streamed.

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
| `schedule_notification` | schedules a local notification |
| `read_calendar_events` | answers only if you inject a handler for it |

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

Future<AgentSession> openAgent(InferenceModel model) async {
  final bundled = AssetSkillSource(names: packageSkillNames);
  final registry = SkillRegistry()
    ..addAll(await loadAppSkills(), selected: true)
    ..addAll(await bundled.load(), selected: true);
  return AgentSession.fromModel(
    model,
    registry: registry,
    executors: [TextSkillExecutor(), NativeIntentExecutor()],
    modelType: Models.gemma4.modelType,
    maxOutputTokens: 512,
  );
}
```

`AssetSkillSource` reads the skills from the package's own assets; you do not
copy them into your app. If a name is not one the package bundles, `load()`
throws and says which.

### Platform setup

On iOS the calendar editor needs a usage description. Add to
`ios/Runner/Info.plist`:

```xml
<key>NSCalendarsUsageDescription</key>
<string>The agent opens the calendar's event editor for events you ask it to create.</string>
```

The mail composer opens through a `mailto:` link, and the agent first asks
whether any app can open one. On Android 11 and newer, and on iOS, that
answer is "no" unless the app declares the scheme — the skill would report
that no mail app is installed. In `android/app/src/main/AndroidManifest.xml`,
inside `<queries>`:

```xml
<intent>
    <action android:name="android.intent.action.VIEW"/>
    <data android:scheme="mailto"/>
</intent>
```

and in `ios/Runner/Info.plist`:

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
    <string>mailto</string>
</array>
```

On macOS and Windows the calendar event opens as a Google Calendar template in
the browser, since there is no system event editor to call.

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

Watch the steps closely and you will likely see a wrong turn. In our runs on
a Mac, Gemma 4 E2B loaded `get-current-time` and then called `runSkill` with
the skill's name, twice, instead of `runIntent` with the intent. The tool answered with an error that
lists the allowed intents; the model read it and called
`runIntent get_current_date_and_time` on its next try. Errors go back to the
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
* `image` — a base64 image, shown to the user
* `webview` — a URL to show
* `error` — what went wrong, which the model reads too

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
    const total = Number(input.total);
    const people = Number(input.people);
    const tipPercent = Number(input.tip_percent ?? 0);
    if (!(total > 0) || !Number.isInteger(people) || people < 1 ||
        !(tipPercent >= 0)) {
      return JSON.stringify({
        error: 'Need a positive total, a whole number of people (1 or more) ' +
          'and a tip of 0 or more.',
      });
    }
    const tip = total * tipPercent / 100;
    const withTip = total + tip;
    const each = withTip / people;
    return JSON.stringify({
      result: `Each of ${people} pays ${each.toFixed(2)} ` +
        `(bill ${total.toFixed(2)} + tip ${tip.toFixed(2)} = ${withTip.toFixed(2)}).`,
    });
  } catch (e) {
    return JSON.stringify({error: `Could not split the bill: ${e.message}`});
  }
};
```

`Number(...)` rather than trusting the types: the model may send `"84"` as a
string. A bad input — a total of zero, 2.5 people — comes back as an `error`,
which the model reads and can explain, instead of a `NaN` it would repeat or
a rounded party size that gives a plausible wrong answer.

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
  reply.steps.add('↩️ ${_describe(result)}');
  if (result is ImageResult) reply.images.add(result.bytes);
```

### Platform setup

The executor serves the skill's page from a small HTTP server inside the
app, on `127.0.0.1`, and the webview loads it from there. Nothing leaves the
device, but two platforms need to be told this is allowed.

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

**Windows** needs the WebView2 runtime, which Windows 11 has. **iOS** needs
nothing.

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
bubble.

A JS skill can also need an API key — a weather service, say. Its `SKILL.md`
declares `require-secret: true` under `metadata`. The app stores the key with
`SecretStore.set(skillName, key)` (`SecretEditorDialog` asks the user for it)
and passes the store to `AgentSession.fromModel(secretStore: ...)`; the agent
hands the key to your function as `secret`. It never goes into the prompt.

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
