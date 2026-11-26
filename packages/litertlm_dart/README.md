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

It runs inside Flutter apps, in plain Dart programs (`dart run`, `dart
test`, `dart build cli`), and in a browser (see
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
  litertlm_dart: '>=0.19.1+4 <0.19.2'
```

The version is the upstream LiteRT-LM version this package is built from:
the first release on an upstream version carries it as is (`0.20.0`), and
each later one adds its number (`0.20.0+1`, `0.20.0+2`). The releases on
LiteRT-LM 0.19.1 started at `0.19.1+1`. Within one upstream version the Dart API stays compatible,
with one exception: `EmbeddingEngineConfig.cacheDir` became a `String?` in
0.19.1+2 (it was a `String`).
This release runs:

| | |
|---|---|
| Native | LiteRT-LM 0.19.1, our build `native-v0.19.1-c` |
| Web | `@litert-lm/core` 0.20.0 |

`dart pub add litertlm_dart` writes `^0.19.1+4`, which for a 0.x
version also takes later 0.19.x releases; those follow newer LiteRT-LM
releases and may change the Dart API, so bound it at the next upstream patch,
as above, to stay on one.

The build hook downloads our patched LiteRT-LM build (the `native-v*`
releases of this repository, SHA256-verified) for Android arm64, iOS, macOS
arm64, Linux x64/arm64 and Windows x64.

`Message`, `Tool`, `ResponseFormat` and `ActivationDataType` have the names
of LiteRT-LM's Kotlin and Swift types. In code that also imports a library
with types of those names, import this package with a prefix:
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
  // On the web pass Backend.gpu(): the default Backend.cpu() fails Gemma 4's
  // GPU export there (see On the web).
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
  vendor's (unset: where the build puts them on Linux and Windows, beside
  an app's executable or among a plain Dart program's code assets). On Android see [Where it runs today](#where-it-runs-today).
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
`toolCalls`; the calls of tools with `execute` are run for you, see
[Function calling](#function-calling)).

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
    speculativeDecoding: SpeculativeDecodingConfig(
      mode: SpeculativeDecodingMode.on, // or .adaptive, .off
      lenience: 0.1, // optional, in [0, 1]; null is LiteRT-LM's (exact)
    ),
  ),
);
```

A conversation can override it with `ConversationConfig.speculativeDecoding`,
and `benchmark()` takes one too. Unset, it is LiteRT-LM's default (off). The
NPU executor ignores the lenience and stays exact.

## Selected signatures

`EngineConfig.selectedSignatures` compiles and runs only the main model's
signatures named, for example `['prefill_128', 'decode']` (keep a prefill
signature and `decode`, and `verify` with speculative decoding). Each name is
checked against the model before the engine is created; one it does not have
is an `ArgumentError`. Refused on the web.

## LoRA

A conversation takes LoRA adapters, as Kotlin's `LoraConfig`: `.tflite` LoRA
weights for the text model and, on a bundle with an audio encoder, for the
audio encoder. The model must be exported with LoRA input signatures
(LiteRT-LM's LoRA Colab, step 3); a conversation without an adapter on such a
model runs the base weights.

```dart
final engine = await Engine.create(
  EngineConfig(modelPath: '/path/functiongemma_270m_dynamic_lora.litertlm'),
);
final tuned = await engine.createConversation(
  ConversationConfig(loraConfig: LoraConfig(loraPath: '/path/task_lora.tflite')),
);
final base = await engine.createConversation(); // the same engine, no adapter
```

Before the conversation is created, a file that is not there, a model whose
`decode` signature has no LoRA inputs (LiteRT-LM would take the adapter and
leave it without effect) and an NPU engine are refused; the web takes no
adapter. A conversation with an adapter always has its own native
conversation. `EngineConfig.loraRank` / `audioLoraRank` are Swift's: LoRA on
the CPU and the GPU needs no rank, and a rank above 0 is passed with
`set_supported_lora_ranks`, which LiteRT-LM keeps for GPU_ARTISAN only and
reports with an ERROR log line elsewhere.

LiteRT-LM's public source refuses every text LoRA ("Lora is not supported.");
the native libraries this package fetches carry a backport of LiteRT-LM PR
#2508 that loads it (`native/litert_lm/patch_c_api.sh` section 33). A
libLiteRtLm built without it is refused with an `UnsupportedError` that says
so.

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
Kotlin's `OpenApiTool` description). Give it an `execute` function and the
conversation runs the model's calls itself, as Kotlin's and Swift's do by
default (`automaticToolCalling: true`): it runs every call of a reply in
order, sends the results back as one `Message.tool`, and streams the model's
next reply as part of the same message, until a reply calls no tool.

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
  execute: (arguments) =>
      {'city': arguments['city'], 'temperature': 25, 'condition': 'sunny'},
);
final engine = await Engine.create(EngineConfig(modelPath: modelPath));
final conversation = await engine.createConversation(
  ConversationConfig(tools: [weather]),
);

final reply = await conversation.sendMessage(
  Message.user("What's the weather like in London?"),
);
print(reply.text);
```

`execute` may be `async` and returns any JSON value (a map, a list, a
string, a number, a bool or null). If it throws, or returns something that is
not JSON, the model gets the error as text (`Error: …`) and answers on; a
call to a name no tool declares gets `Error: Tool not found: <name>` and does
not stop the loop. Each of these is also printed as a warning. After 25
rounds of calls in one message (Kotlin's and Swift's limit) the send fails
with a `TurnFailedException`. `sendMessageStream` streams the text and thought
of every round, not the calls it ran; `sendMessage` returns the last answer.
A stop (`cancel()` or a cancelled subscription) also stops the loop. A stop
while the tools run ends the reply with their calls: they have run, only their
results were not sent to the model, so do not run them again blindly. A close
while the tools run ends the reply at once with `ConversationClosedException`,
and the calls after the one running are not run.
Natively, with a `responseFormat`, a message goes without it while a tool has
`execute`, so the model can call it; the replies to tool results keep it (the
web refuses a `responseFormat`).

To run the calls yourself, leave `execute` out (a reply calling such a tool is
returned to you with nothing run, even beside calls that have it) or set
`automaticToolCalling: false`. The calls arrive as `ToolCall`s; answer them
with `Message.tool`:

```dart
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
  // A tool without execute is the caller's already; automaticToolCalling:
  // false makes every tool the caller's.
  ConversationConfig(tools: [weather], automaticToolCalling: false),
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

### Tool choice

`sendMessage` and `sendMessageStream` take a `toolChoice` for one message, as
Kotlin's and Swift's `ToolChoice`: `ToolChoice.auto` (the default),
`ToolChoice.none`, `ToolChoice.required`, `ToolChoice.forcedFunction(name)` and
`ToolChoice.allowedTools(names, required: ...)`. It applies to that message's
first round only; the rounds that answer tool results run `auto`, so
`required` cannot loop.

```dart
import 'package:litertlm_dart/litertlm_dart.dart';

Future<Message> askWeather(Conversation conversation) =>
    conversation.sendMessage(
      Message.user("What's the weather like in London?"),
      toolChoice: const ToolChoice.forcedFunction('get_weather'),
    );
```

A choice other than `auto` needs a conversation with tools and no response
format, and must name tools the conversation has; otherwise it is an
`ArgumentError`. With `ToolChoice.none` the model cannot call a tool, but may
still write what a call would look like as text. Refused on the web, whose
runtime has no tool choice.

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
    cacheDir: cacheDir, // required natively: one weight cache per bundle,
    // in a directory that is not backed up; refused on the web
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

- `cacheDir` is a `String?` since 0.19.1+2 (it was a `String`): natively a
  null one is refused with an `ArgumentError`, on the web a set one.
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
| Tools | Kotlin functions or `OpenApiTool`, called automatically by default | `Tool` with a JSON Schema; with `execute` called automatically, as in Kotlin and Swift; limit 25 |
| Speculative decoding | `ExperimentalFlags.enableSpeculativeDecoding` | `EngineConfig.speculativeDecoding`, per conversation too |
| Thinking budget | -1 unlimited, 0 off | unset, or 1 to 2,147,483,647; `enableThinking: false` is off |
| Several conversations per engine | — | yes, a stopped, refused or failed turn recovered before the next |
| Reading a bundle without loading it | — | `readBundleInfo`, `readBundleGenericData` |
| Tokenizer | — | `Engine.tokenize`, `detokenize` |
| Option scoring | — | `Engine.scoreTargets`: the exact log-probability of each target as a continuation |
| Constrained decoding | C++ API | `ResponseFormat.json`, `.regex` |
| `benchmark()` | `BenchmarkInfo` with mark durations | `LlmBenchmarkResult`, plus the whole create's time, the backend and the GPU activation type; no media contents |
| EmbeddingGemma 2 | text, images, audio | the same, text with images and audio in one vector, per-SoC NPU bundles |
| LoRA | `LoraConfig` on the conversation and the session (Kotlin), `loraPath` and `loraRank` (Swift) | `ConversationConfig.loraConfig` (`LoraConfig`), `EngineConfig.loraRank`; the native libraries carry a text LoRA backport (LiteRT-LM PR #2508) |
| Tool choice | per message (Kotlin; Swift has none) | per message, `ToolChoice` |

## Where it runs today

litertlm_dart runs in Flutter apps (Android, iOS, macOS, Linux, Windows), in
plain Dart programs (`dart run`, `dart test`, `dart build cli`) on macOS,
Linux (x64 and arm64) and Windows, and on the web. What an app does itself:

- **Android:** the GPU and the NPU load vendor libraries Android hands out
  only when the app's manifest declares them as `<uses-native-library
  android:required="false">`: `libOpenCL.so`, `libOpenCL-car.so`,
  `libOpenCL-pixel.so` and `libvndksupport.so` for the GPU, `libcdsprpc.so`
  for the Qualcomm NPU, `libedgetpu_litert.so` and `libedgetpu_util.so` for
  Google Tensor, and MediaTek's NeuroPilot libraries for MediaTek. For
  `Backend.npu`, pass a `dispatchDir` holding one vendor's dispatch
  libraries, copied out of the APK by the app.
- **macOS and iOS:** nothing. The hook bundles `LiteRtLm` and
  `StreamProxy`, and that is all there is: the tool-call constraints are
  built into `libLiteRtLm` (LLGuidance) and so is the Metal accelerator.
- **One `libLiteRtLm` per app:** another package that bundles its own
  `libLiteRtLm` through a build hook leaves which build runs undefined.

### In a plain Dart program

`dart run`, `dart test` and `dart build cli` bundle the native libraries
through the build hook, as a Flutter build does; the library lookup follows
the program's code assets. [`example/cli`](example/cli) is a command-line
chat:

```sh
cd example/cli
dart run bin/litertlm_chat.dart gemma-4-E2B-it.litertlm
dart run bin/litertlm_chat.dart --backend gpu gemma-4-E2B-it.litertlm
dart build cli    # build/cli/<os>_<arch>/bundle/: bin/ + lib/, movable
```

The bundle's `lib/` holds the native libraries beside the program (on
Linux the program itself is `lib/libdartaot*.so`, run by the executable in
`bin/`); move the whole `bundle/` directory, not `bin/` alone.

- **The backends of an app, under its rules:** the CPU, the GPU and the NPU,
  for the engine, its encoders and EmbeddingGemma 2. A backend that cannot
  run is refused by name, never moved to the CPU. `Backend.npu()` without a
  `dispatchDir` loads the dispatch from the program's code assets: Intel's
  on Windows x64, Qualcomm's on Linux arm64 with `qualcomm_npu: true` in the
  program's pubspec.yaml (Build options below). The raw LiteRT bindings
  (`litert_bindings.dart`) open the same libraries and reach the GPU
  accelerator the same way as in an app.
- **No define on any platform:** a plain Dart program on macOS needs no
  `hooks: user_defines` entry. `macos_companions`, which litertlm_dart
  0.19.1+4 needed there, is obsolete: the build hook ignores it and prints a
  warning naming it.
- **Copies:** each `dart run` and `dart test` copies the libraries into the
  temporary directory (Dart 3.14 and later): about 40 MB on macOS; 96 MB on
  Linux and 243 MB on Windows, whose libraries include the Intel NPU stack
  (OpenVINO and TBB, 120 MB) and the DirectX shader compiler, measured with
  native-v0.19.1-c, which also carried the constraint provider (22 MB on
  Linux, 13 MB under each of two names on Windows) that no longer ships. A
  `dart build cli` bundle carries the same.
- **Linux and Windows:** the GPU accelerator and Dawn (on Windows also the
  DirectX shader compiler) load with LiteRT-LM whatever the backend; they
  need no GPU to load, and nothing runs on them until a GPU engine does.
- `dart compile exe` runs no build hooks, so it cannot bundle LiteRT-LM; use
  `dart build cli`.

## Build options

Set under `hooks: user_defines: litertlm_dart:` in the pubspec of the app or
program you build (the workspace root's, if it is a workspace member):

```yaml
hooks:
  user_defines:
    litertlm_dart:
      qualcomm_npu: true       # bundle Qualcomm's QNN runtime (Android, Linux arm64)
      google_tensor_npu: true  # Google Tensor G5/G6
      mediatek_npu: true       # MediaTek Dimensity
```

`macos_companions`, read up to litertlm_dart 0.19.1+4, is obsolete and
ignored, with a warning.

On the MediaTek NPU every turn runs in a fresh native conversation that
replays the history: there a conversation answers its second message empty
(MT6989, LiteRT-LM #4256).

The native libraries are cached per release under
`~/Library/Caches/litertlm_dart/native/` (macOS), `~/.cache/litertlm_dart/native/`
(Linux) or `%LOCALAPPDATA%\litertlm_dart\native\` (Windows). Patches over
upstream include rewinding a stopped turn, NPU fixes and the thinking-budget
fix (`native/litert_lm/patch_c_api.sh`).

## On the web

The same `Engine`, `Conversation` and `EmbeddingEngine` run in a browser over
`@litert-lm/core` 0.20.0, which the page loads itself. Add to
`web/index.html`:

```html
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.20.0/+esm');
  window.litertLm = m;
  return m;
})();
</script>
```

`EngineConfig.modelPath` is then a URL the page can fetch (`blob:`, `https:`),
with `backend: Backend.gpu()`. For Gemma 4 E2B use its GPU export
`gemma-4-E2B-it-gpu.litertlm` of 2026-11-11 (2.34 GB, so open it as a stream:
a `blob:` URL of more than 2 GB fails in Chrome); the older
`gemma-4-E2B-it-web.litertlm` of 2026-05-19 answers a tool result with an
empty reply on 0.19.0. Import exactly the version above: this release is
measured on it, and another is said once with `print`, before the engine is
created, when the page fetched it by a versioned URL (0.18.0 refuses the GPU
export: "Unsupported backend: 2", and the create failure names the page's
version). `window.litertLm = m;` hands over the whole module, once: each
member this release calls is read from it when it is called (`Engine` when an
engine is created, `EmbeddingEngine` when an embedding engine is, `Backend`
for both), so all of them come from the one module the page loaded, and a
later release that calls more of it needs no new line. The backend ids sent
and read back are the module's own `Backend` (0.20.0 renumbered them). A page
that does not set `window.litertLm` is refused with a `StateError` quoting the
line to add (on a page that still sets `window.Engine` or
`window.EmbeddingEngine`, the lines it replaces); a module without a member
this release calls, or with a `Backend` it cannot read, is refused naming the
member and the version above (an `EmbedderLoadException` for an embedding
engine). A self-hosted or bundled runtime (`import * as m from
'@litert-lm/core';` in the app's own module) is handed over with the same
lines. Another library that loads its own copy of `@litert-lm/core` (from
another URL) puts a second runtime in the page: this release reads only
`window.litertLm`, but two runtimes sharing the GPU and the page's memory is
not tested.

What differs on the web, measured with Gemma 4 E2B's GPU export on
`@litert-lm/core` 0.20.0 in Chrome 158 (2026-11-25), and on 0.19.0 in
Chrome 157 before it (2026-11-23):

- **Images and audio** run with a `visionBackend` (GPU or CPU) and an
  `audioBackend` (CPU or GPU). A part goes as its bytes (`Content.imageBytes`,
  `Content.audioBytes`); a file path is refused, since the page cannot read
  it. `maxNumImages` counts the images of a whole conversation, not of a
  message as natively: the model reserves their space up front, unset is 1
  with a vision encoder, and an image past it is refused before it is sent
  (0.19.0 failed it: "Image index 1 must be less than 1."; 0.20.0 answers
  it).
- **A stop mid-reply is a rebuild.** After `cancel()` (or a cancelled
  subscription) stops a reply before its end, the runtime refuses every later
  send on that conversation ("Task cancelled"), so the next message goes to a
  new conversation built from the preface, the exchanges so far (images and
  audio included) and the stopped one, kept as natively: its text without
  thoughts, or the tool calls it made. A turn stopped before any output is
  taken back, as natively. A stop with nothing in flight, or after the last
  chunk, changes nothing. A turn the runtime fails
  leaves the conversation refusing every later send too; the next message
  goes to one rebuilt without the failed message. A rebuild that fails is
  tried again by the next message, except where it cannot succeed: a
  history holding a part it cannot replay ends the conversation with a
  `TurnFailedException` that says to open a new one.
- **A message that does not fit.** When the runtime refuses a message for
  its size ("Input token ids are too long." or "Max number of tokens
  reached, the context window is full.", 0.19.0 and 0.20.0), the turn fails with
  `ContextFullException`, as natively, and the message is left out: the next
  message goes to a conversation rebuilt without it, so a shorter one is
  answered. When the history alone fills the window (the conversation held
  `maxNumTokens` tokens), or leaves no room for the shortest message, no
  rebuild can take it, and that turn and every later one fail with
  `ContextFullException` without being sent, as natively a conversation with
  no room left ends every turn at the context limit; nothing is truncated.
  Natively the shortest input is read from the model file; the web cannot
  read it, so it learns a lower bound from the runtime's refusals ("Input
  token ids are too long… X >= Y" counts what that call would prefill: on a
  rebuilt conversation's first call the replayed history and the message) —
  that count less the history and the message's UTF-8 bytes, learnt only
  when the history has a count (a conversation it replaced had prefilled) —
  and takes a
  room within that bound plus one token as none. The bound is low by the
  bytes a token spans, so a conversation one or two tokens from that point
  may be told to send a shorter message once more before it ends. A reply that fills the window ends normally (0.19.0
  and 0.20.0 report nothing), so the turn after it is the one refused. A stopped generation that
  does not end within 30 s, after a stop or a close, makes the page unusable
  for LiteRT-LM (the module may still be suspended in it): the turn,
  `close()` and every later call fail and say so.
- **Per conversation, not per message:** thinking and the template variables
  (`extraContext`). Repetition penalties, no-repeat n-grams, suppressed
  tokens, a thinking token budget, response formats and speculative decoding
  are refused.
- **The sampler** of the model file cannot be read: a conversation without a
  `samplerConfig` samples with 0.8 / 40 / 0.95 / seed 1, said once per engine.
- **The context window** (`maxNumTokens`) is passed through as given (unset:
  the bundle's, 8192 for the GPU export); the 1024-token floor of the native
  CPU and GPU executors does not apply, nor does the native float32 rule for
  Gemma 4 on the GPU above 2,048 tokens: the web takes no activation type
  (below), and the runtime uses the bundle's (FP16 for the GPU export).
- **Refused:** the NPU, `cacheDir`, `activationDataType`, the tokenizer,
  option scoring, `benchmark()`, `Conversation.getBenchmarkInfo()`,
  `readBundleInfo`, `readBundleGenericData`. `Backend.cpu` (WebAssembly), the
  default of `EngineConfig`, is handed to the runtime, but Gemma 4's GPU
  export fails at the first send there ("Environment was not initialized
  during streaming."): pass `Backend.gpu()`.
- **EmbeddingGemma 2** runs on WebGPU only: the CPU (WebAssembly) path of
  `@litert-lm/core` cannot read the bundles' external weights ("Failed to get
  external weight"), so `Backend.cpu` — the default of `EmbeddingEngineConfig`
  — is refused; pass `backend: Backend.gpu()`. `cacheDir` and
  `requireWeightCache` are refused (the web keeps no weight cache). A page
  without WebGPU is refused before anything loads. Images on the 270m and
  audio on the 270m or the 440m are refused from the bundle's header: the
  runtime creates those towers and fails only the first input.
- **One module per page.** An LLM and an embedder share the page's
  WebAssembly module (4 GB) and WebGPU device: their calls take turns, and
  their memory adds up. The 440m with images loads next to Gemma 4 E2B's GPU
  export and embeds while a reply streams.

Run the browser suites with `dart test -p chrome` (and `-c dart2wasm`).

## Libraries

- `package:litertlm_dart/litertlm_dart.dart`: the API above, native and web.
- `package:litertlm_dart/bindings.dart`, `litert_bindings.dart`: the raw
  ffigen bindings to LiteRT-LM's and LiteRT's C APIs, outside the
  compatibility promise; native only.
- `package:litertlm_dart/internal.dart` (no `dart:io`, `dart:ffi` or
  `dart:js_interop`), `internal_io.dart` (native) and `internal_web.dart`
  (web): internals for packages built on this one; no compatibility promise,
  not for apps.
