author: Sasha Denisov
summary: Package Skills in Flutter — Teach Your Coding Assistant flutter_edge_ai
id: package-skills-flutter-gemma
categories: flutter, ai, gemma, agent-skills
environments: android, ios, macos, windows, linux, web
status: Published

# Package Skills in Flutter: Teach Your Coding Assistant flutter_edge_ai

## Overview
Duration: 3

### What you'll build

The offline chat that Getting Started builds by hand — except you do not write
it. Your coding assistant does, after reading the instructions `flutter_edge_ai`
ships for it. Then you ask for a second feature, the model changing the app's
colour by calling a Dart function, and watch the assistant reach for a different
set of instructions to write it.

By the end you will have:

* the eight skills `flutter_edge_ai` bundles, installed for the assistant you use
* an offline chat on Gemma 4 E2B, written by that assistant
* the chat extended with a tool the model calls
* a way to check the assistant's code that does not depend on trusting it

### What you'll learn

* what a package skill is, and how an assistant decides to load one
* how `dart run skills@ get` finds skills, and where it puts them for each
  assistant
* the defaults in this API that fail without an error — and how to tell whether
  your assistant avoided them
* how to keep the skills in step with the package when it updates

### What you'll need

* Flutter 3.44 or newer
* One coding assistant that reads Agent Skills: Antigravity, Claude Code, Codex,
  Cursor, GitHub Copilot, Cline or OpenCode. Step 2 covers each of them, and
  Antigravity and Claude Code in detail
* Any one of Flutter's six platforms to run the result on. On **Android** it has
  to be an arm64 device or emulator: `flutter_edge_ai_litertlm` ships an arm64
  library and nothing else, so a 32-bit or x86_64 image has no runtime to load
  (an Apple-silicon Mac's emulator is arm64)
* About 3.5 GB of free space: Gemma 4 E2B is 2.6 GB on a device and 2.0 GB on
  the web, and neither a phone nor a browser near its storage limit takes a
  write that only just fits, so leave headroom

You do not need to have done
[Getting Started](/codelabs/getting-started-flutter-gemma). It helps to have seen
it: Steps 3 and 4 here ask your assistant for code that codelab explains line by
line.

### What "the result" means here

An assistant does not write the same code twice. Two people following this
codelab — or one person running it twice — get different files, so this codelab
never asks you to compare your code with a reference diff. Each task ends with a
list of things the code must do, each one a trap the skills exist to prevent.
The step apps are **one** correct answer to check against, not **the** answer.

### Get the code

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/package-skills-flutter-gemma
```

It holds three apps:

* `step_01_starter/` — the app you start from
* `step_03_chat/` — one correct answer to Step 3
* `complete/` — one correct answer to Step 4

## Step 1: The starter
Duration: 4

### Copy it out of the clone

Do this before anything else:

```bash
cp -R step_01_starter ~/edge_ai_skills
cd ~/edge_ai_skills
```

The reason is the repository you just cloned. It has skills of its own, for the
people who maintain `flutter_edge_ai` — `release`, `build-native`, `review-pr` and
two more, in `.claude/skills/` at its root — and some assistants look further up
than the folder you open. Claude Code loads project skills from the directory a
session starts in **and from every parent up to the repository root**, so a
session started inside the clone would offer your assistant instructions for
publishing this package alongside the ones for using it. A copy outside the
clone has only what you install into it.

### Run it

```bash
flutter run
```

It shows one line of text and nothing else. That is the whole app:

* **No inference code.** Writing it is your assistant's job.
* **`flutter_edge_ai` and `flutter_edge_ai_litertlm` are already dependencies**, and
  nothing imports them yet. They are there for Step 2: the skills CLI finds
  skills by scanning an app's dependencies, so an app that does not depend on the
  package has nothing to install. `flutter run` has also resolved them, which the
  CLI needs — if you skip this run, do a `flutter pub get` before Step 2.
* **The platform setup is already done**: Android's internet permission and
  `minSdk 30`, iOS 15 and its three memory entitlements, the two macOS
  entitlements and the `post_install` block in `macos/Podfile`, and
  `web/index.html`'s three script tags — the `@litert-lm/core` handshake plus
  `cache_api.js` and `opfs_helper.js`, the two scripts core's web model storage
  reaches for. What they buy you is storage, not a lasting install: the bytes
  survive a reload in OPFS, the app's handle on them does not, so a reloaded
  tab reports the model installed and downloads it again anyway.
  [Getting Started](/codelabs/getting-started-flutter-gemma) explains each one.
  They are here so that when the assistant's code fails, it is the code — not a
  missing entitlement that looks the same from outside.

One macOS caveat carries over from Getting Started: with Swift Package Manager
enabled and no other CocoaPods plugin in the app, Flutter drops the Podfile, its
`post_install` block never runs, and the first model load fails with nothing in
the error pointing at CocoaPods. Run
`flutter config --no-enable-swift-package-manager` for this project.

A clean run on your platform is all this step asks for.

## Step 2: Install the skills
Duration: 8

### What a skill is

A skill is a folder with a `SKILL.md` in it: a short description of when it
applies, then rules, working code, and the mistakes that fail silently. The
format is an open standard, [Agent Skills](https://agentskills.io), and the
assistants above read it the same way, in three stages:

1. **Discovery.** At the start of a session the assistant reads only each skill's
   name and description.
2. **Activation.** When a task matches a description, it reads the whole file.
3. **Execution.** It follows the instructions while it does the task.

Stage 2 runs entirely on the description, so `flutter_edge_ai`'s skills describe
tasks and symptoms rather than APIs — *"offline chat, running Gemma…"*, *"a reply
comes back empty"*. Eight ship in the package, one per area: inference, function
calling, RAG, speech, MediaPipe, ONNX, built-in AI and memory diagnostics.

### Install them

From `~/edge_ai_skills`:

```bash
dart run skills@ get --all
```

On a fresh app this stops:

```text
Could not auto-detect agent and none selected. Use --agent to specify one of: antigravity, claude, cline, codex, copilot, cursor, opencode, generic
```

The CLI detects an assistant by the folder it keeps in a project — `.agents/`,
`.claude/`, `.cursor/` and so on — and a new app has none. Name yours. `--all`
installs every skill without asking; leave it out and, in a terminal, the CLI
lets you pick.

### Antigravity

```bash
dart run skills@ get --all --agent antigravity
```

```text
  [generic] Installed flutter-edge-ai-builtin-ai
  [generic] Installed flutter-edge-ai-diagnostics
  [generic] Installed flutter-edge-ai-speech
  [generic] Installed flutter-edge-ai-function-calling
  [generic] Installed flutter-edge-ai-rag
  [generic] Installed flutter-edge-ai-onnx
  [generic] Installed flutter-edge-ai-inference
  [generic] Installed flutter-edge-ai-mediapipe
Installed 8 skill(s) for generic at .agents/skills.
```

`antigravity` is an alias. The CLI files it as `generic` — the name it prints —
and writes to `.agents/skills/`, which is where Antigravity looks for a
workspace's skills. Open `~/edge_ai_skills` itself as the workspace: the skills live
under the workspace root, so a workspace opened on a parent folder does not see
them.

To check, open the Agent panel (Cmd/Ctrl + L) — or start the Antigravity CLI with
`agy` — and ask:

```text
Summarize the flutter_edge_ai skills available in this project.
```

### Claude Code

```bash
dart run skills@ get --all --agent claude
```

```text
  [claude] Installed flutter-edge-ai-builtin-ai
  [claude] Installed flutter-edge-ai-diagnostics
  [claude] Installed flutter-edge-ai-speech
  [claude] Installed flutter-edge-ai-function-calling
  [claude] Installed flutter-edge-ai-rag
  [claude] Installed flutter-edge-ai-onnx
  [claude] Installed flutter-edge-ai-inference
  [claude] Installed flutter-edge-ai-mediapipe
Installed 8 skill(s) for claude at .claude/skills.
```

The CLI adds one line to each skill's header for Claude Code,
`user-invocable: false`. It takes the skills out of the `/` menu: you never call
them by name, and the model loads them on its own when a task matches. To check
they are there, ask the same question:

```text
Summarize the flutter_edge_ai skills available in this project.
```

If a Claude Code session was already open in this folder, **restart it**. Claude
Code picks up skills added while it runs, but only in a skills folder that
existed when the session started — and `.claude/skills/` did not.

### Every other assistant

| Assistant | `--agent` | Installed to |
|---|---|---|
| Codex | `codex` | `.agents/skills/` |
| Cursor | `cursor` | `.cursor/skills/` |
| GitHub Copilot | `copilot` | `.github/skills/` |
| Cline | `cline` | `.cline/skills/` |
| OpenCode | `opencode` | `.opencode/skills/` |
| anything else | `generic` | `.agents/skills/` |

Copilot is the one assistant the CLI never detects, even after its folder exists:
`.github/` serves CI and plenty else, so the CLI will not guess. Always pass
`--agent copilot`.

### What landed

```text
.agents/skills/                  (or .claude/skills/, .cursor/skills/ …)
  flutter-edge-ai-builtin-ai/SKILL.md
  flutter-edge-ai-diagnostics/SKILL.md
  flutter-edge-ai-function-calling/SKILL.md
  flutter-edge-ai-inference/SKILL.md
  flutter-edge-ai-inference/references/platform-setup.md
  flutter-edge-ai-mediapipe/SKILL.md
  flutter-edge-ai-onnx/SKILL.md
  flutter-edge-ai-rag/SKILL.md
  flutter-edge-ai-speech/SKILL.md
.config/dart_skills/skills_config.json
```

Open `flutter-edge-ai-inference/SKILL.md`. The first screen of it — the numbered
rules — is the best preparation for Step 3, because those rules are what you will
be checking.

`skills_config.json` records what was installed and from which package, with a
hash of each skill. It is how the CLI tells an update from a local edit later.

### Commit them, or don't

Either works; pick one for the team.

* **Commit** the skills folder **and** `.config/dart_skills/`, so everyone's
  assistant reads the same instructions and the CLI can track updates for all of
  you.
* **Ignore** `.config/dart_skills/` and the skills folder, and have each developer
  run `dart run skills@ get` after cloning.

## Step 3: Ask for an offline chat
Duration: 12

### The request

Give your assistant this, as written:

```text
Add an offline chat to this app with flutter_edge_ai. Use Gemma 4 E2B from
litert-community on Hugging Face: download it once with a progress bar, open
straight on the chat on later launches, and stream the reply.
```

It names no API on purpose: you are finding out whether the assistant knows them.

Notice what it reads first. The request is exactly what `flutter-edge-ai-inference`
describes, so that is the skill it should load. Most assistants show a skill being
read — as a tool call, or a line in the plan. If yours does not say, ask it which
skills it used; and if it wrote code without one, tell it to use the
flutter-edge-ai skills in this project. An assistant can skip a skill it should have
loaded, and then you are back to whatever it remembers from training.

Let it finish, then run the app. The download is 2.6 GB (2.0 GB on the web).

### Check the code

Go down this list against what your assistant wrote. Each item is one rule from
the skill, and each is a mistake that compiles, runs, and fails without telling
you why. The wrong version is what an assistant without the skill tends to write,
because it looks right.

**1. Both packages are imported.**

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
```

The engine package does not re-export the core. Import only the second and
`FlutterEdgeAi` is an undefined name — the one mistake on this list the compiler
does catch.

**2. The engine is registered, and web storage is set for a 2 GB model.**

```dart
await FlutterEdgeAi.initialize(
  webStorageMode: WebStorageMode.streaming,
  inferenceEngines: [LiteRtLmEngine()],
);
```

The core registers no engine of its own. Leave `inferenceEngines` out and the
app builds, the download works, and the first `getActiveModel()` throws a
`StateError` asking for an engine package. On web, leave `webStorageMode` out
and the default `cacheApi` mode buffers the whole download in memory as one
blob — and browsers cap a single blob at roughly 2 GB, Chrome refusing past it
with `ERR_BLOB_OUT_OF_MEMORY`. Gemma 4 E2B's web build is 2.0 GB, right on
that line: close enough that this codelab streams. `streaming` writes the
download into OPFS and reads the model back from there instead; native
platforms ignore the option.

**3. The file type is declared.**

```dart
await FlutterEdgeAi.installModel(
  modelType: widget.model.modelType,
  fileType: ModelFileType.litertlm,
).fromNetwork(widget.model.url).withProgress((percent) {
  if (mounted) setState(() => _percent = percent);
}).install();
```

The declared type — not the `.litertlm` at the end of the URL — decides which
engine opens the file, and it defaults to `ModelFileType.task`. Without that line
the download succeeds and `getActiveModel()` throws *"No inference engine can
handle this model"*: the only engine you registered does not handle `.task`.

**4. `maxTokens` is not the reply length.**

```dart
final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
final chat = await inference.createChat(
  modelType: widget.model.modelType,
  maxOutputTokens: 256,
);
```

`maxTokens` is the whole context window — prompt, history and reply together. An
assistant told to keep replies short reaches for `maxTokens: 100`; on native
`.litertlm` that is raised back to 1024 with a debug-log warning, and the replies
are as long as before. The web `.litertlm` engine does not use the value at
all — same replies, no warning either. The reply is capped with
`maxOutputTokens` on every platform.

**5. The user's message says it is from the user.**

```dart
await chat.addQueryChunk(Message.text(text: text, isUser: true));
```

`isUser` defaults to `false`. Without it the message is not a user turn and the
reply comes back empty — no exception, nothing in the log.

**6. What was opened is closed.**

A model holds native memory, and so does a chat. Whatever the assistant opened
needs a `close()`, at the latest when the screen goes away.

**7. There is no token.**

Gemma 4 E2B is not gated, so a correct answer has no Hugging Face token anywhere.
When a gated model does need one, the skill has it read with
`String.fromEnvironment` — never written into the source.

`step_03_chat/` passes every item. If yours does too, you have the same app in
different words.

## Step 4: Ask for a tool call
Duration: 12

### The request

```text
Let the user change the app's colour by asking in the chat, for example "make it
green". The model should call a Dart function to do it.
```

This time the assistant should load a **different** skill,
`flutter-edge-ai-function-calling`. Again the request names no API; what matches is
that skill's description — *"letting an on-device model call the app's own Dart
functions"*. The description even says where its edge is: *"For plain chat, use
flutter-edge-ai-inference."* Two skills, one app, and the assistant picks by task.

Run it and ask for a colour. Then ask for one that does not exist — *"make it
mauvish"* — because item 4 below is about what happens then.

### Check the code

**1. The chat is told it may call functions.**

```dart
final chat = await inference.createChat(
  tools: const [ColorTool.declaration],
  supportsFunctionCalls: true,
  modelType: widget.model.modelType,
  maxOutputTokens: 256,
);
```

`tools` alone is not enough. Without `supportsFunctionCalls: true` no call is
parsed and only a debug warning is logged — and on Gemma 4 the declarations still
reach the model, so it answers with its raw tool-call JSON in the middle of the
reply text. The colour never changes, and the user reads JSON.

**2. `modelType` is passed.**

On a device, a `.litertlm` chat uses the installed model's type when you leave it
out. The web engine falls back to `ModelType.gemmaIt` instead, and Gemma 4's calls
then arrive as raw text. Passing it everywhere costs nothing.

**3. The tool describes an action.**

```dart
static const name = 'change_color';

static const declaration = Tool(
  name: name,
  description: "Change the app's colour theme.",
  parameters: {
    'type': 'object',
    'properties': {
      'color': {
        'type': 'string',
        'description': 'A colour name, for example red, green or purple.',
      },
    },
    'required': ['color'],
  },
);
```

The model matches the user's words against the description — the same way your
assistant matched your request against a skill's. Every parameter is described
too.

**4. Errors are results.**

This is what "make it mauvish" tests. A tool should never throw:

```dart
if (color == null) {
  return ToolOutcome({
    'error': 'unknown colour: $requested',
    'known': colors.keys.toList(),
  });
}
```

The model can read an error and recover — tell the user which colours exist, or
pick the nearest. An exception from the tool is reported to the model and then
rethrown on the stream, which ends the turn. In
`complete/` this lives in `lib/color_tool.dart`, apart from the UI, so a test pins
it without a model: `flutter test` there runs it.

**5. The loop is the built-in one.**

```dart
await for (final chunk in chat.generateChatResponseWithTools(
  onToolCall: _runTool,
  onMaxToolTurns: () => _insertNote('Stopped after 8 tool calls.'),
)) {
  if (chunk is TextResponse) {
    buffer.write(chunk.token);
    // …and show the buffer in the reply bubble.
  }
}
```

It calls the tool, feeds the result back, and continues until the model answers
in text. A hand-written loop is allowed, but then it has to switch over all four
`ModelResponse` subtypes: the type is sealed, and a switch that leaves out
`ThinkingResponse` does not compile. Whichever loop it is, reaching the turn limit
ends the stream **without an error** — `onMaxToolTurns` is the only signal.

`complete/` passes every item.

## Step 5: Keep the skills current
Duration: 3

The skills ship inside the package and are versioned with it, so upgrading
`flutter_edge_ai` can change them. After an upgrade, run:

```bash
dart run skills@ get
```

In a terminal it lists every skill with its state and lets you pick which to
update. Without one — in a script, or when your assistant runs it — it prints
the same list and stops. Here it is for a Claude Code install with one skill
edited by hand:

```text
Available skills from package:flutter_edge_ai:
  flutter-edge-ai-rag (Local edits)
  flutter-edge-ai-builtin-ai (Update available)
  flutter-edge-ai-diagnostics (Update available)
  flutter-edge-ai-function-calling (Update available)
  flutter-edge-ai-inference (Update available)
  flutter-edge-ai-mediapipe (Update available)
  flutter-edge-ai-onnx (Update available)
  flutter-edge-ai-speech (Update available)
Rerun with `--skill <name>`, or `--all` to install, update, or remove the given skills.
```

`Local edits` is the hash in `skills_config.json` at work: that skill no longer
matches what was installed. Look for it before you reach for `--all`, because
**`--all` installs the package's copy of every skill and overwrites local edits
without asking.** Rules of your own are safer in a skill of your own than inside
an installed one.

The other six say `Update available` although nothing changed: version 1.0.1 of
the CLI reports that for every Claude Code skill, even straight after installing
it. The same untouched install in `.agents/skills/` prints
`All skills are up to date.`

Two more commands worth knowing:

```bash
dart run skills@ list    # what is installed, for which assistant, from which package
dart run skills@ prune   # remove skills whose package is no longer a dependency
```

An outdated skill is worse than none, because an assistant follows it with
confidence. `flutter_edge_ai`'s CI compiles every Dart block in its skills against
the packages on every pull request, so the skills that match your installed
version are the ones to have.

## What's next
Duration: 2

You have an app your assistant wrote, and a way to check its work without
reading every line of it. The same eight skills cover the rest of the package,
and the same habit — ask, see which skill it loads, check against the rules —
works for each:

* **ground answers in your own documents** — `flutter-edge-ai-rag`
* **transcribe and speak** — `flutter-edge-ai-speech`
* **use the model the OS already has** — `flutter-edge-ai-builtin-ai`
* **measure process memory on Android and iOS** — `flutter-edge-ai-diagnostics`
* **run `.task` or ONNX models** — `flutter-edge-ai-mediapipe`,
  `flutter-edge-ai-onnx`

### Reference

* [Package Skills documentation](/docs/package-skills)
* [Package skills on dart.dev](https://dart.dev/ai/package-skills) — every CLI
  command
* [The Agent Skills format](https://agentskills.io)
* [This codelab's code](https://github.com/DenisovAV/flutter_edge_ai/tree/main/codelabs/package-skills-flutter-gemma)
