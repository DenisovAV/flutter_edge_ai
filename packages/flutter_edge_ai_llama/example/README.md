# GGUF Lab

A small Flutter chat app showing local GGUF inference through
[Flutter Edge AI and llamadart](../README.md). It has Android, iOS, macOS,
Windows, Linux and Web runners.

## First run

Use Flutter **3.47.1**. From `packages/flutter_edge_ai_llama/`:

```sh
python3 tool/fetch_test_model.py
cd example
flutter pub get
flutter run -d macos
```

The verified download is about 145 MB and is saved to `tool/fixtures/chat.gguf`.
Click **Choose model**, select that file and wait for **Ready**. Send
“Say hello in one sentence.” The tiny SmolLM2 model is for a quick integration
check; larger compatible instruction-tuned GGUFs can produce better answers.

Use `flutter devices` to find an Android/iOS device ID. For Linux/Windows,
replace `macos` with `linux`/`windows` on that host. Apple SwiftPM is already
configured. Deployment floors: iOS 16.4, macOS 14, Android API 24.
Android/Linux/Windows package CPU libraries; Apple can use CPU/Metal depending
on the loaded runtime. The backend badge reports what the runtime exposes.

For Chrome, follow the [Web quick start](../README.md#run-in-a-browser), including
asset preparation and isolation headers. Paste a direct, CORS-enabled GGUF URL
and click **Load URL**; the native file picker is not used in the browser.

## A short showcase

1. Send “My name is Alex. Remember it.”, then ask “What is my name?” to show a
   follow-up in the same conversation. Model quality affects the answer.
2. Send a longer prompt and click **Stop** while it is streaming. The partial
   turn disappears; send another message to continue.
3. Click **New chat** to start with empty history.
4. Quit and reopen: the installed model reloads, with a fresh conversation.

Native import copies the file into app-owned storage, preserving the original.
Allow space for both copies. Native generation needs no model server after
the model and runtime are downloaded. Backgrounding the native app stops an
active response. The composer stays visible with a phone keyboard, and text
updates are buffered to at most 30 refreshes per second.

The UI uses a 2,048-token context and 128-token response limit. It reports an
output limit or missing usage rather than inventing a count. For longer chats,
start a new conversation when the context is full.

This UI intentionally demonstrates text chat. Copyable
[chat and embedding API examples](../README.md#stream-a-response) and
[tools, thinking, media and LoRA examples](../doc/advanced_usage.md) show the
other features. See the [qualification matrix](../doc/platforms.md) for tested
devices/backends and open release checks.
