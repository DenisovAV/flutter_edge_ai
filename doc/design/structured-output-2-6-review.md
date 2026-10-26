# Review of `structured-output-2-6.md` (core 2.6.0, #195)

Date: 2026-10-26. Design reviewed at `e2511433`. Read-only review. No code was
written and nothing ran on a device.

Six independent reviewers saw the design with the recommendations removed from
§10:

- flutter-architect: Dart API, lifecycle, migration
- litert-expert: LiteRT-LM C API and runtime
- android-architect: MediaPipe, ML Kit, ONNX and LiteRT-LM on Android
- swift-architect: Foundation Models, ONNX iOS, Metal
- type-design-analyzer: the proposed types
- `codex exec` (read-only): an outside reviewer

I re-checked every claim counted below against the code, the pub cache, the
native hook cache (`native-v0.18.0-g`) or upstream sources. A claim I could
not re-check myself is marked *(reviewer-reported)*.

---

## 1. Verified factual errors in the design

| # | design § | design says | true | evidence (re-checked) |
|---|---|---|---|---|
| E1 | §1.1, §1.7, decision 11 | whether GPU and NPU apply the mask is "not known" | Both apply it in the v0.18.0 source. **CPU/GPU:** `ProcessLogits` runs before sampling. **GPU** buffers are copied to the host, masked and written back (fp32 and fp16). **NPU:** the logits are masked, then sampled greedily, and MTP is off under a constraint. | LiteRT-LM v0.18.0 `runtime/executor/llm_litert_compiled_model_executor.cc:1373-1388`; `runtime/components/constrained_decoding/constrained_decoder.cc:42-66`; `runtime/executor/llm_litert_npu_compiled_model_executor.cc:879-910`, `:1029-1033` |
| E2 | §1.1 | exports checked on macOS only | Both setters are exported by the android_arm64, ios_arm64 and macos_arm64 `libLiteRtLm` in the hook cache (Linux and Windows not checked) | `nm -gU … \| grep -c set_constraint` = 2 on each |
| E3 | §1.1 | bindings come from `include/c/engine.h` | The inference bindings come from `native/litert_lm/include/engine.h`. `include/c/` holds the embedding headers. Neither has the constraint API, so the conclusion stands. | `flutter_edge_ai_litertlm/ffigen.yaml:6` |
| E4 | §2.2 comment, §7.C | "a per-turn format could not be honoured" on LiteRT-LM | Each send that carries a constraint replaces `constraint_`, so changing the schema per turn works. What cannot be done is clearing it: `kLiteRtLmConstraintTypeNone` sets nothing, so the old constraint stays. | `conversation.cc:397-400`; `c/conversation.cc:118` |
| E5 | §3 thinking row | the constraint masks from the first token; "nothing measured says otherwise" | Upstream wraps the user constraint in `ThinkingBudgetConstraint` whenever a thinking budget ≠ 0 (including -1) reaches the decode config, and suspends the schema until thinking ends. Our client sends a `ThinkingConfig` only when `thinkingTokenBudget` is set; otherwise the budget is 0 and the schema masks from the first token. The refusal stands, but this is its reason. | `runtime/core/tasks.cc:642-656`; `conversation.cc:394` |
| E6 | §4.4 | identify the first-send failure by the native status | The status is `absl::InternalError("Failed to create LLGuidance constraint: …")`. INTERNAL is shared with unrelated failures, and only the message prefix tells this one apart. Native has already pushed the user message into `history_` before `CreateDecodeConfig` fails, so the native conversation is poisoned as well as the Dart replay. | `llg_constraint_provider.cc:155-159`; `conversation.cc:588-598`, `:732-739` |
| E7 | §6 | "invalid schema at first send → … next send on the same session works" | Impossible: the format is fixed per session and recompiled on every send, so every send fails again. A session whose schema was rejected must be terminal. | `conversation.cc:397-400` |
| E8 | §1.3 | ONNX on Android/iOS is refused "until #704" | The 0.17.0 Android AAR is built without guidance too. The AAR build settings pass no `--use_guidance`, and `USE_GUIDANCE` defaults to OFF. #704 only turns the silent ignore into a throw. ONNX Android needs our own ORT-GenAI build. | onnxruntime-genai v0.17.0 `tools/ci_build/github/android/default_aar_build_settings.json`; `cmake/options.cmake:8`; the 0.17.0 AAR's `.so`: 0 llguidance strings *(reviewer-reported)* |
| E9 | §1.4 | `refusalFor` "runs `validateGenerationSchema`" (implying it refuses what it cannot enforce) | The validator checks the constructs it knows and ignores unknown keys. `pattern`, `minimum`, `const`, `minLength` and typos pass. Apple's `SchemaBuilder` reads only `description`, string `enum`, `type`, `properties`, `required`, `items`, `minItems` and `maxItems`. So `{"type":"integer","minimum":1,"maximum":5}` is accepted and not enforced, and core's check would then throw `NonConforming`, which §2.5 calls an engine bug. | `flutter_local_ai-0.3.0/lib/src/models/schema_validation.dart`; `darwin/.../GenerationSchemaBuilder.swift:30-70` |
| E10 | §1.4 | `jsonObject` on Apple is unknown | A property-less object becomes a `DynamicGenerationSchema` with no properties, which can only produce `{}` (inferred from the builder, not run) | `GenerationSchemaBuilder.swift:43-60` |
| E11 | §1.4 | streaming refusal at `flutter_local_ai.dart:199-206` | `lib/src/flutter_local_ai.dart:199-207` | file |
| E12 | §1.5 | native llama: tools + format "is accepted" | Rerouted to `generic` **and** refused (`LlamaUnsupportedException`) when any tool uses a canonical JSON schema | `llamadart-0.15.1/lib/src/core/template/chat_template_engine.dart:193-195`, `:440-452` |
| E13 | §2.2 | `name` "sent where an engine takes one (llama, Windows)" | `flutter_local_ai` takes no name: `getStructuredResponse(schema)` and the Windows service gets `prompt` + `schema_json` | `local_ai_session.dart:150`; `windows/local_ai_session_service.cpp:426` |
| E14 | §2.2 | engines send `schemaJson` with sorted keys | Sorting changes the output: llamadart's GBNF and llguidance emit properties in schema order (`{reasoning, answer}` would become `{answer, reasoning}`). Send the caller's order. Use the canonical form only for `==`/`hashCode`. | `llamadart-0.15.1/lib/src/core/grammar/json_schema_converter.dart:727` (`sortedPropNames` = insertion order) |
| E15 | §2.4 | `SessionRequest.enableVisionModality, enableAudioModality` are `bool` | They are `bool?` today; null = the model's own default (`?? supportImage` in each engine). A non-null field loses vision on `openSession()` | `interface.dart:326,391`; `ffi_inference_model.dart` (`enableVisionModality ?? supportImage`) |
| E16 | §3 | parser gate `chat.dart:302-305`; commit at `chat.dart:250` | Tool-parser gate `:307-310`; `:250` is the declaration of `generateChatResponse`; commits at `:336-339` (sync) and `:804-813` (stream). `sessionCreator` is called at `:125, 353, 834, 1088, 1108`, not only the two rebuilds cited *(call sites reviewer-reported)* | `chat.dart` |
| E17 | §5.3 | precedent labelled "Breaking for engines" | No such label. The CHANGELOG precedent is "**Breaking for `implements InferenceModel`:** add `isClosed`", which shows that `implements InferenceModel` is a pattern the project supports | `flutter_edge_ai/CHANGELOG.md:55` |
| E18 | §2.1, §7.B | B holds the rule "for every engine including out-of-tree ones"; it "fits the Decider's `@nonVirtual` pattern" | `@nonVirtual` and `@protected` are analyzer warnings, not language rules. A class that `implements InferenceModel` (a plain `abstract class`) declares its own `openSession` and skips core with no diagnostic; four core tests do exactly that. `Decider` is enforced by `abstract base class`. `InferenceModel.createDecider` is only `@nonVirtual`, and its own doc says `implements` must declare it. | `interface.dart:255`, `:609-612`; `decision/decider.dart:44,81,124`; meta 1.19.0 `nonVirtual` doc *(meta text reviewer-reported)* |
| E19 | §1.6 | MediaPipe: "no constraint option in the bound API" | True of our plugin, but the 0.10.33 AAR has `LlmInferenceSessionOptions.Builder.setConstraintHandle(long)`, and the iOS C header has an opaque `Constraint*`. Nothing public creates one, so "refuse" stands. The doc should cite this so no one tries to wire the handle. | *(reviewer-reported: `javap` on the AAR; `llm_inference_engine.h:44,240-241`)* |
| E20 | §6 | Android on DDP under `flutter test … -d` | DDP runs app + androidTest APKs under `am instrument` (`run_instrumented.sh`). The verdict is the `I/flutter` summary line. DDP bills per minute. | AGENTS.md Rule 6 |

I checked these and they hold: the C API enum values and signatures; the silent
drop without a provider (`conversation.cc:397`); stickiness (`constraint_`
is only ever assigned); schema and tool grammar excluding each other (the
`else` branch, and the tool constraint is built only while `constraint_ ==
nullptr`); the web typings; `interface.dart:444-452`;
`ffi_inference_model.dart:1385-1420`; `litert_lm_client.dart:2200-2207`;
`llama_inference_session.dart:635`; `agent_session.dart:183`;
`flutter_edge_ai_model.dart:267`; the iOS/macOS 26 gate in
`LocalAiSessionService.swift:330-334`; ML Kit `supportsStructuredOutput =
false` (`LocalAiSessionService.kt:239`); llama WebGPU.

## 2. Verified design flaws and missing cases

| # | flaw | scenario | evidence |
|---|---|---|---|
| D1 | **B as drawn is not a guarantee** (E18) | An out-of-tree engine that `implements InferenceModel` never reaches core's checks. An app holding the engine's model can call `openEngineSession` with only a warning. | `interface.dart:255` |
| D2 | **The guard lives in a session wrapper, but chats bypass it** | `LlamaInferenceChat._llamaSession => session as LlamaInferenceSession` would throw a `TypeError` on a wrapped session. It also overrides `generateChatResponse`/`…Async` and calls the llama-only `getResponses(tokenBuffer:)`, so it never touches a wrapper. `buildChat` is an open bypass. | `llama_inference_chat.dart:32`, `:51-91` |
| D3 | **Commit-before-throw contradicts the wrapper placement** | If the wrapped `getResponse()` throws at `chat.dart:252`, or the stream errors inside `await for`, the history commit (`:336`, `:804`) and the token accounting are skipped. The chat must run the guard itself, or catch and commit from `partialText`. | `chat.dart` |
| D4 | **`lastTurnEnd` is racy and goes stale** | ONNX has no per-session busy guard. Two queued turns can read each other's end, and an engine path that forgets to set it leaves the previous `endOfSequence`, so a truncation is reported as `NonConforming`. It needs a per-turn result (`Future<TurnEnd>` with the stream, or a final event). ONNX's worker sends `stopped` in `GenerateDone`, but the client does not surface it. A natural EOS at exactly `maxOutputTokens` cannot be told apart by counting. | `gen_ai_worker.dart:188-192`; `interface.dart:728` (`lastRawResponse`, same pattern) |
| D5 | **`legacySingleton` puts two lifecycles in the SPI** | On FFI, `createSession` is a `RecoveringConversationHandle` with close-previous and single-flight (two concurrent calls with different formats get the first caller's session). `openSession` is the virtual handle. `model.session` stays an engine getter, so it returns the unguarded session. | `ffi_inference_model.dart:225-323`, `:370-414` |
| D6 | **FFI `open*` loses the #682 native rewind** | The virtual handle rebuilds and re-prefills after every stop. A structured session (or a migration from `create*`) pays a full re-prefill after each stop, which slows barge-in and voice apps. | `litert_lm_client.dart:2012-2022` (`_virtualConvStopped` → rebuild) vs `ffi_inference_model.dart:290` |
| D7 | **Genkit leaks on a rename-only migration** | Genkit calls `createChat` per request and never closes it. With `openChat` that leaks one session per request until `maxConcurrentSessions` (`StateError` on FFI). | `genkit_flutter_edge_ai/lib/src/flutter_edge_ai_model.dart:267` (no `close` in the file) |
| D8 | **Per-engine chat defaults are not in the SPI** | `modelType`/`supportImage`/`systemInstruction` defaults differ (FFI and built-in use the model's own; the base uses `ModelType.gemmaIt`); llama sessions also take `modelType`/`toolChoice`. If core owns `openChat`, a Qwen model gets the Gemma parsers. *(reviewer-reported line numbers)* | `interface.dart:466`; `builtin_ai_model.dart:376` |
| D9 | **Every engine must refuse every keyword it does not enforce** | E9: built-in AI. An engine's `refusalFor` must be an allow-list per node, composed by core after its own check. Otherwise a valid reply fails the guard as an "engine bug". | E9 |
| D10 | **The schema dialect is unspecified** | `required` naming a missing property, `minimum > maximum`, boolean schemas, `$defs`/`$schema`, integer semantics, `minLength` in code points or UTF-16, deep `enum` equality, depth limits. *(codex)* | — |
| D11 | **Cancelling a stream ≠ `stopGeneration`** | Cancelling a subscription removes the listener, so the guard's error "after the last chunk" cannot be seen. History and cleanup on cancel need defining. On Apple, a stop clears `activeTurn` while `respond` may still be unwinding; the next turn could hit `concurrentRequests` *(reviewer-reported)*. A value that finished just before the cancel is discarded by `Task.checkCancellation()`. | `LocalAiSessionService.swift:732` |
| D12 | **The schema reaches the prompt anyway on Apple** | Foundation Models defaults `includeSchemaInPrompt: true` and flutter_local_ai never overrides it. Decision 10 holds for core, but the docs must say so: it uses context on a 4096-token model, and prompts differ across engines. | FoundationModels swiftinterface `:2056-2057` (Xcode SDK); no `includeSchemaInPrompt` in flutter_local_ai's Swift |
| D13 | **The LiteRT-LM provider costs a tokenizer index per conversation create** | `LlgConstraintProvider::Create` builds an llguidance tokenizer over the vocabulary (262k for Gemma 4) at each conversation create and clone. The virtual handle recreates on every session switch. Measure create latency and RSS, and tokens per second with and without a format on GPU (host copy per token). *(reviewer-reported lines `conversation.cc:433-441`, `:908-915`)* | — |
| D14 | **Every LiteRT-LM rebuild path must set the provider again** | `RecoveringConversationHandle`'s rebuild from text (NPU, no §16 export, failed rewind), the overflow and single-turn rebuilds, and the virtual switch. Add a mutation test: a structured session through a rewind fallback is still constrained. | `ffi_inference_model.dart:278-290` |
| D15 | **`jsonObject` is a separate variant with a different answer** | On built-in AI, `jsonSchema({'type':'object'})` passes the validator while `jsonObject()` is refused, so the same meaning gets two answers. | design §1.4/§1.7 |
| D16 | **`sealed ResponseFormat` breaks app switches when a variant is added in a minor** | The design says this is deliberate for engines, but engines receive only the kinds they declared, so `sealed` protects nothing there. | design §2.2 |
| D17 | **`StructuredOutputSupport` flags and `refusalFor` can disagree** | A `final class` with bools cannot carry engine keyword logic. Core should build `refusalFor` in this order: the kind check from the flags, core's keyword check, then an engine callback. `refusalFor` should return a refusal with `schemaPath`, not a `String`. | design §2.3 |

## 3. Per decision

The original recommendation was "yes / B" on all 11.

### 1. B (core owns the entry points) vs A
- **Verdicts:**
  - Modify: flutter-architect, codex, type-design (conditional).
  - Agree: swift.
  - Out of area, leaning agree: litert, android.
- **Verified issues:** D1, D2, D3, D5, D8, E18.
- **Final: B, with four changes:**
  - **(a) The guard runs inside core's `InferenceChat`, and on a core-owned session object.**
    - `InferenceChat.generateChatResponse`/`…Async` become `@nonVirtual`.
    - A custom chat (llama) supplies per-turn protected hooks, not a whole chat type: no `buildChat`.
  - **(b) Engines return a per-turn result,** for example `EngineTurn { Stream<String> chunks; Future<TurnEnd> end; }`. This replaces `lastTurnEnd`. Core throws `StateError` when a structured turn ends without one.
  - **(c) `responseFormat` goes on `openSession`/`openChat` only, not on the deprecated `create*`.** This drops `legacySingleton` from the SPI, and with it D5. ONNX structured output already waits for `openSession` (#703), so it loses nothing.
  - **(d) In 2.6.0 `InferenceModel` stays a plain abstract class.** `implements` is documented as opting out of core's guarantees, as `createDecider` already documents (`interface.dart:609-612`). 3.0.0 makes it `abstract base class` along with the removals, because `implements InferenceModel` is a supported pattern today (E17).
- **Changed vs original:** yes, the shape. B stays, but (a)-(d) replace §2.3-§2.4.

### 2. Deprecate `create*` only when every engine has `openSession`
- **Verdicts:** agree (flutter-architect, codex, swift); android out of area.
- **Final: yes, with three more blockers:**
  - D6: FFI `open*` must keep the #682 native rewind, or the regression is measured and accepted.
  - D7: the genkit migration closes its chats.
  - D8: built-in AI's `openChat` defaults must equal its `createChat` defaults.
- **Changed:** blockers added.

### 3. One engine break in 2.6.0 with the Decider SPI move
- **Verdicts:** agree (flutter-architect, android/swift lean); codex modify (separate reviewed slices).
- **Final: yes.** It is one release built from separate PRs (Sasha's "shared release = separate PRs" rule): the Decider SPI, the session SPI and each engine.
- **Changed:** no.

### 4. Formats: `jsonSchema` + `jsonObject`, no regex
- **Verdicts:**
  - Agree: litert, android, swift, flutter-architect, codex.
  - Modify: type-design (`jsonObject` as sugar).
- **Verified:** D15, D16, E10.
- **Final: `jsonSchema` only as a type.**
  - `ResponseFormat.jsonObject()` stays as a factory that returns the schema `{"type":"object"}`.
  - `ResponseFormat` is not `sealed`: an abstract class with a private constructor, so apps cannot subclass it and a later `regex` is not breaking.
  - Built-in AI refuses a property-less object schema on Apple (E10: it means `{}`); confirm with one run.
  - No regex in 2.6.0 (LiteRT-LM and ORT-GenAI could add it later).
- **Changed:** the shape (no separate variant, not sealed).

### 5. Tools + format refused everywhere
- **Verdicts:** agree from all six.
- **Final: yes.** Core throws `ArgumentError` before the engine is called.
- **Changed:** no. Correct E12 in §1.5.

### 6. Thinking + format refused everywhere
- **Verdicts:** agree (4); modify the reason (litert, swift).
- **Final: yes.**
  - Reason corrected per E5.
  - Also refuse a format on a LiteRT-LM engine created with `thinkingTokenBudget`, the one path where upstream's thinking wrapper is active and unmeasured.
- **Changed:** reason only, plus that extra refusal.

### 7. Core validates the final value for a fixed keyword set and refuses other keywords
- **Verdicts:**
  - Agree: litert, android, flutter-architect, type-design (conditional).
  - Modify: codex (dialect), swift (each engine must refuse what it does not enforce).
- **Verified:** D9, D10, D17, E9.
- **Final: yes, plus three requirements:**
  - **(a)** A written dialect with well-formedness checks at session creation (D10 list).
  - **(b)** Each engine declares an allow-list of the keywords it enforces, and core composes: kind → core keywords → engine allow-list.
  - **(c)** It also turns most of llguidance's first-send INTERNAL errors (E6) into refusals at creation.
- **Changed:** requirements added.

### 8. Built-in AI streaming with a format = one buffered chunk
- **Verdicts:** agree (flutter-architect, type-design, swift); codex modify (cancel semantics).
- **Final: yes,** with D11 settled:
  - the adapter maps "I asked to stop" to `TurnEnd.stopped`;
  - a cancelled subscription is defined (no error is delivered; history follows `stopGeneration`);
  - a stop → next-turn test.
  - Apple's `streamResponse(schema:)` yields snapshots, not text prefixes, so `incremental` is not planned.
- **Changed:** no, only made more specific.

### 9. A stopped turn is `IncompleteStructuredOutputException` even if the value was complete
- **Verdicts:** agree (flutter-architect, type-design, swift); codex disagrees (return success if it validates).
- **Final: yes, unchanged.**
  - One answer across engines: Apple discards a value completed at a cancel (`Task.checkCancellation()`), so a "success if valid" rule would differ by engine.
  - An engine cannot always tell a stop from an end that happened just before it.
  - `partialText` lets the app parse it.
- **Changed:** no.

### 10. Core never inserts the schema into the prompt
- **Verdicts:** agree from all.
- **Final: yes.** Document that Apple Foundation Models (`includeSchemaInPrompt: true` by default) and ML Kit's typed API put it in the prompt themselves (D12).
- **Changed:** docs only.

### 11. LiteRT-LM GPU enforced after a run; NPU refused
- **Verdicts:**
  - Modify: litert, android, swift (the source masks on GPU and NPU).
  - Agree: codex.
- **Verified:** E1, D13.
- **Final: one rule for both: each backend is enforced only after its own device run passes.**
  - The run is the discriminating enum test plus tokens per second with and without a format: macOS Metal, iPhone Metal, Android OpenCL on Adreno and Mali.
  - NPU stays refused in 2.6.0 **because it has not been run**, not because the wiring is unknown. A Qualcomm run needs DDP (billed per minute, Sasha's call).
  - Document that NPU decodes greedily under a format.
- **Changed:** the reason, and GPU/NPU now follow the same rule.

## 4. Doc fixes

The fixes I applied to `structured-output-2-6.md` in the same commit (factual
only): E1 (GPU/NPU masking known), E2, E3, E4, E5, E6 (status, native
history), E7, E8, E11, E12, E13, E14 (send insertion order), E15, E16 (line
numbers), E17, E20. §10 points to this file for the final decisions.

Not applied: the API changes in §3 (decisions 1, 4, 7, 8). They change the
proposed public API, so they wait for Sasha's approval (Rule 1b), as do the
design sections D1-D17.
