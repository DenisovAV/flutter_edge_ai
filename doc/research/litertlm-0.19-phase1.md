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

