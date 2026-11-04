# LiteRT-LM 0.19 (L1, `native-v0.19.0-a`): paid-run plan

2026-11-04. One reservation per resource covers everything L1 still needs from
it. Nothing here has been reserved. DDP bills per minute; the T4 VM bills
while it runs. Every artifact is staged on the Mac before the reservation, so
the reserved minutes are spent running.

Free work already done on macOS (CPU, Metal) and Linux arm64 (Docker, CPU)
is in `litertlm-0.19-phase1.md`. What follows is what only devices can show.

## Staged before any reservation

| Artifact | Where | Notes |
|---|---|---|
| Android archive, §1-§25 (no MediaTek adapter, decision K) | `~/Work/.scratch/flutter_edge_ai-l1/dist/litertlm-android_arm64.tar.gz` | local `build_android.sh` at `771b06e1`; passes `verify_tarball_manifest.sh` except the expected `get_last_error_code` (L2) |
| Android probes (API 30) | `~/Work/.scratch/flutter_edge_ai-l1/android_probes/` | `litertlm_probe` (all commands, incl. `ctxgroup`, `convrewind`, `chat`, `eg2` with image/audio), `litert_drift`, `litert_probe`, `eg2_text` |
| Linux x86_64 and Windows archives | `dist/litertlm-linux_x86_64.tar.gz`, `dist/litertlm-windows_x86_64.tar.gz` | CI run 41749984146 |
| Gemma 4 E2B NPU bundles | `~/Work/.scratch/flutter_edge_ai-n1/models/` (Qualcomm SM8750 2.9 GB, Tensor G6 3.2 GB) | pushed from the Mac: Pixels have no curl |
| Gemma 4 E2B generic, FunctionGemma, LFM2.5, EG1, EG2 270m/740m, FastVLM, Phi-4 mini q8, old Qwen3, speech `.tflite` | `~/Work/.scratch/flutter_edge_ai-l1/models/` | all sha256-checked against the registry |
| EG2 per-SoC NPU bundles (SM8750 270m/440m/740m, Tensor G6 270m/440m, `_Intel_PTL` 270m) | to download before the runs (HF, gated) | sizes from the registry |
| #770 MediaPipe test APKs | built from `feat/core-session-spi` with `run_instrumented.sh`'s build step, before reserving | `gemma3-1b-it-int4.task` pushed to `/data/local/tmp/flutter_gemma_test/` |
| #745 ONNX smoke | `~/Work/.scratch/flutter_edge_ai-745/run_745.sh` (branch `fix/onnx-android-smoke-staged-model`) | Phi-3.5-mini ONNX dir (~2.7 GB) pushed first |

One run script per device writes every result to `~/Work/.scratch/flutter_edge_ai-l1/paid/<device>/`
and prints the `RESULT` lines; the first step reads the device's SoC and
driver into the log.

## DDP Galaxy S25 (SM8750, Adreno 830): ~60 min

1. **Qualcomm NPU, Gemma 4 E2B SM8750 bundle** (`npu`, dispatch dir with Qualcomm only, `qualcomm_npu` QNN libs):
   - `multiconv`, `longprompt`, `turnend`, `deleteduring`, `chat`;
   - `ctxgroup`, with `PROBE_CTX_FILL` set past the first context size the executor logs (a single-size bundle is recorded "not applicable");
   - `rewind` and `convrewind`: the NPU's one-token rollback must refuse cleanly; record the code.
2. **Adreno 830 GPU, Gemma 4 E2B generic**: all 12 commands of the macOS regression, plus `xsession` on LFM2.5 and `chat` with an image on FastVLM.
3. **Packaging question (verify_tarball_manifest.sh comment):** step 2's `multiconv` and `chat` again with `libLiteRtOpenClAccelerator.so` and `libLiteRtTopKOpenClSampler.so` removed from the lib dir. GPU still used, same output → Adreno half of the evidence to drop them.
4. **EG2 on the NPU**: 270m/440m/740m `_Qualcomm_SM8750` with `PROBE_EG2_IMAGE`/`PROBE_EG2_AUDIO` (audio tower on CPU, as the Dart pass names it); the generic 740m on CPU for the vector comparison.
5. **Drift on Android CPU**: `litert_drift` (Gecko, EG1, speech) and `eg2_text` (EG2) against native-v0.18.0-h's Android archive, as on Linux.
6. **#770 MediaPipe**: `multi_session_mediapipe_test.dart` through `run_instrumented.sh`. Verdict: the `I/flutter` summary line.
7. **#745**: `run_745.sh`.

Estimate: 5 (setup, push ~6 GB over adb) + 15 (1) + 15 (2) + 5 (3) + 8 (4) + 5 (5) + 5 (6) + 5 (7).

## DDP Pixel 11 (Tensor G6): ~35 min

1. **Tensor NPU, Gemma 4 E2B G6 bundle** (dispatch dir with Tensor only): `multiconv`, `ctxgroup`, `longprompt`, `turnend`, `deleteduring`, `chat`, `convrewind` (rollback refusal).
2. **EG2 on the NPU**: 270m/440m `_Google_Tensor_G6`, text and image.
3. **GPU** (not Mali or Adreno): `multiconv` and `chat` on Gemma 4 E2B generic, as a third GPU family.

Estimate: 5 (setup, push 3.2 GB + EG2) + 15 + 5 + 5. Tensor numbers stay out of public text.

## DDP Mali phone (e.g. a Galaxy with Exynos, or a Pixel 8/9): ~25 min

1. **Mali GPU, Gemma 4 E2B generic**: all 12 commands.
2. **Packaging question, Mali half**: as S25 step 3.
3. `chat` with an image (FastVLM) on GPU.

Estimate: 5 + 12 + 4 + 4.

## GCloud T4 VM (Linux x86_64, Vulkan): ~45 min running

1. **CPU, Linux x86_64** (the part Docker cannot run here: no AVX under emulation):
   - drift (EG1, EG2, speech) against native-v0.18.0-h;
   - all 12 commands on Gemma 4 E2B;
   - `xsession` on LFM2.5;
   - `chat` on FastVLM, old Qwen3 and Phi-4 mini.
2. **T4 GPU**: all 12 commands; EG2 270m on GPU (cache-file names, `liteRtLmEmbeddingGpuAbis`), 740m with image/audio towers on CPU.
3. Gated models are copied from the Mac (`scp`); no token on the VM.

## intel-ptl (Windows x64, Arc B390, Panther Lake NPU): ~50 min

1. **CPU**: drift against native-v0.18.0-h (Windows), the 12 commands.
2. **Arc B390 GPU**:
   - the 12 commands;
   - EG2 270m `gpu`: does it still crash on 0.19 (#744, `liteRtLmEmbeddingGpuRefusedAbis`)? Either result is recorded; a pass lifts the refusal only after an L2 decision.
3. **Intel NPU**:
   - Gemma 4 E2B Intel bundle: `multiconv`, `ctxgroup`, `turnend`, `chat`;
   - EG2 270m `_Intel_PTL`;
   - weight banks in `%TEMP%` created and deleted.
4. Only our scratch folder is touched; no processes we did not start are stopped.

## intel-lnl (Windows x64, Arc 140V, Lunar Lake NPU): ~30 min

1. Arc 140V GPU: the 12 commands (not re-run since §20).
2. Intel NPU (LNL): Gemma 4 E2B `multiconv`, `ctxgroup`, `chat`.

## QDC (only if needed)

Linux arm64 Qualcomm NPU (QCS8275): EG2 270m NPU and Gemma 4 E2B `qcs8275` `multiconv`/`ctxgroup`. Skippable for L1 if S25 passes: the Linux dispatch is the same code with §11's options, and EG2 NPU on QCS8275 was verified on 0.18.

## Not paid, needs the device at hand

iPhone (A19): the 12 commands on Metal and CPU through an app build. The
probes run as command-line tools on macOS only. Whether iOS took the same
0.18 kernel path as macOS (the drift question) is answered by EG1/EG2 there.

## Totals

About 2 h of DDP (60 + 35 + 25 min, three devices, one at a time), 45 min of T4, 80 min on the
Intel boxes (one machine at a time). Each line above is cancelled as soon as
its script's last `RESULT` line is in.

## Results: DDP Galaxy S25 Ultra (pa3q-35, SM8750, Adreno 830), 2026-11-04

Session `session-3olmn6k9u8yzk`, 02:50–04:07 UTC (77 billed minutes,
extended once). The phone's own curl reached only ~0.5 MB/s, so models went
over the forwarder (3.3–6 MB/s) instead. Android archive: the local L1 build
(§1-§25, no MediaTek adapter).

| Check | Result |
|---|---|
| Qualcomm NPU, Gemma 4 E2B SM8750: multiconv, longprompt, deleteduring, chat | PASS (3/3, "PELICAN", 0.23 s reply) |
| NPU turnend | every end kind right (stop token, output limit, context limit, context_full code 8); the rewind after context_full is refused (status 3), and the conversation stays usable without it |
| NPU rewind / convrewind | refused: "NPU executor's SetCurrentStep only supports rolling back one step", as on 0.18 (the Dart client rebuilds from text on the NPU) |
| **NPU ctxgroup** (window 4096): A past 1100 tokens, a turn on B, A recalls the code word | **PASS** at 1104 tokens (with window 1024 the probe's own window ran out at 1006) |
| Adreno 830 GPU, Gemma 4 E2B: all 13 commands | PASS |
| Adreno without `libLiteRtOpenClAccelerator.so` and `libLiteRtTopKOpenClSampler.so` | multiconv, chat, determinism: same results as with them (timing only), so the GPU runs on the accelerator linked into libLiteRtLm: the Adreno half of the drop evidence |
| LFM2.5 xsession on Adreno (§25) | PASS |
| EG2 on the NPU: 270m and 440m text; 440m image (289 ms); 740m text, image, audio (tower on CPU, 121 ms), combined | PASS |
| EG2 270m on Adreno (not measured before) | PASS, 52 ms |
| Drift, Android CPU 0.19 vs Linux arm64 0.19 | EG1, Gecko, Moonshine, Whisper i8, Matcha decoder, talker (169/169): bit-identical; EG1 retrieval identical to macOS 0.19 |
| #770 `multi_session_mediapipe_test.dart` (branch `feat/core-session-spi`) | PASS, 3 tests |
| #745 ONNX smoke (Phi-3.5 mini int4, branch `fix/onnx-android-smoke-staged-model`) | PASS: 23.2 tok/s median decode, peak RSS 3.7 GB |

Not done on this session:
- FastVLM with an image on Adreno (FastVLM passed on macOS and Linux).
- The native-v0.18.0-h side of the Android drift: our `litert_drift` segfaults on the 0.18 Android library (it ran fine on 0.18 macOS); not chased on billed time.

Note for L2: the EG2 740m NPU bundle fails engine create unless an audio
backend is named (`embedding_engine_impl.cc:409`), because its audio encoder is
compiled for CPU/GPU only. The Dart pass names `cpu` when audio is declared; a
740m NPU load without declared audio should be checked.

## Results: DDP Pixel 11 (cubs-37, Tensor G6, PowerVR GPU), 2026-11-04

Session `session-ftxstpjglk19a`, 04:12–04:32 UTC (about 21 billed minutes).
Timings are left out for Tensor.

| Check | Result |
|---|---|
| Tensor NPU, Gemma 4 E2B G6 bundle: multiconv, longprompt, deleteduring, chat | PASS |
| NPU turnend | every end kind right; the rewind after context_full refused (status 3), as on Qualcomm |
| NPU convrewind | rewind refused (one-token rollback), as on Qualcomm |
| **NPU ctxgroup** (window 4096) | **PASS** at 1104 tokens |
| EG2 on the NPU: 270m text; 440m text, image, combined | PASS |
| PowerVR GPU, FunctionGemma: chat | PASS |
| PowerVR GPU, FunctionGemma: multiconv | FAIL: the model's own answers, as on macOS |
| PowerVR GPU, FunctionGemma: determinism | **FAIL**: two greedy conversations diverge at character 245 (Metal and CPU are deterministic for this model). Open question for the PowerVR GPU path; not chased on billed time |

## Results: DDP Pixel 8a (akita-34, Tensor G3, Mali-G715), 2026-11-04

Session `session-1pii5wtsudyyj`, 04:34–05:05 UTC (about 31 billed minutes).

| Check | Result |
|---|---|
| Mali-G715 GPU, Gemma 4 E2B: all 13 commands | PASS |
| Mali without `libLiteRtOpenClAccelerator.so` and `libLiteRtTopKOpenClSampler.so`: multiconv, chat, determinism | PASS, identical results (determinism hash `642e1f7c…` both ways) |
| LFM2.5 xsession on Mali (§25) | PASS |
| FastVLM with an image on Mali | PASS |

**Packaging (verify_tarball_manifest.sh):** Adreno 830 and Mali-G715 now both
run the GPU with the two separate OpenCL libraries removed, with the same
results. That is the evidence the manifest comment asked for to drop them
from the Android archive. The drop itself is left for a decision (it changes
the archive).

DDP total for L1: S25 77 + Pixel 11 21 + Pixel 8a 31 = about 129 billed minutes.
