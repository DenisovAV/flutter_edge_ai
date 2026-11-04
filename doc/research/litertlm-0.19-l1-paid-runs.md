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
