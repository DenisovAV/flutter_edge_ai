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
| Windows x86_64 (+ Intel NPU dispatch) | CI runs 41277710260, 41281104298 | ✅ both | No TopK WebGPU sampler exists for Windows any more (upstream marks it incompatible), so Windows GPU samples on the CPU. |
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
| §17 SentencePiece NUL piece | **drop** | v0.19.0 carries its own `third_party/sentencepiece/sentencepiece.patch`; FastVLM-0.5B (NUL piece) loads and answers on macOS without ours |
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
3. **No TopK sampler on Windows GPU** (upstream has none for Windows any more).
4. **macOS CPU greedy is nondeterministic** (above).

## Not run (paid or blocked)

DDP (Qualcomm NPU on SM8750, Adreno constrained/MTP, #3508 Gemma 3 NPU, Pixel 11
Tensor G6, MediaTek refusal on a Tab S10+), GCE T4 (Linux GPU constrained/MTP,
the web suites on `@litert-lm/core` 0.19.0), the Intel boxes (Windows NPU tool
calls and §15, #4083 Gemma 4 12B on the Panther Lake GPU, Windows GPU
constrained). The auto-mode classifier refused the DDP reservation and the SSH
session because the approval came through the coordinating thread.
