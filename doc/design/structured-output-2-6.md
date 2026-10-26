# Structured output in core 2.6.0 (#195): design

Status: **proposal, nothing implemented.** Branch `design/structured-output-2-6`
off `main` `de0711e1`. The numbered decisions at the end are Sasha's to make.

Already decided (2026-10-21, not reopened here):

- It ships in core **2.6.0** as a parameter of the main API: `createSession`,
  `openSession`, `createChat`, `openChat`. Not a mixin.
- Every engine either **enforces** the format or **refuses** it with a typed
  exception. No engine ignores it.
- 2.6.0 deprecates `createSession` / `createChat` (and the `session` / `chat`
  fields) in favour of `openSession` / `openChat`; 3.0.0 only removes them.
- The Decider SPI moves off the `OptionScoringModel` mixin onto
  `InferenceModel` with refusing defaults (separate item, see §9).

Not decided: the exact shape. This document recommends B (core owns the entry
points) over A (a parameter each engine handles) and C (per-turn format). The
recommendation changed from A to B after an independent review (§11).

---

## 1. Evidence: what each engine can enforce

Everything below was read or measured on 2026-10-26 unless marked otherwise.

### 1.1 LiteRT-LM native (`flutter_edge_ai_litertlm`, FFI)

- **The C API has it.** Upstream `c/conversation.h` @ `v0.18.0` (our pin
  `b2f686e2`):
  - `litert_lm_conversation_config_set_constraint_provider(config, const LiteRtLmConstraintProviderType*)`
    with `kLiteRtLmConstraintProviderTypeLlGuidance = 1`;
  - `litert_lm_conversation_optional_args_set_constraint(args, LiteRtLmConstraintType, const char*)`
    with `kLiteRtLmConstraintTypeRegex = 1`, `kLiteRtLmConstraintTypeJsonSchema = 2`.
  - Not in `native/litert_lm/include/engine.h` (the header the inference
    bindings are generated from, `ffigen.yaml:6`) and not in the generated
    `litert_lm_bindings.dart` today: both need binding.
- **Shipped.** `nm -gU` on the android_arm64, ios_arm64 and macos_arm64
  `libLiteRtLm` in the hook cache (`native-v0.18.0-g`, 2026-10-26) shows both
  functions exported. Linux and Windows: not re-checked.
- **Three behaviours of 0.18.0 that shape the design**
  (`runtime/conversation/conversation.cc` @ `v0.18.0`, `CreateDecodeConfig`,
  lines 397-415):
  1. A constraint passed to a send is used **only if the conversation was
     created with a provider** (`decoding_constraint.has_value() &&
     constraint_provider_ != nullptr`). Without the provider it is dropped with
     no error: the silent-ignore case. The engine must always set both.
  2. The constraint is stored in the member `constraint_` and **never reset**:
     a later send without a constraint still decodes under the old one
     (`kLiteRtLmConstraintTypeNone` sets nothing, `c/conversation.cc:118`). A
     send with another constraint replaces it, so only clearing it is
     impossible without rebuilding the conversation.
  3. The tool constraint (`enable_constrained_decoding` + the Gemma provider)
     is the `else` branch of the same `if`: a send can be under the schema or
     under the tool grammar, never both.
- **An invalid schema** fails inside `CreateConstraint` at every send
  (`absl::InternalError("Failed to create LLGuidance constraint: …")`,
  `llg_constraint_provider.cc:155-159`), not at conversation create. There is
  no compile-only call in the C API. By then native has already pushed the
  user message into `history_` (`conversation.cc:588-598`).
- **GPU and NPU apply the mask in the v0.18.0 source; neither has been run.**
  CPU/GPU: `ProcessLogits` before sampling
  (`llm_litert_compiled_model_executor.cc:1373-1388`); a GPU buffer is copied
  to the host, masked and written back (`constrained_decoder.cc:42-66`), a
  vocabulary-sized copy per token. NPU: masked logits, then greedy sampling,
  MTP off under a constraint (`llm_litert_npu_compiled_model_executor.cc:879-910`,
  `:1029-1033`). Correctness and tokens per second on a device are what remain
  (§6).

### 1.2 LiteRT-LM web (`@litert-lm/core` 0.18.0)

- The four WASM builds contain the string `llguidance` (4 hits each), but the
  JS API exposes no way to pass a constraint: `ConversationConfig` has only
  `enableConstrainedDecoding?: boolean` (the tool grammar), and
  `Conversation.sendMessage(message)` / `sendMessageStreaming(message)` take no
  options (`dist/conversation_config.d.ts:150-156`, `dist/conversation.d.ts:31,36`).
- **Refuse.**

### 1.3 ONNX (`flutter_edge_ai_onnx`, ORT-GenAI 0.14.0 pinned)

- `OgaGeneratorParamsSetGuidance(params, type, data, enable_ff_tokens)` is
  already in the generated bindings (`ort_genai_bindings.g.dart:1302`), types
  `json_schema`, `regex`, `lark_grammar`.
- Which archives carry llguidance — the hook's 0.14.0 copies in
  `~/Library/Caches/flutter_gemma/native/onnx_genai/` (`.version` =
  `genai-0.14.0`):

  | archive | llguidance strings | `use_guidance` rebuild message |
  |---|---:|---:|
  | macOS arm64 | 18 | 0 |
  | Android arm64 | 0 | 1 |
  | iOS arm64 | 0 | 1 |

  Linux x64 and Windows x64 carry it (samarthsinh2660 on #195, measured on
  Linux; Windows "carries it" per the same comment). Windows ARM64: not checked.
- 0.14.0 on a build without llguidance **accepts and ignores** the call (vivo
  1933, #195); 0.17.0 throws "Rebuild with use_guidance=true" (#704, source
  lines cited there). So the ONNX part depends on #704; until then the engine
  must refuse on Android/iOS itself, before calling ORT. #704 does not add
  Android support: Microsoft's AAR build passes no `--use_guidance` and
  `USE_GUIDANCE` defaults to OFF (v0.17.0
  `tools/ci_build/github/android/default_aar_build_settings.json`,
  `cmake/options.cmake:8`); ONNX Android would need our own ORT-GenAI build.
- ONNX has no `openSession` today (#703): `openSession` / `openChat` throw
  `UnsupportedError` with or without a format.
- Web (Transformers.js): no constraint wiring. **Refuse.**
- Measured value (samarthsinh2660, #195, Phi-3.5-mini, Linux CPU, 100 prompts):
  bare JSON 4/100 → 100/100, 144 → 40 tokens per prompt, 10.7 → 3.7 s; same
  89/100 correct values in every arm (it fixes the shape, not the answers).

### 1.4 Built-in AI (`flutter_edge_ai_builtin_ai` over `flutter_local_ai` 0.3.0)

`LocalAiSession.getStructuredResponse(Map schema)` (`local_ai_session.dart:150`),
validated in Dart first by `validateGenerationSchema` (subset: objects with
`properties`/`required`, arrays with `items`/`minItems`/`maxItems`, string
enums, scalar `string|integer|number|boolean`; no union/nullable types).
Per platform (`supportsStructuredOutput` in each host):

| platform | value | source |
|---|---|---|
| iOS / macOS | true on OS 26.0+ | `darwin/.../LocalAiSessionService.swift:330-334` |
| Chrome (Prompt API) | true (`responseConstraint`) | `session/web/local_ai_host_web.dart:180,496` |
| Windows (Phi Silica) | true, `GenerateStructuredJsonResponseAsync`, App SDK 2.0+ | `windows/local_ai_session_service.cpp:254-255,426` — **not run by me** |
| Android (ML Kit) | false | `android/.../LocalAiSessionService.kt:239` |
| Linux | no built-in AI | — |

- **No streaming with a schema** on any backend: `generateTextStream` throws
  "Streaming structured (JSON/schema) output is not supported on any backend
  yet" (`lib/src/flutter_local_ai.dart:199-207`).
- `validateGenerationSchema` checks the constructs it knows and ignores
  unknown keys (`pattern`, `minimum`, `const`, … pass), and Apple's
  `SchemaBuilder` reads only `description`, string `enum`, `type`,
  `properties`, `required`, `items`, `minItems`, `maxItems`
  (`GenerationSchemaBuilder.swift:30-70`). It is not a refusal list.
- Foundation Models defaults `includeSchemaInPrompt: true` and flutter_local_ai
  does not override it: on Apple the schema is in the prompt.
- `jsonObject` ("any object"): the validator accepts `{}` and an object with
  no `properties` (`schema_validation.dart:62-80`, test
  `schema_validation_test.dart:40`), but what Apple's `GenerationSchema`,
  Chrome's `responseConstraint` and Windows make of a property-less object
  (any object, or exactly `{}`) is not known. Refuse `jsonObject` on built-in
  AI until it is measured per platform.

### 1.5 llama.cpp (`flutter_edge_ai_llama` over llamadart 0.15.1)

- `LlamaEngine.create(..., Map<String, dynamic>? responseFormat)`
  (`engine.dart:1626-1633`), OpenAI shape: `{'type': 'json_object'}` or
  `{'type': 'json_schema', 'json_schema': {'schema': …}}` → GBNF
  (`response_format.dart`). An unknown shape throws `LlamaUnsupportedException`.
- A backend without grammar support throws `LlamaUnsupportedException` for
  any strict format (`chat_completion_request_planner.dart:241-256`); llamadart
  reports `supportsStructuredOutput` false only on LiteRT-LM. **WebGPU
  enforces a strict format**; it refuses only format + tools, which needs a
  lazy grammar it lacks (`engine_capabilities.dart:99-103`,
  `webgpu_backend.dart:145-147` `supportsLazyGrammar => false`,
  planner `:110-115`). My first draft said WebGPU refuses: wrong, corrected
  after review.
- The capability is readable before generation:
  `engine.capabilities.supportsStructuredOutput`.
- llamadart also validates the final text against the schema
  (`LlamaStructuredOutput.parse`, `structured_output.dart:136`) and documents
  its JSON-Schema-to-GBNF subset (`:65-75`): primitives, objects with
  `properties`/`required`/`additionalProperties`, arrays, `enum`/`const`,
  local `$ref`, `anyOf`/`oneOf`, bounds, formats, `pattern`; unsupported
  keywords throw before generation, annotations and unknown vocabulary are
  kept but not enforced.
- Tools + format on native llama.cpp **reroutes the chat format to
  `generic`** (`chat_template_engine.dart:193-195`), and is refused with
  `LlamaUnsupportedException` when any tool uses a canonical JSON schema
  (`:440-452`).
- Not passed through today: `llama_inference_session.dart:635-642` calls
  `engine.create` without `responseFormat`.

### 1.6 MediaPipe (`flutter_edge_ai_mediapipe`, Android/iOS 0.10.33, web 0.10.29)

No constraint option in the bound API (`pigeon.dart`, `lib/src/web/` — no
match for constrain/schema/grammar). Maintenance-only upstream (AGENTS.md).
#720 rewrites the web session (conversation owned by `WebModelSession`) and
does not change this. **Refuse everywhere.**

### 1.7 Summary matrix (what 2.6.0 would ship)

| engine / platform | `jsonSchema` | `jsonObject` | streaming | evidence level |
|---|---|---|---|---|
| LiteRT-LM native, CPU | enforce | enforce (`{"type":"object"}`) | yes | API read, export checked (macOS); run: not yet |
| LiteRT-LM native, GPU | enforce if §6 run passes, else refuse | same | yes | to measure |
| LiteRT-LM native, NPU | refuse | refuse | — | not measured |
| LiteRT-LM web | refuse | refuse | — | JS API read |
| ONNX macOS arm64 / Linux x64 / Windows x64 | enforce (after #704) | enforce | yes | Linux measured by contributor; macOS archive checked |
| ONNX Windows ARM64 | refuse until checked | refuse | — | not checked |
| ONNX Android / iOS | refuse | refuse | — | archives checked: no llguidance |
| ONNX web | refuse | refuse | — | — |
| Built-in AI iOS/macOS 26+, Chrome | enforce (schema subset) | refuse until measured | buffered (§4.3) | source read |
| Built-in AI Windows | enforce (schema subset) | refuse until measured | buffered | source read, not run |
| Built-in AI Android | refuse | refuse | — | source read |
| llama.cpp native | enforce | enforce | yes | source read |
| llama.cpp WebGPU | enforce | enforce | yes | source read (refuses only format + tools) |
| MediaPipe (all) | refuse | refuse | — | — |


---

## 2. Proposed API (option B: core owns the entry points)

### 2.1 Why core, not each engine

The rule "enforce or refuse, never ignore" cannot be held by a parameter each
engine handles. `interface.dart:444-452` records the precedent: the base
`createChat` dropped `tools` on its way to `createSession`, so every engine
using that base silently ran without tools. A forgotten `responseFormat` in
one override is the same bug and nothing in core would see it. So core owns
the four public methods; an engine implements one protected hook and can only
receive a format through it, after core has checked it.

### 2.2 `ResponseFormat` (core, app library)

```dart
/// What every reply of a session must be. Fixed for the session's lifetime:
/// LiteRT-LM keeps a constraint for the whole conversation (§1.1): a later
/// turn cannot drop it without rebuilding the conversation.
sealed class ResponseFormat {
  const ResponseFormat._();

  /// A JSON value valid against [schema]. Not const: the schema is
  /// deep-copied into unmodifiable maps/lists and canonicalised at
  /// construction (ArgumentError if not JSON-encodable or the root is not a
  /// map), so the caller mutating its map later changes nothing.
  factory ResponseFormat.jsonSchema(Map<String, Object?> schema, {String? name}) =
      JsonSchemaResponseFormat._;

  /// Any JSON object (`{"type": "object"}`).
  const factory ResponseFormat.jsonObject() = JsonObjectResponseFormat._;
}

final class JsonSchemaResponseFormat extends ResponseFormat {
  Map<String, Object?> get schema;   // unmodifiable deep copy
  String get schemaJson;             // caller's key order: grammars emit properties in schema order
                                     // (llamadart json_schema_converter.dart:727); sorted form only for ==
  String? get name;                  // sent where an engine takes one (llama; flutter_local_ai takes none)
  // == / hashCode on schemaJson + name
}

final class JsonObjectResponseFormat extends ResponseFormat { … }
```

No `regex` and no `text` variant in 2.6.0 (decision 4). `sealed`: a later
variant breaks exhaustive switches in engines on purpose.

### 2.3 Public signatures

`ResponseFormat? responseFormat` (default `null` = today) on all four:

```dart
@nonVirtual Future<InferenceModelSession> openSession({ …existing…, ResponseFormat? responseFormat });
@nonVirtual Future<InferenceChat> openChat({ …existing…, ResponseFormat? responseFormat });
@Deprecated(…) @nonVirtual Future<InferenceModelSession> createSession({ …, ResponseFormat? responseFormat });
@Deprecated(…) @nonVirtual Future<InferenceChat> createChat({ …, ResponseFormat? responseFormat });
```

`InferenceChat` gets a read-only `responseFormat`; its session creator carries
it, so the overflow rebuild (`chat.dart:1073`) and the single-turn rebuild
(`chat.dart:353`) keep it.

Capability, so an app can ask before creating a session:

```dart
/// What this loaded model can enforce (engine, platform and the backend it
/// was loaded on). Default: nothing.
StructuredOutputSupport get structuredOutputSupport;

final class StructuredOutputSupport {
  static const none = …;
  final bool jsonSchema;
  final bool jsonObject;
  final StructuredDelivery delivery;       // incremental | buffered (one chunk at the end)
  /// Why a given format would be refused here, or null if it would be accepted:
  /// the engine/platform/backend, or the first schema keyword at a JSON path
  /// this engine cannot enforce.
  String? refusalFor(ResponseFormat format);
}
```

### 2.4 Engine SPI (`package:flutter_edge_ai/engine.dart`)

```dart
/// Everything an engine needs to open a session. New options become fields,
/// so the next one does not break engines again (as DeciderRequest does).
final class SessionRequest {
  final double? temperature; final int? randomSeed; final int? topK; final double? topP;
  final String? loraPath; final bool? enableVisionModality, enableAudioModality; // null = model default
  final String? systemInstruction; final bool enableThinking;
  final List<Tool> tools; final int? maxOutputTokens;
  final ResponseFormat? responseFormat;
  final bool legacySingleton; // true for createSession: replaces `session`
}

abstract class InferenceModel {
  @protected Future<StructuredSessionHandle> openEngineSession(SessionRequest request);
  @protected StructuredOutputSupport get engineStructuredOutputSupport => StructuredOutputSupport.none;
  /// Optional: an engine with its own chat type (llama's LlamaInferenceChat).
  @protected InferenceChat buildChat(ChatRequest request, SessionCreator creator) => InferenceChat(…);
}

/// How a turn ended, reported by the engine for every turn.
enum TurnEnd { endOfSequence, outputLimit, contextLimit, stopped }
```

Core's `openSession`: check arguments (§2.6) → `refusalFor(format)` → if
refused, `ResponseFormatUnsupportedException` before the engine is called →
`openEngineSession(request)` → wrap the session in core's reply guard (§4.1),
which reads the engine's `TurnEnd` for each turn. An engine that has not
opted in reports `none` and never receives a format.

The engine reports `TurnEnd` through the session it returns
(`StructuredSessionHandle` = an `InferenceModelSession` plus
`TurnEnd? get lastTurnEnd`); it is needed only when a format is set. Today
no engine reports it: LiteRT-LM turns a requested cancel into a clean end
(`litert_lm_client.dart:2200-2207`) and ONNX keeps its stop flag private;
each records it once (stopped: the session knows it asked; output limit:
token count = `maxOutputTokens`; context: the engine's own overflow check).

### 2.5 Exceptions

```dart
abstract base class StructuredOutputException implements Exception { final String message; }

/// Refused at session creation: engine/platform/backend, a schema keyword the
/// engine (or core's validator, §4.2) cannot enforce, or a schema the engine
/// rejected. On LiteRT-LM a schema the native compiler rejects is first seen
/// at the first send (§4.4) and thrown from there.
final class ResponseFormatUnsupportedException extends StructuredOutputException {
  final String? schemaPath;
}

/// The turn ended before the value was complete: [end] is outputLimit,
/// contextLimit or stopped. [partialText] is what was generated (and is in the
/// chat history, §3).
final class IncompleteStructuredOutputException extends StructuredOutputException {
  final TurnEnd end; final String partialText;
}

/// The turn ended normally but the text is not a value of the format: not
/// JSON, trailing text, wrong root type, or a schema violation core can see.
/// Means an engine did not enforce what it accepted: an engine bug, never
/// expected in normal use.
final class NonConformingStructuredOutputException extends StructuredOutputException {
  final String text; final String? schemaPath;
}
```

A stop after the value was already complete but before end-of-sequence:
`TurnEnd.stopped` with a parseable `partialText` → still
`IncompleteStructuredOutputException(end: stopped)`; the app can parse
`partialText` if it wants (decision 9).

### 2.6 Argument errors (core, `ArgumentError`, same on every engine)

- `responseFormat` with a non-empty `tools` list (decision 5);
- `responseFormat` with `enableThinking: true` (decision 6).

### 2.7 Per-engine work

| engine | work |
|---|---|
| LiteRT-LM native | bind the two C functions (vendor the constraint section of `c/conversation.h`, regenerate); a structured session's conversation gets `set_constraint_provider(LlGuidance)` at create and `set_constraint(JsonSchema, schemaJson)` on every send; support = CPU (GPU per §6), NPU refused; the multiplexed conversation (`_VirtualConversationHandle`) is rebuilt on session switch, so a structured and a plain session can share the model, and the plain one's conversation must be created without the provider; report `TurnEnd`; first-send schema failure per §4.4 |
| LiteRT-LM web | `none` |
| ONNX native | after #704: `OgaGeneratorParamsSetGuidance(params, "json_schema", schemaJson, false)` (`enable_ff_tokens` off: no gain measured, drops forced tokens from the stream, #195); support only on macOS arm64, Linux x64, Windows x64; needs #703 for `openSession` at all |
| ONNX web | `none` |
| Built-in AI | support from `LocalAi.capabilities().supportsStructuredOutput` (read at model creation); `refusalFor` runs `validateGenerationSchema`; `getResponse` → `getStructuredResponse`; delivery `buffered`; `jsonObject` refused until measured |
| llama | support from `engine.capabilities.supportsStructuredOutput`; build `LlamaStructuredOutput` at session creation (its unsupported-keyword check happens there, not at generation); pass its `responseFormat` to `engine.create`; only the format's own `LlamaUnsupportedException`s become `ResponseFormatUnsupportedException`, others stay as they are; `buildChat` keeps `LlamaInferenceChat` |
| MediaPipe | `none` |

`canHandle` is unchanged everywhere: a format never changes which engine
loads a file.

---

## 3. Interaction with other options

| option | rule in 2.6.0 | why |
|---|---|---|
| `tools` | non-empty + format → `ArgumentError` | LiteRT-LM: schema and tool grammar exclude each other (§1.1 point 3); llama reroutes the chat format and refuses the pair on WebGPU; built-in AI has no combined call. Can be widened per engine later |
| `enableThinking: true` | + format → `ArgumentError` | LiteRT-LM upstream suspends the user constraint during thinking when a thinking budget ≠ 0 reaches the decode config (`runtime/core/tasks.cc:642-656`), but our client sends one only with `thinkingTokenBudget`; otherwise the budget is 0 (`conversation.cc:394`) and the schema masks from the first token. Neither path is measured. A Qwen3 model that thinks by tag is constrained from its first token and cannot open `<think>`: intended |
| thinking budget (#721) | n/a | — |
| `maxOutputTokens` | allowed; cut → `IncompleteStructuredOutputException(outputLimit)` | docs say to leave room |
| context window | overflow → same, `contextLimit` | — |
| streaming | chunks = raw JSON text; at the end, after the last chunk, the guard emits the error if any | an app may render partial JSON |
| `stopGeneration` | `IncompleteStructuredOutputException(stopped)` | a structured turn never returns non-conforming text as success |
| `systemInstruction` | unchanged; core does not insert the schema into the prompt | never rewrite the prompt silently; docs recommend naming the fields in the prompt (#195 numbers: guidance fixes the shape, the prompt the values) (decision 10) |
| images / audio | allowed | constraint acts on decoding only |
| sampling | unchanged | the mask applies before sampling |
| `InferenceChat` parsing | the thinking filter (`ModelThinkingFilter`) and tool parsers are bypassed for a structured chat | the parsers already need tools (`chat.dart:262-268`, `:307-310`); the thinking filter runs for every model and could cut a `<think>` inside a JSON string |
| chat history | the reply is committed to history **before** the guard throws (sync and stream paths) | matches native: LiteRT-LM's virtual handle records the turn even on error (`ffi_inference_model.dart:1385-1420`), and a stopped reply is kept since #682. Today `InferenceChat` commits only after `getResponse` returns / the `await for` completes (`chat.dart:336-339`, `:804-813`), so this is a change there |

---

## 4. Behaviour details

### 4.1 The reply guard (core)

For every turn of a structured session, at its end:

1. `TurnEnd` is `outputLimit` / `contextLimit` / `stopped` →
   `IncompleteStructuredOutputException`.
2. `endOfSequence` → trim whitespace; `jsonDecode` must consume the whole
   text; root type must match; then the schema check (§4.2). Any failure →
   `NonConformingStructuredOutputException`.

No unwrapping of code fences or prose: a constrained decoder emits none.

### 4.2 Schema check in core

Engines enforce different subsets (llguidance, llamadart's GBNF subset,
Apple's `GenerationSchema`). If core only checked "valid JSON", an engine that
accepted a schema and enforced part of it would pass. Proposal: core
validates the final value for a fixed keyword set — `type`, `properties`,
`required`, `additionalProperties: false`, `items`, `enum`, `const`,
`minItems`/`maxItems`, `minLength`/`maxLength`, `minimum`/`maximum` — and a
schema using any other validation keyword (`pattern`, `$ref`, `anyOf`,
`oneOf`, `allOf`, `format`, …) is refused at session creation in 2.6.0, with
the keyword and its path. Annotations (`description`, `title`, `examples`) are
allowed. The set can grow per release with tests. Cost: a small validator in
core (no new dependency), and some schemas llguidance could enforce are
refused at first (decision 7).

### 4.3 Built-in AI delivery

`flutter_local_ai` 0.3.0 cannot stream a structured reply. `getResponseAsync`
yields the whole reply as one chunk when it is done (`delivery: buffered`).
A cancel of that subscription stops the native call as `stopGeneration` does
(to test). The alternative is refusing `getResponseAsync` there (decision 8).

### 4.4 LiteRT-LM: a schema rejected at the first send

There is no compile call; llguidance compiles inside `CreateConstraint` at the
first send. With §4.2 most schemas core accepts are plain, but llguidance can
still reject one. Then the turn must leave no trace: today
`_VirtualConversationHandle` records the user turn and an empty assistant turn
in `finally`, even when the stream never started (`ffi_inference_model.dart:1385-1420`),
and native has already pushed the user message into its own `history_`
(`conversation.cc:588-598`). The status is `INTERNAL`, shared with unrelated
failures; only the message prefix "Failed to create LLGuidance constraint"
tells it apart (`llg_constraint_provider.cc:155-159`). Since the format is
fixed per session and recompiled on every send, every later send fails too:
such a session is terminal. Option to avoid this: compile at session creation by one
throwaway send with `max_output_tokens = 1` on a throwaway conversation —
costs one prefill per structured session; not proposed for 2.6.0.

---

## 5. Deprecation plan (2.6.0 → 3.0.0)

1. 2.6.0: `@Deprecated('Use openSession(). Removed in 3.0.0.')` on
   `createSession`, the same for `createChat`, `session`, `chat`.
2. **Blocker:** `openSession` throws on ONNX native and web (#703) and on
   MediaPipe web (base `UnsupportedError`; #720 leaves it out of scope).
   Deprecation lands only in a release where every shipping engine has a
   working `openSession` (decision 2).
3. Making the four methods `@nonVirtual` is breaking for every engine, in and
   out of tree, in a minor — the project's precedent (2.1/2.2/2.3/2.5, e.g.
   2.2.1 "Breaking for `implements InferenceModel`: add `isClosed`",
   satellites at `^2.6.0`), but the largest break of
   2.x. It replaces, not adds to, the cost of A, where every override changes
   its signature anyway.
4. In-repo callers move to `open*` in the same release:
   `genkit_flutter_edge_ai` (`flutter_edge_ai_model.dart:267`),
   `flutter_edge_ai_agent` (`agent_session.dart:183`), the example app,
   codelabs, website docs, `.claude/skills` and `skills/`.
5. Behaviour difference for users: `createSession` closes the previous legacy
   session; `openSession` does not and counts against
   `maxConcurrentSessions`. A rename-only migration that opens a session per
   turn leaks them. MIGRATION.md gets a before/after.
6. 3.0.0 removes the deprecated members; nothing else.

---

## 6. Test plan

Rule 6 / 6b: native integration tests with `flutter test
integration_test/<file>.dart -d <device>`; web with `flutter drive`, no
`setUp`.

**Core (VM):**
- `ResponseFormat`: deep copy (mutating the caller's map after construction
  changes nothing), canonical `schemaJson`, equality, `ArgumentError` for a
  non-encodable schema / non-map root.
- Argument checks: tools + format, thinking + format; refusal before the
  engine hook is called (a fake engine counts calls).
- Reply guard: every `TurnEnd` × {complete, truncated, empty, trailing text,
  wrong root, schema violation for each keyword of §4.2}; a stop after a
  complete value; an unsupported keyword refused with its path.
- `InferenceChat`: format reaches every session creation incl. both rebuilds;
  a JSON reply shaped like a tool call stays `TextResponse`; partial reply is
  in history after `IncompleteStructuredOutputException` on both paths; the
  next turn after it works; a `<think>` inside a JSON string survives.
- Public surface goldens (`test/public_surface/`) regenerated and reviewed.

**Engines (fakes, VM):**
- LiteRT-LM: provider + constraint on every send of a structured session,
  neither on a plain one; structured and plain `openSession` interleaved on
  one model (sticky constraint): the plain one is sent without provider;
  invalid schema at first send → exception, no history entry (Dart replay
  and native), the session is terminal; a stop in session A while B is
  queued ends only A.
  **Mutation check:** delete the provider call → the test fails.
- Every `none` path (LiteRT-LM web, NPU, ONNX mobile/web, built-in Android,
  MediaPipe) refuses before any engine call.
- Built-in: buffered stream, and its cancel.
- llama: `LlamaStructuredOutput` built at session creation; an unrelated
  `LlamaUnsupportedException` is not remapped.

**Real models — the discriminating test.** A schema the model would not
produce unconstrained, e.g.
`{"type":"object","properties":{"code":{"enum":["qzx-7","vlo-3"]}},"required":["code"],"additionalProperties":false}`
with a prompt asking for a poem. Unconstrained control first (must fail the
schema), then constrained (must pass). Plus: `maxOutputTokens: 5` →
`outputLimit`; `stopGeneration` mid-reply → `stopped`; structured and plain
sessions alternating three turns each.

| target | model | where |
|---|---|---|
| LiteRT-LM CPU | Gemma 4 E2B, FunctionGemma 270M | macOS (local), Linux (VM; #551 constraint ABI history), Windows (LNL box), Android (local phone, or DDP via `run_instrumented.sh` / `am instrument`, verdict = `I/flutter` summary line, billed per minute, ask first), iPhone |
| LiteRT-LM GPU | Gemma 4 E2B | macOS Metal, iPhone Metal, Android OpenCL (Adreno, Mali), tokens per second with and without a format: decides the GPU row of §1.7 |
| ONNX | Phi-3.5-mini / Qwen2.5-0.5B | after #704: macOS, Linux, Windows; Android/iOS refusal |
| Built-in AI | Apple FM | macOS 26 (local); Chrome desktop; Windows not available to me; `jsonObject` meaning measured here |
| llama | Qwen2.5-0.5B GGUF | macOS native; web WebGPU (enforce) |

Docs carry only measured rows; the rest is listed as not verified.

---

## 7. Alternatives

### A. Parameter on the four methods, each engine handles it

Engines keep their overrides; core provides `checkResponseFormatArguments` and
the reply guard as helpers.

- Pro: smaller change; llama's `LlamaInferenceChat` and the FFI `createChat`
  override stay as they are.
- Con: "never ignore" depends on every engine using the helpers. An engine
  that adds the parameter and does nothing compiles and ships (the
  `tools`-dropped precedent, `interface.dart:444-452`). Still breaking for
  engines (a missing named parameter is an invalid override), so it does not
  save the break, only the restructuring.

### B. Core owns the entry points (recommended, §2)

- Pro: one place refuses, validates and guards, for every engine including
  out-of-tree ones; later options are `SessionRequest` fields; fits the
  decided `create*` → `open*` move and the Decider's `@nonVirtual` pattern.
- Con: largest 2.x engine break; llama and the FFI engine move their custom
  chat logic behind `buildChat`; more to review in one release. Can be split:
  2.6.0 adds the hook and makes `open*` non-virtual, 3.0.0 removes `create*`.

### C. Per-turn format (`session.getResponse(responseFormat:)`)

Matches ORT-GenAI 0.16+ per-turn guidance and LiteRT-LM's C API shape
(constraint in `optional_args`).

- Con: on LiteRT-LM 0.18.0 the constraint is sticky (§1.1 point 2): a later
  turn without a format silently stays constrained unless every change
  rebuilds the conversation (a full re-prefill). `InferenceChat` would need a
  per-call format. Not for 2.6.0; can be layered on B later where an engine
  supports it.

(The mixin variant was rejected on 2026-10-21.)

---

## 8. Migration notes (2.6.0 MIGRATION.md)

**Apps:**
```dart
final chat = await model.openChat(
  responseFormat: ResponseFormat.jsonSchema({
    'type': 'object',
    'properties': {'city': {'type': 'string'}, 'days': {'type': 'integer'}},
    'required': ['city', 'days'],
  }),
);
await chat.addQueryChunk(
  Message.text(text: 'Plan 3 days in Lisbon. Reply with city and days.', isUser: true),
);
final reply = await chat.generateChatResponse() as TextResponse;
final value = jsonDecode(reply.token) as Map<String, Object?>;
```
Check `model.structuredOutputSupport.refusalFor(format)` first on
multi-engine apps; catch `ResponseFormatUnsupportedException` at session
creation and `IncompleteStructuredOutputException` per reply.

**Engines (out of tree):** stop overriding `createSession` / `openSession` /
`createChat` / `openChat`; implement `openEngineSession(SessionRequest)`;
override `engineStructuredOutputSupport` and report `TurnEnd` only if you
enforce a format; a custom chat type goes through `buildChat`. Core floor
`^2.6.0`.

## 9. Other 2.6.0 items, not designed here

- Decider SPI off the mixin (`OptionScoringModel` members onto
  `InferenceModel` with refusing defaults): separate design; it touches the
  same class, so both should land in one engine break.
- #703, #704, MediaPipe web `openSession`: prerequisites (§5, §1.7).
- Genkit: map `output: {format: 'json', schema}` to `responseFormat` after core.

## 10. Decisions for Sasha

Listed with recommendations in the autopilot queue item; repeated here. The
multi-reviewer pass of 2026-10-26 and its final recommendations are in
[`structured-output-2-6-review.md`](structured-output-2-6-review.md).

1. B (core owns entry points) or A (parameter per engine). Rec: **B**.
2. Deprecate `create*` only when every engine has `openSession` (#703, MediaPipe web). Rec: **yes**.
3. Ship in one 2.6.0 with the Decider SPI move (one engine break). Rec: **yes**.
4. 2.6.0 formats = `jsonSchema` + `jsonObject`, no regex. Rec: **yes**.
5. Tools + format refused everywhere in 2.6.0. Rec: **yes**.
6. Thinking + format refused everywhere in 2.6.0. Rec: **yes**.
7. Core validates the final value for a fixed keyword set and refuses other keywords. Rec: **yes**.
8. Built-in AI `getResponseAsync` with a format = one buffered chunk. Rec: **yes**.
9. A stopped turn is `IncompleteStructuredOutputException` even if the value was complete. Rec: **yes**.
10. Core never adds the schema to the prompt. Rec: **yes**.
11. LiteRT-LM GPU: enforce only after the §6 run passes; NPU refused. Rec: **yes**.

## 11. Independent review

`codex exec` (read-only, gpt-5.6-sol, 2026-10-26) on the first draft (option
A). 14 findings; the ones I verified and folded in:

| # | finding | verified | change |
|---|---|---|---|
| 1 | A cannot hold "never ignore" | yes, `interface.dart:444-452` precedent | recommendation → B |
| 2 | JSON syntax check misses partial enforcement | yes | §4.2 core keyword validator, `NonConforming…` |
| 3 | partial reply not in chat history if the guard throws | yes, `chat.dart:250,336,796` | §3: commit before throw |
| 4 | "stopped" not derivable from the text | yes, `litert_lm_client.dart:2200-2207` | `TurnEnd` reported by engines |
| 5 | llama WebGPU enforces | yes, `engine_capabilities.dart:99-103` | §1.5, §1.7 |
| 6 | "null = full JSON Schema" overclaims | yes, `structured_output.dart:65-75` | `refusalFor(format)` |
| 7 | const `ResponseFormat` keeps a mutable map; equality undefined | yes | deep copy, canonical JSON, `==` |
| 8 | first-send rejection leaves a turn in the virtual replay | yes, `ffi_inference_model.dart:1385-1420` | §4.4 |
| 9 | llama checks only at generation | yes, `llama_inference_session.dart:635` | build `LlamaStructuredOutput` at creation |
| 10 | one exception for several failures | — | three exception types |
| 11 | built-in validator accepts `{}` | yes, `schema_validation_test.dart:40` | §1.4: `jsonObject` refused until measured |
| 12 | `streaming: false` reads inverted | — | `delivery: incremental \| buffered` |
| 13 | source-breaking for engines; replacement API still throws | — | §5 points 2-3 |
| 14 | missing tests | — | §6 extended |
