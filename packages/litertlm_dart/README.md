# litertlm_dart

[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) in pure Dart, with
no Flutter dependency: `dart:ffi` over LiteRT-LM's C API, with the native
libraries fetched and bundled by a build hook, and on the web the same API over
the page's [`@litert-lm/core`](https://www.npmjs.com/package/@litert-lm/core)
(see [On the web](#on-the-web)). The API follows LiteRT-LM's
[Kotlin](https://developers.google.com/edge/litert-lm/android) and
[Swift](https://developers.google.com/edge/litert-lm/swift) APIs: an `Engine`
loads a `.litertlm` model, a `Conversation` sends it messages, an
`EmbeddingEngine` embeds with EmbeddingGemma 2.

It is the runtime under
[`flutter_edge_ai_litertlm`](https://pub.dev/packages/flutter_edge_ai_litertlm)
and [`flutter_edge_ai_speech`](https://pub.dev/packages/flutter_edge_ai_speech).
A Flutter app normally uses those, through
[`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai); today this
package runs inside Flutter apps (see
[Where it runs today](#where-it-runs-today)).

```dart
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation();
await for (final piece in conversation.sendMessageStream(
  Message.user('What is the capital of France?'),
)) {
  stdout.write(piece.text);
}
await conversation.close();
await engine.close();
```

## Add the dependency

```yaml
dependencies:
  litertlm_dart: '>=0.19.1+1 <0.19.2'
```

The version is the upstream LiteRT-LM version this package is built from,
plus the number of our release on it: `0.19.1+1` is the first release on
LiteRT-LM 0.19.1. Within one upstream version the Dart API stays compatible.
This release runs:

| | |
|---|---|
| Native | LiteRT-LM 0.19.1, our build `native-v0.19.1-c` |
| Web | `@litert-lm/core` 0.18.0 |
 `dart pub add litertlm_dart` writes `^0.19.1+1`, which for a 0.x
version also takes later 0.19.x releases; those follow newer LiteRT-LM
releases and may change the Dart API, so bound it at the next upstream patch,
as above, to stay on one.

The build hook downloads our patched LiteRT-LM build (the `native-v*`
releases of this repository, SHA256-verified) for Android arm64, iOS, macOS
arm64, Linux x64/arm64 and Windows x64.

`Message`, `Tool`, `ResponseFormat` and `ActivationDataType` have the names
of LiteRT-LM's Kotlin and Swift types, and `flutter_edge_ai` has types of the
same names. In code that imports both, import this package with a prefix:
`import 'package:litertlm_dart/litertlm_dart.dart' as lm;`.

## Initialize the Engine

`Engine.create` loads the model on an isolate of its own: one attempt on the
backend you name, with no fallback to another.

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(
  EngineConfig(
    modelPath: modelPath,
    backend: const Backend.gpu(), // or Backend.cpu(), Backend.npu()
    maxNumTokens: 4096, // the context window, not the reply length
    cacheDir: cacheDir, // optional: compiled programs, weight caches
  ),
);
// ... create conversations ...
await engine.close();
```

- **`maxNumTokens`** is the context window: the prompt, the history and every
  reply. The reply length is `ConversationConfig.maxOutputTokens`. On the CPU
  and the GPU a value below 1024 is raised to 1024 (the cache length those
  bundles bake). Unset, LiteRT-LM chooses, as in its Kotlin API: the bundle's
  `max_num_tokens`, else 4096 (at most 4096 on a GPU other than Apple's).
- **`Backend.cpu(threadCount:)`**, **`Backend.gpu()`**, **`Backend.npu()`**.
  The NPU vendor (Qualcomm, Google Tensor, MediaTek, Intel) is read from the
  bundle, which must be compiled for that NPU; `Backend.npu(dispatchDir:)`
  names a directory holding that vendor's dispatch libraries, and only that
  vendor's (unset: beside the executable, where the build puts them on Linux
  and Windows). On Android see [Where it runs today](#where-it-runs-today).
- **`activationDataType`** sets the GPU executor's activation type. Unset, the
  engine keeps the bundle's, except that Gemma 4 above a 2,048-token context
  and a FunctionGemma bundle that declares no type get float32 on the GPU
  (not Gemma 4 on Android: there it keeps float16 on every GPU, because
  float32 failed on an Adreno 830 with this native build).
- `engine.bundleInfo` is what the file says about itself;
  `readBundleInfo(path)` reads it without loading the model.

LiteRT-LM's native log level is set before the engine is created, as with
Kotlin's `Engine.setNativeMinLogSeverity`:

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

LiteRtLmLog.nativeLevel = LiteRtLmLogLevel.error;
LiteRtLmLog.level = LiteRtLmLogLevel.warning; // this package's own lines
```

## Create a Conversation

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation(
  ConversationConfig(
    systemInstruction: 'You are a helpful assistant.',
    initialMessages: [
      Message.user('What is the capital city of the United States?'),
      Message.model('Washington, D.C.'),
    ],
    samplerConfig: SamplerConfig(topK: 10, topP: 0.95, temperature: 0.8),
    maxOutputTokens: 512,
  ),
);
// ...
await conversation.close();
```

An engine holds several conversations at once. On the backends where several
native conversations were measured to work, each has its own; elsewhere they
share one and replay their messages when they take it over.

## Send messages

`sendMessage` returns the whole reply; `sendMessageStream` streams it as
`Message` pieces (text, a thought in `channels['thought']`, tool calls in
`toolCalls`).

```dart
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation();

final reply = await conversation.sendMessage(
  Message.user('What is the capital of France?'),
);
print(reply.text);

await for (final piece in conversation.sendMessageStream(
  Message.user('Tell me a long story.'),
)) {
  stdout.write(piece.text);
}
```

One message at a time: a send while another reply is still being listened to
is a `StateError`.

**Stopping a reply.** `conversation.cancel()` stops it and keeps what was
generated: the stream ends normally (Swift's `cancel()`). Cancelling the
subscription stops it too and drops what has not reached you. Either way the
next message waits for the stopped turn to end. The conversation keeps the
message and the partial reply as a finished exchange; a turn stopped before
any output is taken back, message included.

```dart
import 'dart:async';

import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation();
final text = StringBuffer();
final done = Completer<void>();
conversation
    .sendMessageStream(Message.user('Count to one thousand.'))
    .listen((piece) => text.write(piece.text), onDone: done.complete);
await Future<void>.delayed(const Duration(seconds: 2));
conversation.cancel();
await done.future;
```

**Template variables.** `extraContext` on `ConversationConfig`, and per
message on `sendMessage`/`sendMessageStream`, feeds the model's prompt
template; per-message keys win.

## Speculative decoding

Multi-token prediction is an engine setting here, not an experimental flag:

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(
  EngineConfig(
    modelPath: modelPath,
    backend: const Backend.gpu(),
    speculativeDecoding: SpeculativeDecodingMode.on, // or .adaptive, .off
  ),
);
```

A conversation can override it with `ConversationConfig.speculativeDecoding`.
Unset, it is LiteRT-LM's default (off).

## Multimodality

A multimodal model (Gemma 4, Gemma 3n) takes images and audio once their
encoders are loaded. An encoder loads only when you name its backend;
`BundleInfo.declaredVisionBackend` and `declaredAudioBackend` are where the
file wants them.

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(
  EngineConfig(
    modelPath: modelPath,
    backend: const Backend.gpu(),
    visionBackend: const Backend.gpu(),
    audioBackend: const Backend.cpu(),
  ),
);
final conversation = await engine.createConversation();
final reply = await conversation.sendMessage(
  Message(
    role: Role.user,
    contents: [
      Content.imageFile(imagePath),
      Content.audioBytes(audioBytes),
      Content.text('Describe this image and audio.'),
    ],
  ),
);
```

`Content.imageBytes` and `Content.imageFile` take encoded images (JPEG,
PNG, …); `Content.audioBytes` and `Content.audioFile` take encoded audio
(WAV, MP3, FLAC, …). `EngineConfig.maxNumImages` is how many images one
message may carry (1 when unset). The Gemma 4 and Gemma 3n audio encoders
declare the CPU.

## Function calling

Declare a tool with its parameters as a JSON Schema object (the shape of
Kotlin's `OpenApiTool` description). The model's calls arrive as
`ToolCall`s; you run them and answer with `Message.tool`. There is no
automatic tool loop (Kotlin's default, `automaticToolCalling = true`): which
code runs is the caller's decision.

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final weather = Tool(
  name: 'get_current_weather',
  description: 'Get the current weather for a city.',
  parameters: {
    'type': 'object',
    'properties': {
      'city': {'type': 'string', 'description': 'The city name.'},
    },
    'required': ['city'],
  },
);
final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation(
  ConversationConfig(tools: [weather]),
);

var reply = await conversation.sendMessage(
  Message.user("What's the weather like in London?"),
);
while (reply.toolCalls.isNotEmpty) {
  reply = await conversation.sendMessage(
    Message.tool([
      for (final call in reply.toolCalls)
        Content.toolResponse(call.name, {
          'city': call.arguments['city'],
          'temperature': 25,
          'condition': 'sunny',
        }),
    ]),
  );
}
print(reply.text);
```

## Thinking

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation(
  ConversationConfig(
    thinkingConfig: ThinkingConfig(thinkingTokenBudget: 1024),
    maxOutputTokens: 2048,
  ),
);
final reply = await conversation.sendMessage(
  Message.user('Solve this logic puzzle step by step.'),
);
print('Thought: ${reply.channels['thought']}');
print('Answer: ${reply.text}');

// Per message:
final quick = await conversation.sendMessage(
  Message.user('Give a concise answer.'),
  thinkingConfig: ThinkingConfig(enableThinking: false),
);
```

`ThinkingConfig()` turns thinking on with no budget; `enableThinking: false`
turns it off. A budget is 1 to 2,147,483,647 (Kotlin's -1 and 0 are an unset budget
and `enableThinking: false` here), caps the first channel the bundle declares
(`thought` on Gemma 4), and counts towards `maxOutputTokens`.

## Sampling and constrained decoding

- **`SamplerConfig(topK:, topP:, temperature:, seed:)`** (`seed` is 0 when
  not given). With no `SamplerConfig`, a conversation uses the sampler the
  model file carries, field by field, then 0.8 / 40 / 0.95 / seed 1.
  LiteRT-LM fixes the sampler at the engine's first generation (LiteRT-LM
  #2080); a later conversation that asks for another one is told so once. On
  the NPU the executor decodes greedily whatever is sent, and an explicit
  sampler there prints a warning.
- **`ResponseFormat.json(schema)`** and **`ResponseFormat.regex(pattern)`**
  constrain every reply while it is decoded. They run on the hosts and
  backends where constrained decoding was qualified: elsewhere
  `createConversation` throws `ConstraintUnsupportedException`. A send ends
  with the same exception for a schema LLGuidance cannot compile, and for a
  response format combined with a thinking budget.

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation(
  ConversationConfig(
    responseFormat: ResponseFormat.json({
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
        'population': {'type': 'integer'},
      },
      'required': ['city', 'population'],
    }),
  ),
);
```

Per message, `sendMessage` also takes `repetitionPenaltyConfig`,
`noRepeatNgramConfig` and `suppressTokens`.

## Embeddings

`EmbeddingEngine` runs EmbeddingGemma 2 `.litertlm` bundles: text, and on the
bundles with those towers images and audio, one vector for all the parts of
one input. The text carries its task prefix, written by you as the model
card gives it.

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final embedder = await EmbeddingEngine.create(
  EmbeddingEngineConfig(
    modelPath: embeddingModelPath,
    cacheDir: cacheDir, // one weight cache per bundle; not backed up
    visionBackend: const Backend.cpu(), // takes images; null: text only
  ),
);
print(
  '${embedder.info.dimension} dimensions, '
  '${embedder.info.maxInputTokens} tokens at most',
);
final vector = await embedder.computeEmbedding([
  Content.text('A photo of a red apple'),
  Content.imageBytes(imageBytes),
]);
await embedder.close();
```

- The text tower runs on the CPU, on the NPU for a per-SoC bundle (and only
  there), and on the GPU on Linux x64, Windows x64 and macOS arm64 for the
  bundles measured there; elsewhere the GPU is refused. Nothing moves to
  another backend on its own: an NPU bundle's vectors and the generic
  bundle's are in different spaces.
- The vision tower runs on the CPU, or on the NPU beside an NPU text tower;
  the audio tower on the CPU only.
- An input over `info.maxInputTokens` is an `EmbedderInputTooLongException`;
  it is never truncated.
- Unlike `Engine`, an `EmbeddingEngine` runs on the isolate that creates it:
  the load and every `computeEmbedding` block that isolate. In an app with a
  UI, create and use it on a worker isolate.

## Errors and closing

The exceptions below all extend `LiteRtLmException`, one type to catch.
Programming errors stay `ArgumentError` and `StateError` (a send on a closed
conversation, a second send while a reply streams).

| Exception | When |
|---|---|
| `LiteRtLmBundleException` | the file is not a `.litertlm` this release reads, is incomplete, or cannot run as asked; before any engine exists |
| `NpuDispatchUnavailableException` | the NPU cannot be reached |
| `LiteRtLmEngineCreateException` | LiteRT-LM refused the engine |
| `LiteRtLmLibraryException` | libLiteRtLm did not load, or is not a build this release drives |
| `ContextFullException` | a message did not fit what the context window had left |
| `ConversationClosedException` | the conversation or its engine closed while a reply streamed |
| `TurnFailedException` | native failed the turn; or a reply chunk could not be read, and the stream goes on |
| `ConstraintUnsupportedException` | a response format is not supported on this host and backend, its schema does not compile, or it is combined with a thinking budget |
| `EmbedderLoadException`, `EmbedderInputTooLongException`, `EmbedderEngineException` | the embedding engine's |

A failed turn ends its stream with the exception; the next message recovers
the conversation first (a turn that produced nothing, failed or did not fit
is taken back).

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation();
try {
  await conversation.sendMessage(Message.user('Hello!'));
} on ContextFullException {
  // Start a new conversation, or send less.
} on LiteRtLmException catch (e) {
  print(e.message);
} finally {
  await conversation.close();
  await engine.close(); // closes every conversation it still holds
}
```

## Benchmark

`benchmark()` is the Kotlin API's `benchmark()` (experimental): it loads the
model in LiteRT-LM's benchmark mode, where the prompt is cut or padded to
exactly `prefillTokens` and the reply runs exactly `decodeTokens` past its end,
sends one message and closes the engine. The defaults (`'How are you'`, 256
and 256) are Kotlin's; AI Edge Gallery's benchmark screen starts from the
same (`BenchmarkScreen.kt` and `BenchmarkViewModel.kt` in
google-ai-edge/gallery).

```dart
final run = await benchmark(
  modelPath: modelPath,
  backend: const Backend.gpu(),
  cacheDir: cacheDir, // a new empty directory: the first run is a cold load
);
print('${run.prefillTokensPerSecond} / ${run.decodeTokensPerSecond} tok/s, '
    'first token ${run.timeToFirstToken}, init ${run.initTime}, '
    'context ${run.maxNumTokens}');
```

Each call loads the model again; the cache files decide whether a load is
cold. Unset, `cacheDir` is the model's directory, and its caches outlive the
process: pass a new empty directory, or `':nocache'`, for a cold run.
`maxNumTokens` unset leaves the context to the bundle; it changes the speeds,
so compare runs with the same `run.maxNumTokens`.

## Differences from the Kotlin and Swift APIs

| | Kotlin / Swift | litertlm_dart |
|---|---|---|
| Load | `Engine(config)`, then `initialize()` | `await Engine.create(config)` |
| Streaming | `sendMessageAsync` (Kotlin), `sendMessageStream` (Swift) | `sendMessageStream`, a `Stream<Message>` |
| System prompt | `systemInstruction` (Kotlin), `systemMessage` (Swift) | `systemInstruction`, a `String` |
| Tools | Kotlin functions or `OpenApiTool`, called automatically by default | `Tool` with a JSON Schema, called by you |
| Speculative decoding | `ExperimentalFlags.enableSpeculativeDecoding` | `EngineConfig.speculativeDecoding`, per conversation too |
| Thinking budget | -1 unlimited, 0 off | unset, or 1 to 2,147,483,647; `enableThinking: false` is off |
| Several conversations per engine | — | yes, a stopped, refused or failed turn recovered before the next |
| Reading a bundle without loading it | — | `readBundleInfo`, `readBundleGenericData` |
| Tokenizer | — | `Engine.tokenize`, `detokenize` |
| Option scoring | — | `Engine.scoreTargets`: the exact log-probability of each target as a continuation |
| Constrained decoding | C++ API | `ResponseFormat.json`, `.regex` |
| `benchmark()` | `BenchmarkInfo` with mark durations | `LlmBenchmarkResult`, plus the whole create's time, the backend and the GPU activation type; no media contents |
| EmbeddingGemma 2 | text, images, audio | the same, text with images and audio in one vector, per-SoC NPU bundles |
| LoRA, `tool_choice`, the LiteRT-LM 0.20 additions | | not yet |

## Where it runs today

The runtime and the hook are what `flutter_edge_ai_litertlm` runs on Android,
iOS, macOS, Linux and Windows. On its own, without that package:

- **Android:** the GPU and the NPU load vendor libraries an app must declare
  as `uses-native-library` (`libOpenCL.so`, `libvndksupport.so`,
  `libcdsprpc.so`, the Google Tensor and NeuroPilot libraries;
  `flutter_edge_ai`'s manifest declares them). For `Backend.npu`, pass a
  `dispatchDir` holding one vendor's dispatch libraries, copied out of the
  APK; `flutter_edge_ai_litertlm` does this through a platform channel.
- **macOS:** two companion libraries (the constraint provider and the Metal
  accelerator) are embedded by `flutter_edge_ai_litertlm`'s Swift package or
  Podfile step. A macOS app that depends on `litertlm_dart` alone, and a
  plain Dart program on macOS, cannot load the engine yet.
- **Library lookup** follows a Flutter app bundle; `dart run` and
  `dart build cli` layouts are not looked up yet.
- **With `flutter_edge_ai_litertlm` 1.20.x or older** in the same app, both
  build hooks bundle `libLiteRtLm` and which build runs is not defined. Use
  `flutter_edge_ai_litertlm` 1.21.0 or newer, which builds on this package.

A plain Dart program and the macOS companions are planned with a
command-line example.

## Build options

Set under `hooks: user_defines: litertlm_dart:` in the app's pubspec (the
workspace root's, if the app is a workspace member):

```yaml
hooks:
  user_defines:
    litertlm_dart:
      qualcomm_npu: true       # bundle Qualcomm's QNN runtime (Android, Linux arm64)
      google_tensor_npu: true  # Google Tensor G5/G6
      mediatek_npu: true       # MediaTek Dimensity
```

On the MediaTek NPU every turn runs in a fresh native conversation that
replays the history: there a conversation answers its second message empty
(MT6989, LiteRT-LM #4256).

The key apps set before this package existed, `flutter_edge_ai_litertlm:`, is
still read, with a warning, until the next upstream LiteRT-LM version.

The native libraries are cached per release under
`~/Library/Caches/litertlm_dart/native/` (macOS), `~/.cache/litertlm_dart/native/`
(Linux) or `%LOCALAPPDATA%\litertlm_dart\native\` (Windows). Patches over
upstream include rewinding a stopped turn, NPU fixes and the thinking-budget
fix (`native/litert_lm/patch_c_api.sh`).

## On the web

The same `Engine`, `Conversation` and `EmbeddingEngine` run in a browser over
`@litert-lm/core` 0.18.0, which the page loads itself. Add to
`web/index.html`:

```html
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/+esm');
  window.Engine = m.Engine;
  window.EmbeddingEngine = m.EmbeddingEngine;
  return m.Engine;
})();
</script>
```

`EngineConfig.modelPath` is then a URL the page can fetch (`blob:`, `https:`):
a `.litertlm` web export such as `gemma-4-E2B-it-web.litertlm`. A page that
does not load the module, lacks `window.Engine`, or loads a runtime without
the calls this release makes is refused with a `StateError` naming the
version above.

What differs on the web, measured on `@litert-lm/core` 0.18.0 with Gemma 4
E2B's web export in Chrome 157 (2026-11-23):

- **Text only.** 0.18.0's `Engine` takes no vision or audio backend, and an
  image or audio part fails ("Audio or image item must contain a path or
  blob."), so `visionBackend`, `audioBackend` and `maxNumImages` are refused,
  and so is a message with an image or audio.
- **A stop is a rebuild.** After `cancel()` (or a cancelled subscription) the
  runtime refuses every later send on that conversation ("Task cancelled"),
  so the next message goes to a new conversation built from the old one's
  history, the stopped exchange put back. A stopped generation that does not
  end within 30 s makes the page unusable for LiteRT-LM (the module may still
  be suspended in it): `close()` and every later call fail and say so.
- **Per conversation, not per message:** thinking and the template variables
  (`extraContext`). Repetition penalties, no-repeat n-grams, suppressed
  tokens, a thinking token budget, response formats and speculative decoding
  are refused.
- **The sampler** of the model file cannot be read: a conversation without a
  `samplerConfig` samples with 0.8 / 40 / 0.95 / seed 1, said once per engine.
- **The context window** (`maxNumTokens`) is passed through as given; the
  1024-token floor of the native CPU and GPU executors does not apply, nor
  does the native float32 rule for Gemma 4 on the GPU above 2,048 tokens: the
  web runtime takes no activation type and uses its own.
- **Refused:** the NPU, `cacheDir`, `activationDataType`, the tokenizer,
  option scoring, `benchmark()`, `Conversation.getBenchmarkInfo()`,
  `readBundleInfo`, `readBundleGenericData`. `Backend.cpu` (WebAssembly) is
  handed to the runtime, but it refuses Gemma 4 E2B's web export
  ("tf_lite_prefill_decode not found in the model.").
- **EmbeddingGemma 2** runs on WebGPU only: the CPU (WebAssembly) path of
  `@litert-lm/core` cannot read the bundles' external weights ("Failed to get
  external weight"), so `Backend.cpu` — the default of `EmbeddingEngineConfig`
  — is refused; pass `backend: Backend.gpu()`. `cacheDir` and
  `requireWeightCache` are refused (the web keeps no weight cache). A page
  without WebGPU is refused before anything loads.
- **One module per page.** An LLM and an embedder share the page's
  WebAssembly module and WebGPU device: their calls take turns, and their GPU
  memory adds up.

Run the browser suites with `dart test -p chrome` (and `-c dart2wasm`).

## Libraries

- `package:litertlm_dart/litertlm_dart.dart`: the API above, native and web.
- `package:litertlm_dart/bindings.dart`, `litert_bindings.dart`: the raw
  ffigen bindings to LiteRT-LM's and LiteRT's C APIs, outside the
  compatibility promise; native only.
- `package:litertlm_dart/internal.dart` (no `dart:io`, `dart:ffi` or
  `dart:js_interop`), `internal_io.dart` (native) and `internal_web.dart`
  (web): what `flutter_edge_ai_litertlm` and its tests build on; no
  compatibility promise.

Everything LiteRT-LM lives here. LiteRT.js `.tflite` embeddings (EmbeddingGemma
1, Gecko) stay in `flutter_edge_ai_litertlm`: they are a `flutter_edge_ai`
`TokenEmbeddingPass`, built on core's embedding SPI, as the native `.tflite`
pass is.
