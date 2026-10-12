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
`LlamaFunctionCallResponse` instances retaining the call ID. Answer with
`LlamaToolResponseMessage(callId: call.id, toolName: call.name, response: result)`.
Ordinary `Message.toolResponse` remains compatible, matching unanswered calls
by name in emission order. Use explicit IDs for out-of-order results when
several calls have the same name. Reused runtime call IDs are remapped to keep IDs unique across turns.
Calls commit before being delivered; all
calls must be answered before the next generation.

Thinking deltas become `ThinkingResponse` only when `enableThinking` is true.
The model can ignore the thinking switch; hidden reasoning still consumes
runtime/output budget. The low-level String session methods return answer text
and JSON tool calls; use the connector chat or session `getResponses()` for
typed thinking and tools. The synchronous chat response follows Edge AI's
single-response API: it returns a call group when present, otherwise joined text.

## Images, audio and LoRA

Configure a model-specific projector resolver on `LlamaEngineProvider`:

```dart
import 'package:llamadart/llamadart.dart' as llama;

final provider = LlamaEngineProvider(
  projectorResolver: (spec, config) async =>
      llama.ModelSource.path('/absolute/mmproj.gguf'),
);
await FlutterEdgeAi.initialize(inferenceEngines: [provider]);
```

Use a browser URL with `llama.ModelSource.path(...)` on Web. The app owns projector
installation and exact model/projector pairing: core has no GGUF projector
slot. The connector probes the loaded projector's vision/audio capabilities.
Set `supportImage`/`supportAudio` on `getActiveModel` and enable the corresponding
chat/session modality. Encoded image/audio bytes map directly to llamadart
content parts; `maxNumImages` is enforced per input message. The text-template
budget preflight does not estimate media embeddings; the runtime enforces its
actual multimodal context requirements. Separate encoder backend overrides
are unavailable in llamadart and fail explicitly.

Native sessions accept `loraPath`, applying the adapter during their exclusive
turn and removing it before a peer runs. Installed `InferenceModelSpec`
LoRA companions are resolved through core's file manager and used by default.
If applying/removing an adapter fails, the shared runtime is invalidated:
close/reload the model before any peer can infer with uncertain adapter state.
Web LoRA operations are unavailable in llamadart 0.11.1 and remain unsupported.
Core does not persist the inference LoRA companion in its restart identity;
after restart, reinstall the paired spec or pass `loraPath` explicitly.

## Compatibility boundaries

Core 2.2.1 has no `ModelFileType.gguf`; only binary specs with a `.gguf` primary
filename are claimed. Do not register another binary provider for these models.
Core now owns imported-file restart restoration; the connector has no preference
reader or activation workaround. The remaining Web shim and engine imports will
move to public core libraries after the 2.3.0 API train lands.

Core Web probes a synthetic `web-active` / `active.bin` spec. The connector
recovers the active installed identity for that exact probe before selecting
and loading it; unrelated binary formats are still rejected.
Web resolves core's installed blob/network URLs. Use `WebStorageMode.cacheApi`
or `none`; OPFS stream handles are not accepted by llamadart's URL loader.
Missing bridge assets, unavailable GPU, unsupported projector/template grammar
combinations and runtime capability skew fail with actionable errors. NPU,
LiteRT activation/MTP controls and MediaPipe LoRA ranks remain unsupported for
this GGUF adapter. They describe other engines and cannot be meaningfully
forwarded to llama.cpp through this contract.

Explicit GPU requests fail if the runtime reports zero GPU layers; unknown
backend identity remains unknown. Runtime usage drives metrics; output tokens are zero/unknown when usage is not
reported. Throughput includes prefill. The demo labels missing output counts as unavailable. Native termination is available as
`LlamaInferenceSession.lastFinishReason`. Only completed turns commit history;
cancellation/error removes pending input and partial output.
