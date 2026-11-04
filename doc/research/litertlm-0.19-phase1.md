# LiteRT-LM 0.19.0 migration, phase 1: checks before the Dart rewrite

2026-11-01, branch `native/litertlm-0.19`. Builds of LiteRT-LM v0.19.0
(`771b06e1`, LiteRT `dcb657e8`) with our patches, and C-level probes against
the new C API 1.0 (`packages/flutter_edge_ai_litertlm/native/litert_lm/probes/litertlm_probe.c`).
Nothing is published: CI runs are artifact-only, no tag, no release.

## Builds

| Target | Where | Result | Notes |
|---|---|---|---|
| Linux x86_64 | CI run 41277710260 (no §13), 41281104298 (§13) | ✅ both | `libLiteRtLm.so` now NEEDs `libwebgpu_dawn.so` (the WebGPU TopK sampler is linked in); Dawn already ships on Linux. |
| Linux arm64 | same | ✅ both | §13 unit test passes in the §13 run. |
| Linux arm64 Qualcomm dispatch | same | ✅ | Exports `LiteRtDispatchQueryInterface` (LiteRT's versioned dispatch ABI); the build check now follows the pin. |
| Windows x86_64 (+ Intel NPU dispatch) | CI runs 41277710260, 41281104298 | ✅ both | No separate TopK WebGPU sampler DLL any more; the sampler is compiled into `LiteRtLm.dll` (phase B). |
| macOS arm64 | local | ✅ | Built with `--//runtime/executor:gpu_accelerator=metal` (see "Static GPU accelerator"). `minos` 11.0 / 14.0; the real framework id fits the Metal accelerator's header slack. |
| iOS arm64 + simulator | local | ✅ | Static ML Drift Metal accelerator, no Dawn. |
| Android arm64 | local | ✅ with §19 | Google Tensor and Qualcomm dispatches built from the pin, both export `LiteRtDispatchQueryInterface`; all PT_LOAD 16 KB aligned; DT_NEEDED closure passes. |

## Patches

| Patch | v0.19.0 | Evidence |
|---|---|---|
| §1 shared lib, dynamic-list, Windows `.def` | keep (applies) | all 71 `.def` names exist in the 0.19 headers |
| §2 / §3 setters | keep, now `LiteRtLmStatusCode` | the sed anchor (`void …set_activation_data_type`) silently matched nothing on 0.19; the section now fails when the impl is missing |
| §10b gpu_registry (Apple) | keep, re-created | Bazel refused the old hunk (it needs zero fuzz); macOS gained the bare `LiteRtMetalAccelerator` name. Possibly unnecessary now on Apple: the accelerator is linked in statically (below) |
| §11 Qualcomm options on Linux | keep, re-created | upstream added `SetHtpFileReadMemoryBudgetMB(16)` inside the Android-only block |
| §12 Linux constraint bridge | keep, **constants unchanged** | new providers (x86_64 `fc4e17a9…`, arm64 `4685001b…`) disassembled: `Start` returns in rax/x0, `StatusOr` through the hidden slot with rep 1, mask `{vtable, vocab@0x08, begin@0x10, size@0x18, cap@0x20}`; Gemma 4 tool calls pass on Linux x86_64 and arm64 |
| §13 external weights by path | **keep**, re-created | without it EmbeddingGemma 2 fails engine create on Linux x86_64 and arm64 (`embedding_engine_impl.cc:585`) and crashes on Windows (exit 139); with it Linux and Windows pass (dim 768, norm 1.0). Rewrites a model's own `tflite_weights` group only: v0.19 bundles that reference another model's weights (`tflite_weights:<type>`, 90aac9c) still fail on Linux/Windows |
| §14 embedding response lengths | keep, 1.0 shape | `input_length` 14 read through the new getters on macOS and Linux |
| §15 Windows no-fd loading | keep (applies) | #4023 closed upstream without a code change |
| §16 rewind_cancelled_turn | keep, re-created | upstream `Conversation::WaitUntilDone` used; checkpoint saved synchronously right before the send's prefill |
| §17 SentencePiece NUL piece | **keep**, re-created as a second patch on top of upstream's | v0.19.0 carries its own `third_party/sentencepiece/sentencepiece.patch`, but it accepts only the one-byte piece `"\0"` (NORMAL, BPE, no byte_fallback). That covers FastVLM-0.5B and the pre-e6687177 Qwen3-0.6B (only id 188 = `"\0"`), not Phi-4-mini-instruct q8, whose vocabulary also holds the merge `"\0\0"` (id 156344): "piece must not include null character" on our 0.19 build (XNNPACK thread). Tokenizer sections read by HTTP range: Phi-4-mini 2 NUL pieces, Qwen3 old 1, FastVLM 1; Qwen3 new, Qwen3 dynamic, Phi-4-mini-reasoning and LFM2.5 use HF_Tokenizer_Zlib. `patches/sentencepiece_nul_piece_on_upstream.patch` (-p0, applied after upstream's) restores our rule; `sentencepiece_nul_piece_test` gains the `"\0\0"` case |
| §18 = upstream PR #4197 (new) | keep until upstream merges | makes §16 exact on Gemma 4 E2B (below) |
| §19 Android OpenCL-only static accelerator (new) | keep | without it `libLiteRtLm.so` NEEDs `libwebgpu_dawn.so` on Android (`default_static_gpu_accelerator` → `ml_drift_gpu_accelerator` → `delegate_webgpu` → Dawn) |
| OpenVINO 2026.4.1 backport | **drop** | in the LiteRT pin |
| Google Tensor dispatch BUILD | keep (applies, zero fuzz) | |
| WebGPU accelerator override (5f973f57) | **drop** | the tag's own prebuilt is newer and its LiteRT pin has #11120 |

## Probes (C API 1.0)

CPU on macOS (M5 Pro), GitHub runners (Linux x86_64, Linux arm64, Windows
x86_64) and an Android arm64 emulator; GPU on macOS (Metal).

| Check | Result | Numbers / platforms | What it means for the Dart work |
|---|---|---|---|
| Several live conversations on one engine (#966) | ✅ | Gemma 4 E2B, 3 conversations interleaved, each kept its history: macOS CPU + Metal, Linux x86_64/arm64, Windows | Open sessions can be one conversation each on a shared engine; no one-conversation limit at the C API |
| Constrained decoding (LLGuidance, JSON schema with enum, regex) | ✅ | valid output everywhere tested. Gemma 4 E2B decode tok/s, none / schema / regex: Metal 59.0 / 36.7 / 73.1; Linux x86_64 CPU 30.5 / 30.9 / 30.9; Windows CPU 18.6 / 20.3 / 20.2 | Typed responses can sit on `conversation_config_set_constraint_provider` + `optional_args_set_constraint`; JSON schema costs ~38 % of decode speed on Metal, nothing on CPU. Adreno, Linux/Windows GPU not run yet |
| §16 rewind exact on Gemma 4 E2B with §18 (#3947) | ✅ | bit-identical (was −1.152 vs −0.792 on 0.18): macOS CPU + Metal, Linux x86_64/arm64, Windows CPU; FunctionGemma too, Android emulator | §16 + §18 restores stopped turns exactly |
| #3561 scoring | ✅ fixed | the self-check pair now differs (FunctionGemma 11.69–12.02, Gemma 4 0.40 CPU / 1.89 Metal) → mode `plain`; a target after a rewind is bit-identical to one alone, CPU and Metal, 8/8 repeats | `once` and `_reprefillFor` can go; keep the self-check; re-fit nothing, but re-run the golden packs (litetune fitted under `once`) |
| MTP / speculative decoding (Gemma 4 E2B has `tf_lite_mtp_drafter`) | ⚠️ no gain | decode tok/s off / on / adaptive / default: Metal 46.1 / 41.0 / 39.4 / 34.0; Linux x86_64 CPU 30.9 / 15.4 / 24.2 / 30.6; Linux arm64 28.6 / 21.8 / 26.8 / 28.4; Windows 19.5 / 13.5 / 17.4 / 19.4. On Metal, `on`/`adaptive` change the greedy text; on CPU the text is unchanged | Do not enable it by default; default behaves as off. Adreno not run yet |
| Tool calls | ✅ (CPU, Metal) | Gemma 4 E2B: macOS CPU + Metal, Linux x86_64 and arm64 (§12 bridge, no abort), Windows. FunctionGemma answers in text instead of calling on arm64 (Linux, Android emulator) — a model decision, no failure | NPU (Qualcomm, Tensor, Intel) not run yet |
| EmbeddingGemma 2 | ✅ with §13 | macOS 0.16 s/query, Linux x86_64 0.16 s, arm64 0.07 s, Windows 0.06 s; dim 768, norm 1.0 | §13 stays |
| Long prompt past one prefill chunk | ✅ (CPU, Metal) | Gemma 4 E2B answers the fact at the end: Metal, Linux x86_64/arm64, Windows | #3508 (Gemma 3 on the NPU) not run yet |
| Greedy determinism | ❌ **regression on macOS CPU** | same prompt, two conversations, one engine: 0.18 PASS, 0.19 FAIL (FunctionGemma and Gemma 4, diverges at char 18–205) with the default thread count and with 4 or 6 threads; PASS with `num_threads` 1; Metal PASS; Linux x86_64/arm64 and Windows runners PASS; Android emulator PASS | Our "greedy run1 == run2" assertions will flake on Apple Silicon CPU. Not explained; an XNNPack/KleidiAI change in the LiteRT pin is a guess, not measured |

## Findings that change the plan

1. **Static GPU accelerator and samplers.** From v0.19.0,
   `runtime/executor:default_static_gpu_accelerator` and
   `default_static_gpu_samplers` are linked into libLiteRtLm on Apple and
   Android (they were empty in 0.18 for us). macOS defaults to ML Drift WebGPU
   (needs Dawn); we build with `gpu_accelerator=metal`. On Apple the
   separately shipped `LiteRtLmMetalAccelerator` framework is then probably
   unnecessary — the static one registers first — which would remove the
   SwiftPM companion and maybe §10b. On Android §19 keeps it OpenCL-only;
   `libLiteRtOpenClAccelerator.so` and `libLiteRtTopKOpenClSampler.so` are
   probably unnecessary too. Each needs a device run (Mali and Adreno) before
   anything is dropped.
2. **MediaTek NPU breaks on v0.19.0.** LiteRT `dcb657e8` loads only
   `LiteRtDispatchQueryInterface`; Google's `litert-npu-runtime-mediatek` AAR
   (2.3.0 and the newer 2.3.2) exports only `LiteRtDispatchGetApi`, which the
   loader refuses. We cannot build that dispatch (NeuroPilot SDK). Until Google
   ships an AAR on the new ABI, MediaTek NPU is lost with 0.19.
3. **The TopK GPU sampler is compiled into libLiteRtLm on Linux and Windows** (no separate prebuilt any more), and it crashes the first GPU decode there (phase B).
4. **macOS CPU greedy is nondeterministic** (above). Cause: XNNPACK's KleidiAI
   pf32 SME2 f32 GEMM on SME2 CPUs (Apple M4/M5) gives thread-count-dependent
   results (google/XNNPACK#11789). §21 (`patches/xnnpack_pf32_sme2_apple.patch`,
   by the XNNPACK thread) skips those SME2 branches on macOS and iOS; with it
   the 11-model macOS matrix is deterministic and 1 = 4 = 12 threads.
5. **LFM2.5-230M int8: sessions differ even with one thread, on every build**
   (reported by the XNNPACK thread, `research/macos-cpu-nondeterminism-0.19`;
   not measured here). It looks like state carried from one session to the
   next rather than thread scheduling. Not explained.
6. **§17 is still needed** (Phi-4-mini, see Patches).

## Phase B: devices (2026-11-01)

Same harness and bundles: Android arm64 (local §19 build) through adb on DDP
phones, Linux x86_64 on the GCE T4 VM and Windows x86_64 on the Intel boxes
(both from CI run 41281104298, with §13). Galaxy S25 (SM8750, Adreno 830,
Qualcomm NPU), Pixel 11 (Tensor G6), Galaxy Tab S10+ (MT6989), Tesla T4,
Panther Lake (Arc B390 + NPU), Lunar Lake (Arc 140V + NPU).

| Check | Result | Numbers / platforms | What it means for the Dart work |
|---|---|---|---|
| Linux and Windows GPU, conversation API | ❌ **crash at the first decode** | T4: SIGSEGV, backtrace `LlmLiteRtCompiledModelExecutorBase::SampleLogits` → `TopKWebGpuSampler::SampleToIdAndScoreBuffer` → `ml_drift::webgpu::InferenceContext::Execute` → `absl::StatusRep::Clone`. PTL and LNL: `0xC0000409` in `LiteRtLm.dll` at the same offset in every run; `LiteRtLm.dll` carries `TopKWebGpuSampler` too. Session-API checks (rewind, scoring: no sampling) pass on all three GPUs. Gemma 4 12B (#4083) could not be checked: it crashes the same way | v0.19 compiles the TopK GPU samplers from source and links them into libLiteRtLm (upstream 47d7ba6, 7ea259d, 43b79e8); on Linux/Windows our libstdc++/MSVC build of that code then runs against Google's prebuilt WebGPU accelerator. Windows stack not taken, so the Windows cause is the same signature, not a proven one. Blocks the migration on desktop GPU until fixed (§20 below) |
| Several live conversations (#966) on the NPU | ❌ **shared state** | Qualcomm SM8750, Tensor G6, Intel PTL and LNL: all three conversations answer the last one's fact ("Chen"); CPU, Adreno and Metal keep 3/3 | On the NPU an open session cannot be one conversation of several on a shared engine: one live conversation per NPU engine, or rebuild. The NPU executor keeps one KV cache |
| Constrained decoding on devices | ✅ | Gemma 4 E2B decode tok/s, none / schema / regex: Adreno 830 GPU 30.8 / 41.1 / 38.1; Qualcomm NPU 43.9 / 41.1 / 43.0; Intel PTL NPU 61.0 / 52.8 / 38.3; LNL NPU 57.0 / 52.7 / 39.6; T4 not measured (crash above). Tensor G6: valid output, numbers not published (Tensor SDK terms) | Typed responses work on every backend that decodes; JSON schema costs nothing on Adreno, ~5-15 % on the Intel NPU |
| Tool calls on the NPU | ✅ | Gemma 4 E2B on Qualcomm SM8750, Tensor G6, Intel PTL, Intel LNL: `get_weather(city: Paris)`. FunctionGemma on Adreno answers in text (model decision, as on the arm64 CPU) | |
| §16 + §18 rewind | ✅ GPU / ⛔ NPU | bit-identical on Adreno (FunctionGemma), T4, Arc B390, Arc 140V (Gemma 4 E2B). The NPU refuses the checkpoint rewind (`SetCurrentStep only supports rolling back one token`, PTL) | Unchanged: on the NPU the Dart side keeps rebuilding from text |
| #3561 scoring | ✅ plain | pair differs on Adreno, T4 and Arc B390 (2.56) → `plain`; a target after a rewind bit-identical | Same as CPU/Metal |
| MTP | ⚠️ no gain | Adreno 830, tok/s off / on / adaptive / default: 38.4 / 33.5 / 41.8 / 43.4; `on` and `adaptive` change the greedy text, `default` = off | Keep it off |
| Greedy determinism | ✅ NPU, Adreno | Qualcomm, Tensor, Intel PTL/LNL NPU, Adreno: identical | The macOS CPU regression stays the only one |
| Long prompt past one prefill chunk | ✅ Gemma 4 / ❌ Gemma 3 (#3508) | Gemma 4 E2B answers the fact at the end on Qualcomm, Tensor, Intel PTL and LNL NPUs. Gemma 3 1B `…_ekv1280_sm8750` on the Qualcomm NPU (max_num_tokens 1280) answers something else: #3508 is **not** fixed in 0.19 | Keep the Gemma 3 NPU long-prompt caveat |
| MediaTek NPU | ❌ refused | Tab S10+ (MT6989): `Could not load symbol LiteRtDispatchQueryInterface: undefined symbol: LiteRtDispatchQueryInterface` → `No usable Dispatch runtime found` with Google's AAR 2.3.0 dispatch | Confirms finding 2 on a device |

## Not run

- Web: `@litert-lm/core` 0.19.0 (JSPI/Asyncify), the page lock with EG2. Needs
  a web export and a browser with WebGPU; not done in this phase.
- Mali GPU (no Mali phone in this round), iOS device.
- Windows GPU constrained/MTP/tool calls and Gemma 4 12B (#4083): blocked by
  the GPU sampler crash.

## §20: no fused GPU sampler on Linux and Windows (built, re-checked)

`patches/desktop_no_static_gpu_sampler.patch` leaves
`runtime/components:default_static_gpu_samplers` empty when
`litert_runtime_link_mode=dynamic`, and no sampler library ships; CI fails a
build whose libLiteRtLm still carries the sampler's RTTI name. Build run
41300996155 (Linux libLiteRtLm also no longer NEEDs `libwebgpu_dawn.so`).
LiteRT-LM logs "GPU sampler unavailable. Falling back to CPU sampling" and
samples on the CPU; the logits stay on the GPU.

Re-check 2026-11-02, Gemma 4 E2B on the GPU, conversation API (the path that
crashed before):

| Check | Tesla T4 (Linux) | Arc B390 (Windows, Panther Lake) |
|---|---|---|
| tools | PASS | PASS |
| multiconv (3 conversations) | PASS 3/3 | PASS 3/3 |
| constrained (none / schema / regex tok/s) | 15.5 / 72.5 / 73.0, schema and regex PASS | 61.5 / 55.2 / 49.6, PASS |
| determinism | PASS | PASS |
| long prompt | PASS ("PELICAN") | PASS |
| MTP off / on (tok/s) | 70.3 / 7.1, `on` changes the text | 60.4 / 18.2, `on` changes the text |
| §16 + §18 rewind | exact | exact |
| #4083 Gemma 4 12B | — | long prompt PASS, determinism PASS (create 23.5 s cold, 8.3 s warm) |

The T4 unconstrained run (15.5 tok/s, 4.85 s for 17 tokens) is slow against
the same model's 70.3 tok/s in mtp-off; it was measured once and is not
explained. Arc 140V (Lunar Lake) was not re-run.


## §23: the turn-end record and a full window (macOS, 2026-11-04)

`patches/conversation_turn_end_record.patch`, probe commands `turnend` and
`prefillroom`. Gemma 4 E2B with a 1024-token window, FunctionGemma 270M with
256 (`turnend`) or 1024 (`prefillroom`); macOS CPU and Metal.

| Check | Result |
|---|---|
| `turnend`: fresh, stop token, max_output_tokens, decode fills the window, input longer than the window, input that does not fit what is left | PASS on all four (FunctionGemma CPU/Metal, Gemma 4 CPU/Metal). FunctionGemma on Metal ends its reply before the window fills: reported, not checked |
| `prefillroom`: a short message (17 positions with the reply) sent until refused | Gemma 4 refused at **125** positions left, CPU and Metal, two Metal runs identical; FunctionGemma on Metal refused at **249** |
| After that refusal | turn end `context_full` (RESOURCE_EXHAUSTED), the rewind restores the count (899), the same send is refused the same way |
| Upstream behaviour (library without the two edits below) | `FAILED_PRECONDITION`, turn end `failed`, the rewind refused, the next send `INTERNAL: Task failed with state: 7` |

What the refusal is: `GetOptimizedPrefillWorkGroups` erases every prefill
signature longer than `GetNumEntries() - current_step` and, when none is left,
refuses with "Chosen prefill work group size exceeds available state entries
(N)". So it is fixed by the remaining room and the bundle's smallest prefill
signature (Gemma 4 E2B: 128, FunctionGemma: 256), not by timing or the GPU:
the window has room for decode steps but not for any new input. §23 now
reports both refusals of that function as RESOURCE_EXHAUSTED, so the turn
reads as `context_full` from the status alone, without §23 having to guess
the signature sizes. Upstream's unit test
`GetOptimizedPrefillWorkGroups_MaxPrefillSequenceLengthExceededError` is
changed with it.

The rewind first failed with `INTERNAL: Prefill turn prefill:15 already
started`: `Tasks::Prefill` starts a `BenchmarkInfo` prefill turn before
`executor.Prefill` and ends it only on success, so a failed prefill leaves the
start mark and every later prefill of the session is refused. The Dart client
always calls `enable_benchmark`. `Decode` has the same shape (any early return
between `TimeDecodeTurnStart` and `TimeDecodeTurnEnd`). §23 forgets an unended
turn's start on every exit from both functions
(`BenchmarkInfo::AbandonPrefillTurn` / `AbandonDecodeTurn`); upstream's test
that a double start is an error stays as it is.

For the Dart work: a `context_full` after a short input means the window has
no room for a prefill left; the next turn needs a new conversation (or a
smaller history), not a retry.

### Upstream issue draft (not posted)

> **Prefill of an input that fits the context window fails with
> FAILED_PRECONDITION when the remaining room is smaller than the smallest
> prefill signature, and the session stays failed**
>
> LiteRT-LM v0.19.0 (`771b06e1`), macOS arm64, CPU and GPU (Metal), C API.
> Gemma 4 E2B `.litertlm`, `max_num_tokens` 1024, one conversation.
>
> 1. Send a long user message, then short ones ("Reply with the single word
>    OK.", 17 positions with the reply) until the conversation holds 899
>    tokens (`litert_lm_conversation_get_token_count`).
> 2. The next short message fails:
>    `FAILED_PRECONDITION: Chosen prefill work group size exceeds available state entries (125).`
> 3. Every later send on that conversation fails with
>    `INTERNAL: Task failed with state: 7`.
>
> The input fits: `Tasks::Prefill`'s own check (`current_step + num_tokens >=
> max_num_tokens`) lets it through. `GetOptimizedPrefillWorkGroups`
> (`litert_compiled_model_executor_utils.cc`) then erases every prefill
> signature longer than `state_->GetNumEntries() - current_step`, and Gemma 4
> E2B's smallest is 128. The result is the same for every run with the same
> history, CPU and Metal; FunctionGemma 270M (smallest signature 256) is
> refused with 249 positions left of 1024, so a quarter of its window can
> never take new input.
>
> Expected, either:
> - the input is prefilled anyway (a smaller signature, or the decode
>   signature one token at a time, for the tail of the window); or
> - the refusal says RESOURCE_EXHAUSTED, as the over-long input check in
>   `Tasks::Prefill` does, so a caller can tell a full window from a failed
>   run. FAILED_PRECONDITION reads as a bug in the caller.
>
> Related, seen once the session is made usable again (we rewind it to a
> checkpoint): `Tasks::Prefill` calls `BenchmarkInfo::TimePrefillTurnStart()`
> before `executor.Prefill` and `TimePrefillTurnEnd` only after it succeeds,
> so with benchmark enabled a failed prefill leaves the start mark and every
> later prefill of the session fails with
> `INTERNAL: Prefill turn prefill:N already started.` `Tasks::Decode` has the
> same shape for `TimeDecodeTurnStart`.

## LiteRT C API at the 0.19 pin (`dcb657e8`, was `26895c9f`; macOS, 2026-11-04)

- **Headers.** The ten headers the bindings read (`litert_{model,environment,options,tensor_buffer,compiled_model,layout,model_types,common,tensor_buffer_types,opaque_options}.h`) were diffed across the two pins. All 24 functions in `LITERT_BINDINGS_SYMBOLS` keep their declarations. `litert_layout.h` and `litert_model_types.h` (the structs we mirror) are byte-identical. The rest is additions: delegation metrics, `LiteRtGetRuntimeAbiVersion`, `LiteRtCreateTensorBufferFromCustomHandle`, and `kLiteRtStatusErrorFailedPrecondition = 11`. Every status value is explicit and none moved.
- **Probe.** `probes/litert_probe.c` makes the `.tflite` pass's calls in its order. It is compiled against the pin's headers, with each pointer typed from its declaration, so a moved signature fails the build. It covers 19 of the 24 functions; the opaque-options and buffer-requirement calls used by speech are covered by the header diff only.

| Gecko 110m seq64 (registry sha256) | 0.19 (`mac23`) | 0.18.0-h (release archive) |
|---|---|---|
| CPU | PASS: dim 768, norm 1.0, repeat bit-identical, the two inputs cos 0.223 | PASS, **vectors bit-identical to 0.19** |
| Metal | `LiteRtCreateCompiledModel` 504 (589 of 633 ops on the GPU, then compile fails) | the same 504, with the Metal framework staged and registered |

The Gecko Metal failure is therefore not new in 0.19.

EmbeddingGemma 1 (`embeddinggemma-300M_seq256_mixed-precision.tflite`, registry
sha256), run once the Hugging Face login was in place:

| | 0.19 (§1-§25) | 0.18.0-h |
|---|---|---|
| CPU | PASS: dim 768, norm 1.0, repeat bit-identical, the inputs cos 0.256 | PASS, the inputs cos 0.254 |
| Metal | all-zero vectors (FAIL) | the same all-zero vectors |

Both versions repeat bit for bit across processes. Between them, one input's
vector is identical and the other's is not: cos 0.99886, largest component
difference 5.0e-3. Gecko, by contrast, is identical on both inputs. The Metal zeros are the known "EG1 on the GPU does not work" result,
unchanged. The drift is isolated in the next section.

## Pre-tag probe 1: §16 across conversations, and §24 (macOS, 2026-11-04)

Probe command `convrewind [image]`, Gemma 4 E2B, window 1024, CPU and Metal.
A streamed reply on conversation A is cancelled mid-decode and a turn runs on
B. A is then rewound with the stopped exchange (the user message plus the
partial reply produced, as the Dart client passes it) and asked a follow-up.
The same path without B must give the same greedy follow-up. A control
conversation seeded with that exchange through `config_set_messages` is
reported beside it.

**Found: a rewind followed by a prefill could lose the history.** A rewind
with the partial "The salt-laced wind was Elara's" left the conversation at
5 tokens instead of 34. The model then answered "I am Gemma 4, a Large
Language Model developed by Google Deep Hungary.", while the control
conversation recalled the story. It happened on CPU and Metal, with and
without B. With "…Bob's" the count was 33 and the answer correct.

Cause: after `RewindToCheckpoint` the executor's step is at the checkpoint,
but its processed tokens still hold the stopped send's tokens. The resource
manager's prefill drops the input tokens that match them (`RemoveMatchingTokens`).
When all of them match, it calls the executor with the new step in the prefill
params only. The executor takes its step from `SetCurrentStep`, so the rest of
the input was prefilled at the checkpoint's step, and the matched tokens were
lost. That is the usual case after a stop: the partial reply ends with the
token the executor holds as pending. The other branch already calls
`SetCurrentStep`.

**§24** (`patches/resource_manager_matched_step.patch`) adds that call to the
full-match branch.

With §24:

| Run | CPU | Metal |
|---|---|---|
| text, the stream's own partial | PASS | PASS |
| text, forced "…Elara's" / "…Elara" / "…Bob's" | PASS, 34 / 32 / 33 tokens | PASS, 34 / 32 / 33 tokens |
| image (house_scene.png, ~300 tokens) | PASS | PASS |

On Metal the follow-up depends on how far the cancelled decode got, because
reused positions hold decode-written KV, which is not bit-identical to the same
tokens prefilled. The probe therefore compares only runs that stopped at the
same step, read with `get_token_count` after the final chunk. On CPU every run
matches.

### Upstream issue draft (not posted)

> **Prefill after `rewind_to_checkpoint` drops the history when the input
> starts with every token the executor processed after the checkpoint**
>
> LiteRT-LM v0.19.0 (`771b06e1`), macOS arm64, CPU and Metal, conversation
> and session API.
>
> 1. Save a checkpoint, prefill a message, decode a few tokens, stop.
> 2. Rewind to the checkpoint and prefill a text that begins with the same
>    tokens (the message and the tokens decoded so far) and continues.
> 3. `GetCurrentStep()` is the length of the continuation only (Gemma 4 E2B:
>    5 instead of 34), and the model no longer sees the message.
>
> `ResourceManager`'s prefill drops the tokens that match the processed ones
> with `RemoveMatchingTokens`. When the processed tokens are all matched
> (`processed_tokens->TokenCount() == current_step`), it calls
> `llm_executor_->Prefill(new_inputs, new_prefill_query_params)` with the new
> step set on the params only. `LlmLiteRtCompiledModelExecutorBase::Prefill`
> does not read `ExecutorPrefillParams::GetCurrentStep()`, so the
> continuation is prefilled from the step the rewind set. The branch below it
> calls `llm_executor_->SetCurrentStep(current_step)` first. Calling it in
> this branch too fixes it.

## Pre-tag probe 3: deleting a conversation while another generates (macOS, 2026-11-04)

Probe command `deleteduring` (`PROBE_REPEAT=4`). Conversation A streams a
reply. After four chunks, B is deleted, in two variants:
- B idle, with a history;
- B with its own stream just cancelled (cancel, then delete at once).

A's reply must end with a final chunk and no failure, equal a run where
nothing is deleted (greedy), and A must answer a follow-up.

| Model | CPU | Metal |
|---|---|---|
| Gemma 4 E2B | 8/8 PASS, deleted at A's chunk 4 of a running reply | 8/8 PASS, same |
| FunctionGemma 270M | 8/8 PASS, **no overlap**: its reply had already ended at chunk 2 | same |

The delete returned in under 1 ms in every run. For the Dart client this means
`_deleteConversation` can overlap a turn on another conversation; the overlap
was measured on Gemma 4 E2B only. Adreno and the NPUs were not run.

## Pre-tag probe 2: state carried between conversations, and §25 (macOS, 2026-11-04)

Probe command `xsession` checks two things:
- four conversations in a row with one prompt on one engine, against the same
  prompt on four fresh engines;
- two live conversations interleaved (X, Y, X), against X alone.

**Phase-1 finding 5 explained.** On LFM2.5-230M int8, every conversation
after the first on one engine answered differently, and the difference
accumulated. A fresh engine always gave the first answer. FunctionGemma was
identical in all eight runs. §24 changed nothing.

Cause: LFM2 keeps a convolution state (`kv_cache_c_`) beside its attention KV
cache. `Reset()` and a new session only move the step to 0. That is enough for
a KV cache, which is masked by position, but the convolution state is cleared
only when its buffers are created. **§25** (`patches/linear_attention_state_clear.patch`)
clears the `TYPE_LINEAR_ATTENTION` buffers when a prefill starts an empty
context.

| LFM2.5-230M int8 | before §25 | with §25 |
|---|---|---|
| CPU: same engine ×4 / interleaved | 3 of 4 differ / FAIL | PASS / PASS |
| Metal: same engine ×4 / interleaved | 3 of 4 differ / FAIL | PASS / PASS |

Regression with §25: every probe command (multiconv, determinism, constrained,
rewind, scoring, longprompt, tools, prefillroom, convrewind, deleteduring,
xsession, turnend) passes on Gemma 4 E2B, CPU and Metal. FunctionGemma 270M
fails `multiconv` (CPU, Metal), `tools` (CPU, Metal) and `longprompt` (CPU)
identically without §24 and §25: those are the model's own answers, not
regressions.

Still open for hybrid models: a rewind to a step above 0 (§16, and the
matched-token reuse of §24) restores the KV cache but not the convolution
state at that step. A stopped LFM2 reply should be rebuilt from text, not
rewound. That was not measured here and is a question for L3.

Not run on macOS: "a conversation longer than the first context group". Context
groups exist only in the NPU executor, so it needs an NPU device (paid).

## Embedding and speech drift, 0.18 → 0.19: where it comes from (2026-11-04)

The question: is the difference introduced by 0.19, or by §21?

Tools:
- `probes/litert_probe.c` batch mode (one id sequence per line);
- `probes/eg2_text.c` (EG2 through either C API shape: `-DC_API_018` for native-v0.18.x);
- `probes/litert_drift.c` with `litert_drift_compare.py`: any `.tflite`, every static-shape signature, fixed pseudo-random inputs, outputs compared file by file.

Runs:
- macOS M-series CPU: 0.18.0-h, 0.19 with §21, and 0.19 built **without §21**;
- Linux arm64 in Docker on the same Mac: native-v0.18.0-h, and the CI artifact of run 41749984146 (0.19, §1-§25).

The retrieval set is 50 documents and 10 queries, tokenized like the Dart
client (`[2] + encode(prefix + text) + [1]`, core's `TaskType` prefixes).

| Comparison | EG1 `.tflite` | EG2 270m `.litertlm` | Qwen3-TTS talker int4 (169 outputs) | Gecko, Moonshine, Whisper (f32, i8), Matcha |
|---|---|---|---|---|
| Linux 0.18 vs Linux 0.19 | identical | identical | 169/169 identical | identical |
| macOS 0.19 vs Linux 0.19 | identical | identical | 169/169 identical | identical |
| macOS 0.19 without §21 vs with §21 | identical | — | — | — |
| macOS 0.18 vs everything above | docs cos min 0.99867 (46/50 differ) | docs cos min 0.99923 (45/50 differ) | 22/169 identical, worst cos 0.9971 | Matcha decoder 2.4e-6 relative; the rest identical |

So 0.19 computes the same numbers on macOS and Linux, with or without §21,
and the same numbers Linux 0.18 did. The outlier is **0.18 on Apple CPUs**:
its LiteRT/XNNPACK pin took a different CPU kernel path there, and the 0.19
pin no longer does. This is not attributed further; Linux in Docker exposes
no SME, so the Linux side always takes the portable path.

Effect on retrieval, macOS (0.18 documents queried by 0.19, and both sides on
0.19): for EG1 and EG2, all 10 queries keep their top-1 and the full top-5
order, and gold is first on every side. The largest change in a query-document
score is 0.0056, larger than the smallest gap between neighbours in a top 6
(0.0033), so a denser corpus could swap neighbours.

Affected data: only vectors produced by 0.18 on Apple CPUs, i.e. macOS and
probably iOS (not measured), which take the same build path. Not run:
- Linux x86_64 (Docker's emulated CPU has no AVX, which LiteRT requires);
- Windows, Android.

The talker's random-input difference is large, but it is the 0.18 Apple
outlier too, not 0.19; whether it was audible was not measured.

## L1 smoke matrix, free part: macOS and Linux arm64 (2026-11-04)

Builds: macOS from the §1-§25 tree (the official `build_macos.sh` build gives
the same vectors byte for byte); Linux arm64 from CI run 41749984146 in an
`ubuntu:24.04` container on the same Mac (CPU only).

| Check | macOS CPU | macOS Metal | Linux arm64 CPU |
|---|---|---|---|
| Gemma 4 E2B: all 12 probe commands + `chat` | PASS | PASS | PASS (13/13) |
| Gemma 4 E2B: `convrewind` with an image | PASS | PASS | PASS |
| FunctionGemma 270M: determinism, rewind, scoring, prefillroom, convrewind, deleteduring, xsession, turnend | PASS | PASS | PASS |
| FunctionGemma 270M: tools, multiconv, longprompt | the model's own answers, the same on builds without §24/§25 | same | not run |
| LFM2.5-230M int8 `xsession` (§25) | PASS | PASS | PASS |
| EG2 270m text | PASS, 0.09 s | PASS, 0.02 s | PASS |
| EG2 740m text / image / audio / combined (towers on CPU) | PASS: input lengths 14 / 134 / 79 / 223 | PASS, same lengths | PASS |
| FastVLM 0.5B (#268), text and image | PASS ("Paris."; "A simple drawing of a house and a sun…") | PASS | PASS |
| Old Qwen3 0.6B file (#659, `a6e678a1d43b`) | loads; with 64 output tokens the reply is all thinking ("France's capital is Paris…") | loads, answers | loads, thinking only, as on macOS |
| Phi-4 mini q8 (§17, two-NUL piece) | PASS ("Paris.") | PASS | PASS |

**EG2 cache files on 0.19:** the names are the ones the Dart pass checks
(`requireWeightCache`):
- CPU: `<file>_<mtime>_<size>.{text_encoder,vision_encoder,streaming_audio_encoder,vision_adapter,audio_adapter}.xnnpack_cache`;
- GPU: `<file>.text_encoder_<mtime>_<size>_mldrift_{weight,program}_cache.bin`.

**New: EG2 on the macOS GPU works on 0.19.** The 270m and 740m text towers
run on Metal: 24 ms, ML Drift caches written. On 0.18 this path SIGBUSed in
LiteRT's external weight loader, which is why the Dart catalog does not honour
`gpu` on macOS (`liteRtLmEmbeddingGpuAbis`). Lifting that is an L2 decision.

Paid runs: `litertlm-0.19-l1-paid-runs.md`.
