# Advanced GGUF usage

Start with the [chat quick start](../README.md). This guide
covers model-specific features and session behavior.

`createSession`/`createChat` replace and close the previous legacy session.
`openSession`/`openChat` keep independent conversations over the same weights.
Inference and tokenization share one serialized runtime queue; sessions do not
run inference in parallel or allocate separate native KV caches.
`maxConcurrentSessions` limits detached sessions. Closing a model closes all
of its sessions.

The chat examples below assume an already loaded `model`, as in the quick start.
Keep it open while using a chat and close it when your feature ends.

## Sampling

Leave `temperature`, `topK`, `topP` and `randomSeed` unset to use core's defaults
for the installed model family and `enableThinking` mode. Chats may override
`modelType`; that override also selects their sampling defaults. Unknown families
use temperature 0.8, top-k 40, top-p 0.95 and seed 1. The pinned llamadart API does
not expose sampling defaults from the GGUF file itself.

Explicit values override defaults field by field. Use `temperature: 0` or
`topK: 1` for greedy output. An explicit temperature or top-p with no top-k skips
a greedy family default, so a request for sampling remains sampling. Non-finite
or negative temperatures, top-k below 1, and top-p outside `(0, 1]` throw
`ArgumentError` before a usable legacy session is replaced.

## Tools and thinking

Pass tools with object JSON Schemas and `ToolChoice.auto`, `required`, or `none`.
The connector forwards the complete schemas to llamadart and uses its typed
outputs, without Edge AI's model-family parser or a synthetic LiteRT JSON
response. A compatible model/template/runtime is still required. `required`
uses llamadart's grammar path where supported and fails if no call is returned.
Malformed or undeclared calls are rejected before history is committed.

```dart
final chat = await model.openChat(tools: [
  const Tool(name: 'weather', description: 'Get weather', parameters: {
    'type': 'object',
    'properties': {'city': {'type': 'string'}},
    'required': ['city'],
  }),
]);
await chat.addQuery(Message.text(text: 'Weather in Montreal?', isUser: true));
await for (final response in chat.generateChatResponseWithTools(
  onToolCall: (call) async => {'temperature': 18},
)) {
  if (response is TextResponse) print(response.token);
}
```

The bounded Edge AI tool loop is inherited. For manual execution, calls are
core `FunctionCallResponse` instances retaining the call ID. Answer with
`Message.toolResponse(toolCallId: call.id, toolName: call.name, response: result)`.
Ordinary `Message.toolResponse` remains compatible, matching unanswered calls
by name in emission order. Use explicit IDs for out-of-order results when
several calls have the same name. Reused runtime call IDs are remapped to keep IDs unique across turns.
Calls commit before being delivered; all
calls must be answered before the next generation.

Thinking deltas become `ThinkingResponse` only when `enableThinking` is true.
The model can ignore the thinking switch; hidden reasoning still consumes
runtime/output budget. The low-level String session methods return answer text
and JSON tool calls; use the chat `generateChatResponseAsync()` API for typed thinking and tools. The synchronous chat response follows Edge AI's
single-response API: it returns a call group when present, otherwise joined text.

## Images, audio and LoRA

Configure a model-specific projector resolver on `LlamaEngineProvider`:

```dart
final provider = LlamaEngineProvider(
  projectorResolver: (spec, config) async =>
      '/absolute/mmproj.gguf',
);
await FlutterEdgeAi.initialize(inferenceEngines: [provider]);
```

Return a browser URL on Web, including an app-owned cached blob URL. Native
resolvers return an installed local path; SDK-managed downloads are not exposed. The app owns projector
installation and exact model/projector pairing: core has no GGUF projector
slot. The connector probes the loaded projector's vision/audio capabilities.
Set `supportImage`/`supportAudio` on `getActiveModel` and enable the corresponding
chat/session modality. Encoded image/audio bytes map directly to llamadart
content parts; `maxNumImages` is enforced per input message. The text-template
budget preflight does not estimate media embeddings; the runtime enforces its
actual multimodal context requirements. Separate encoder backend overrides
are unavailable in llamadart and fail explicitly.

Installed native adapters load once with the model. Sessions may override them
with `loraPath`; the override is removed and the installed adapter restored before
a peer runs. Missing local override files fail before runtime mutation. Installed `InferenceModelSpec`
LoRA companions are resolved through core's file manager and used by default.
A rejected adapter remains recoverable if restoring the installed adapter succeeds.
Failed restoration or an SDK-reported unusable native context closes the model;
reload it before any peer can infer. Disposal/cleanup failures are reported,
and an inference error remains the primary error when cleanup also fails.
This connector does not wire Web LoRA, even when the bridge supports it.
Installed and per-session Web adapters are rejected explicitly.
Core restores the model and its paired LoRA after restart. If the adapter is
missing, it restores neither rather than silently loading the base model.
GGUF adapter filenames use `model__adapter.gguf`; the connector requires core
2.4.0 for typed tool history.

## Compatibility boundaries

Declare `ModelFileType.gguf`; the connector selects by type rather than filename.
MediaPipe does not claim this type, so provider registration order is irrelevant.
Core now owns imported-file restart restoration; the connector has no preference
reader or activation workaround. Engine contracts use `engine.dart`, and Web URL resolution uses
`engine_web.dart`. Shipped code imports no core internals.

Core 2.3.0 passes the real active model identity to the provider on Web.
The connector selects the supplied spec directly; unrelated binary formats
are rejected. Core reuses the loaded model for unchanged requests, and waits
for a closing model to finish teardown before loading its replacement.
Web resolves core's installed blob/network URLs. Use `WebStorageMode.cacheApi`
or `none`; OPFS stream handles are not accepted by llamadart's URL loader.
Missing bridge assets, unavailable GPU, unsupported projector/template grammar
combinations and runtime capability skew fail with actionable errors. NPU,
LiteRT activation/MTP controls and MediaPipe LoRA ranks remain unsupported for
this GGUF adapter. They describe other engines and cannot be meaningfully
forwarded to llama.cpp through this contract.

Backend reporting uses the runtime backend name, not the requested offload count.
Explicit GPU requests reject a reported CPU backend; unknown identity stays unknown. Runtime usage drives metrics; output tokens are zero/unknown when usage is not
reported. Throughput includes prefill. The demo labels missing output counts as unavailable. Completed turns commit history. Cancellation/errors remove pending user input and
partial assistant output; results of already committed tool calls are retained.

Omitted output caps use remaining rendered context. A truncated tool turn or an
empty completion throws and rolls back. Completed results of prior committed tool
calls survive interruption; replay groups thinking, text and calls in one assistant turn.

## Errors and restored history

Invalid configuration or replay payloads throw `ArgumentError`; unsupported
features throw `UnsupportedError`. Closed/invalid runtime state, empty answers,
malformed generated tools and incomplete tool turns throw `StateError`.
SDK unsupported/model-format/argument failures map to standard `UnsupportedError`
or `ArgumentError`; load-time `LlamaModelException` is preserved so callers can attempt resource-related
fallback (the SDK cannot distinguish corrupt weights from out-of-memory loads).
Other SDK failures map to `StateError`, retaining the original cause and stack. A failed shared-runtime recovery
closes the model so core can reload it; the original failure remains in diagnostics.

`fullHistory` retains committed visible turns across context trimming and close,
so it can be persisted or replayed into a replacement model. Only runtime history
is trimmed. `clearHistory(replayHistory: ...)` commits validated completed turns;
a trailing user input remains staged and rolls back on stop/error. Replayed tool calls read core's typed `Message.toolCalls` through `toolCallsOf`,
with owned argument copies. Text-only histories also accept core's `{"name": "search", "parameters": {"q": "value"}}`, a JSON list of
those objects, and the OpenAI `tool_calls` wrapper. Missing IDs are assigned by the
session; ordinary results pair unanswered calls by name in order. Use
`Message.toolResponse(toolCallId: ...)` when repeated names need results delivered
out of order; retain `toolCallId` when serializing an incompletely answered group. Completed
parallel results are recorded in call order so ordinary core Message fields replay
without losing their association.

Chat `tokenBuffer` must be nonnegative and smaller than `maxTokens`. It is a
trimming target, not a reservation that rejects a valid latest input. Output
caps must be positive and are reduced to the actual remaining rendered context.


Historical tool turns remain replayable under `ToolChoice.none`; that choice
forbids newly generated calls. Results are rendered and persisted in call order.
Missing, reused or non-nine-character-alphanumeric historical IDs receive unique
nine-character alphanumeric IDs, with explicit result references remapped together. An unanswered ID cannot
be reused. Core tool-result copies and equality retain `toolCallId`.

Tool declarations are preflighted against cached template metadata before replacing
an existing chat, without waiting for its running generation. A successful
replacement cancels that turn; an invalid tool declaration leaves it usable. GLM-4.5, Laguna and Hunyuan-V3 accept the SDK's typed parameter
subset; schemas requiring richer constraints fail explicitly for those grammars.
Other formats retain the full schema. If any tool cannot be represented as typed
parameters, the entire set omits that typed view so shared XML grammars do not
lose argument names. The adapter keeps its schema bridge: llamadart 0.13.0's
`ToolDefinition.fromJsonSchema` supports a narrower set of formats and would reject
XML tools. XML nullable-string decoding is a separate SDK limitation; nullable
string arguments can come back as text instead of calls. Use scalar string
properties for those models until the SDK parser is fixed.

The connector rejects a loaded context smaller than requested; request a smaller
`maxTokens` explicitly rather than relying on a silent Web fallback. A fatal SDK
state failure during generation, tokenization or chat preflight closes and evicts
the model. Reload it, then replay the saved `fullHistory`.
