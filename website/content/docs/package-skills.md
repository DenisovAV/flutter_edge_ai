---
title: Package Skills
description: flutter_edge_ai ships agent skills for coding assistants — Claude Code, Codex, Cursor, Copilot and others learn the API from skills bundled in the package, installed with one dart run skills@ get --all.
image: https://flutteredge.ai/images/og-image.png
---

A coding assistant that has never seen flutter_edge_ai writes plausible code that
fails. It installs a `.litertlm` model without declaring its file type and lands
on the wrong engine, reads `maxTokens` as the reply length, or leaves out
`isUser: true` and gets an empty reply.

flutter_edge_ai ships **agent skills** — instruction files in the open
[Agent Skills](https://agentskills.io) format — inside the package itself.
Dart's [`skills` CLI](https://dart.dev/blog/skills-cli-1-0-bundle-and-distribute-ai-agent-skills-for-your-packages)
copies them into your project, where your assistant picks them up.

<Info>

Not to be confused with <a href="/docs/agent">Agent Skills</a> — the
<code>flutter_edge_ai_agent</code> package, which gives the <em>on-device model</em>
skills to run. The skills on this page teach <em>your coding assistant</em> to
use flutter_edge_ai.

</Info>

## Install

From your app's root, once `flutter_edge_ai` 2.0.0 or later is a dependency (the skills follow the installed version):

```
dart run skills@ get --all
```

The CLI scans your dependencies, finds the skills they bundle, and installs
them for the assistant it detects in the project:

| Assistant | `--agent` | Installed to |
|-----------|-----------|--------------|
| Claude Code | `claude` | `.claude/skills/` |
| Codex, Antigravity | `codex`, `antigravity` | `.agents/skills/` |
| Cursor | `cursor` | `.cursor/skills/` |
| GitHub Copilot | `copilot` | `.github/skills/` |
| Cline | `cline` | `.cline/skills/` |
| OpenCode | `opencode` | `.opencode/skills/` |
| any other | `generic` | `.agents/skills/` |

Detection looks for the assistant's directory in the project root. When there is
none yet, the CLI stops with *Could not auto-detect agent* — name the assistant:

```
dart run skills@ get --all --agent claude
```

Copilot is never auto-detected, because `.github/` serves many other purposes,
so it always needs `--agent copilot`. `--all` installs everything without
asking; `--skill <name>` installs only the skills you name, and can be repeated. The CLI records what it
installed in `.config/dart_skills/skills_config.json`.

Run the same command after upgrading flutter_edge_ai: it updates the installed
skills to the ones the new version ships.

To try it end to end — install the skills, have your assistant build a chat
and a tool call, and check its code against the rules — follow the
[Package Skills codelab](/codelabs/package-skills-flutter-gemma).

## How your assistant uses them

Each skill is a folder with a `SKILL.md`: a description of when it applies, then
rules, working code, and the traps that fail without an error. The assistant
reads only the descriptions up front and loads a skill when a task matches —
"add an offline chat with Gemma" pulls in the inference skill, "search my notes
by meaning" the RAG one. In Claude Code they install as skills the model invokes
on its own; there is no command to remember.

## The skills

| Skill | Covers |
|-------|--------|
| `flutter-edge-ai-inference` | engines, installing a model from Hugging Face, sessions and chats, streaming, system prompts, images and audio, backends — and the platform setup for Android, iOS, macOS, Windows, Linux and web |
| `flutter-edge-ai-function-calling` | declaring tools, `FunctionCallResponse`, the built-in tool loop, returning errors as results |
| `flutter-edge-ai-rag` | embedding models, `flutter_edge_ai_rag` (`RagIndex`, embedding profiles), SQLite/Qdrant providers, filters and their schema, ownership |
| `flutter-edge-ai-speech` | Whisper, moonshine and Parakeet STT; Matcha, Qwen3 and Inflect TTS; 16 kHz PCM; `VoiceSession` |
| `flutter-edge-ai-mediapipe` | `.task` and `.bin` models on Android, iOS and web |
| `flutter-edge-ai-onnx` | ORT-GenAI generation and ONNX embeddings, native and through Transformers.js |
| `flutter-edge-ai-builtin-ai` | Gemini Nano on Android and in desktop Chrome, Phi-4-mini in Edge, Apple Foundation Models on iPhone, iPad and Mac, Phi Silica on Windows; availability, falling back to a downloaded model |
| `flutter-edge-ai-diagnostics` | measuring what a model costs in memory with `flutter_edge_ai_diagnostics`: what the OS kills on per platform, null versus `MemoryReadException` |

## What they prevent

The skills spell out the defaults that fail quietly, each with its fix:

- `maxTokens` is the context window, not the reply length — cap a reply with `maxOutputTokens`.
- `Message.isUser` defaults to `false`; a prompt without it gets an empty reply.
- The declared `fileType`, not the file name, picks the engine, and it defaults to `.task`.
- A metadata filter on a field missing from `filterSchema` is ignored, and search returns unfiltered results.
- Speech-to-text takes raw 16 kHz mono PCM. A WAV file or 48 kHz audio is not rejected — it is transcribed wrong.
- The engine packages do not re-export core: import `package:flutter_edge_ai/flutter_edge_ai.dart` as well.

## Kept in step with the code

Every code block in the skills is compiled against the real packages before each
release, and a release that changes an API a skill describes gets that skill
re-read and updated. The skills ship inside the package, so upgrading
flutter_edge_ai and re-running the CLI keeps your assistant current.
