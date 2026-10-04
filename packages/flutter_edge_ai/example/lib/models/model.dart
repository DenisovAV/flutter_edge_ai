// ignore_for_file: unused_element_parameter

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'base_model.dart';

// Platform detection that's safe for web
bool get _isDesktop {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

enum Model implements InferenceModelInterface {
  // === GEMMA MODELS (Top Priority) ===

  // Gemma 4 (Next-gen multimodal: text + image + audio) — LiteRT-LM builds are
  // the primary entries (litertlm everywhere incl. web -web.litertlm). The
  // web-only MediaPipe (.task) twins live further down as *_web.

  // Gemma 4 E2B LiteRT-LM. On web, uses the `-web.litertlm` build optimised for
  // WebGPU/WASM via @litert-lm/core. Text-only on web; full
  // multimodal on native.
  gemma4_E2B_litertlm(
    baseUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    filename: 'gemma-4-E2B-it.litertlm',
    displayName: 'Gemma 4 E2B IT',
    size: '2.4GB',
    licenseUrl: '',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    supportImage: true,
    supportAudio: true,
    maxTokens: 4096,
    maxNumImages: 4,
    isThinking: true,
    supportsFunctionCalls: true,
    agentic: true,
  ),

  // Gemma 4 E4B LiteRT-LM.
  gemma4_E4B_litertlm(
    baseUrl:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it-web.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
    filename: 'gemma-4-E4B-it.litertlm',
    displayName: 'Gemma 4 E4B IT',
    size: '4.3GB',
    licenseUrl: '',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    supportImage: true,
    supportAudio: true,
    maxTokens: 4096,
    maxNumImages: 4,
    isThinking: true,
    supportsFunctionCalls: true,
    agentic: true,
  ),

  // Gemma 4 E2B compiled for Intel NPU (Windows only, PreferredBackend.npu).
  // Chip-specific builds — pick the one matching the silicon:
  //   _LNL = Lunar Lake, _PTL = Panther Lake.
  // The plugin auto-configures the NPU dispatch dir on Windows; the bundled
  // LiteRtDispatch.dll + OpenVino + TBB ship in the same native tarball.
  // Source: https://ai.google.dev/edge/litert/next/litert_lm_npu#intel
  gemma4_E2B_intel_LNL(
    baseUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it_intel_LNL.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it_intel_LNL.litertlm',
    filename: 'gemma-4-E2B-it_intel_LNL.litertlm',
    displayName: 'Gemma 4 E2B IT (Intel NPU - Lunar Lake)',
    size: '2.96GB',
    licenseUrl: '',
    needsAuth: false,
    preferredBackend: PreferredBackend.npu,
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 4096,
    isThinking: true,
  ),

  gemma4_E2B_intel_PTL(
    baseUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it_intel_PTL.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it_intel_PTL.litertlm',
    filename: 'gemma-4-E2B-it_intel_PTL.litertlm',
    displayName: 'Gemma 4 E2B IT (Intel NPU - Panther Lake)',
    size: '2.95GB',
    licenseUrl: '',
    needsAuth: false,
    preferredBackend: PreferredBackend.npu,
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 4096,
    isThinking: true,
  ),

  // Gemma 4 E2B/E4B — WEB-ONLY MediaPipe (.task) builds, right below their
  // LiteRT-LM twins. HuggingFace only ships a `-web.task` for Gemma 4 (no
  // mobile/desktop .task — those are .litertlm only, see the *_litertlm
  // entries above). So these run on web only, through the MediaPipe
  // `@mediapipe/tasks-genai` path. fileType is `task` to match the file —
  // mixing it with `litertlm` routed the .task blob into the LiteRT-LM engine
  // and failed with "Invalid magic number".
  gemma4_E2B_web(
    baseUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.task',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.task',
    filename: 'gemma-4-E2B-it-web.task',
    displayName: 'Gemma 4 E2B IT (Web/MediaPipe)',
    size: '2.0GB',
    licenseUrl: '',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemma4,
    fileType: ModelFileType.task,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    supportImage: true,
    supportAudio: false, // .task has no audio encoder
    maxTokens: 4096,
    maxNumImages: 4,
    isThinking: true,
    supportsFunctionCalls: true,
  ),
  gemma4_E4B_web(
    baseUrl:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it-web.task',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it-web.task',
    filename: 'gemma-4-E4B-it-web.task',
    displayName: 'Gemma 4 E4B IT (Web/MediaPipe)',
    size: '3.0GB',
    licenseUrl: '',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemma4,
    fileType: ModelFileType.task,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    supportImage: true,
    supportAudio: false, // .task has no audio encoder
    maxTokens: 4096,
    maxNumImages: 4,
    isThinking: true,
    supportsFunctionCalls: true,
  ),

  // Gemma 3 Nano models (Multimodal + Function Calls).
  // These are the MOBILE MediaPipe (.task) builds — HuggingFace only ships a
  // mobile .task for Gemma 3n (no -web.task; web/desktop are .litertlm only).
  // So keep them mobile-only with fileType task; web/desktop users take the
  // *_litertlm entries below (litertlm everywhere). Mixing a .litertlm web/
  // desktop URL under fileType task routed the blob into the wrong engine.
  gemma3n_2B(
    baseUrl:
        'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/gemma-3n-E2B-it-int4.task',
    filename: 'gemma-3n-E2B-it-int4.task',
    displayName: 'Gemma 3 Nano E2B IT (MediaPipe)',
    size: '3.1GB',
    licenseUrl: 'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview',
    needsAuth: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.task,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    supportImage: true,
    supportAudio:
        false, // .task files don't have TF_LITE_AUDIO_ENCODER - audio only in .litertlm
    maxTokens: 4096,
    maxNumImages: 4,
    supportsFunctionCalls: false, // Disabled - causes issues with multimodal
    foregroundDownload: true, // Large model - use foreground service on Android
  ),
  gemma3n_4B(
    baseUrl:
        'https://huggingface.co/google/gemma-3n-E4B-it-litert-preview/resolve/main/gemma-3n-E4B-it-int4.task',
    filename: 'gemma-3n-E4B-it-int4.task',
    displayName: 'Gemma 3 Nano E4B IT (MediaPipe)',
    size: '6.5GB',
    licenseUrl: 'https://huggingface.co/google/gemma-3n-E4B-it-litert-preview',
    needsAuth: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.task,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    supportImage: true,
    supportAudio:
        false, // .task files don't have TF_LITE_AUDIO_ENCODER - need .litertlm
    maxTokens: 4096,
    maxNumImages: 4,
    supportsFunctionCalls: false, // Disabled - causes issues with multimodal
    foregroundDownload: true, // Large model - use foreground service on Android
  ),

  // Gemma 3 1B model
  gemma3_1B(
    baseUrl:
        'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/gemma3-1b-it-int4.task',
    webUrl:
        'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/gemma3-1b-it-int4-web.task',
    desktopUrl:
        'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    filename: 'gemma3-1b-it-int4.task',
    displayName: 'Gemma 3 1B IT',
    size: '0.5GB',
    licenseUrl: 'https://huggingface.co/litert-community/Gemma3-1B-IT',
    needsAuth: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 1024,
  ),

  // Gemma 3 270M (Ultra-compact text-only model)
  gemma3_270M(
    baseUrl:
        'https://huggingface.co/litert-community/gemma-3-270m-it/resolve/main/gemma3-270m-it-q8.task',
    webUrl:
        'https://huggingface.co/litert-community/gemma-3-270m-it/resolve/main/gemma3-270m-it-q8-web.task',
    desktopUrl:
        'https://huggingface.co/litert-community/gemma-3-270m-it/resolve/main/gemma3-270m-it-q8.litertlm',
    filename: 'gemma3-270m-it-q8.task',
    displayName: 'Gemma 3 270M IT',
    size: '0.3GB',
    licenseUrl: 'https://huggingface.co/litert-community/gemma-3-270m-it',
    needsAuth: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 1024,
    supportsFunctionCalls: false,
  ),

  // LFM2.5 230M — the smallest entry here (int4, 168 MB) and the only one that
  // needs no HuggingFace token. LiquidAI's lfm2 architecture, a ShortConv /
  // attention hybrid (14 layers: 8 conv + 6 GQA) rather than a plain
  // transformer, which is what makes it viable on low-end hardware.
  //
  // Installed through `fromHuggingFace(repo)`: the repo ships a
  // litertlm_manifest.json, so the resolver supplies the variant, the backend
  // and maxTokens. The url/filename/backend fields below are what the manifest
  // resolves to today — they are here so the entry still renders in the picker,
  // not because the install path reads them.
  //
  // Verified end to end on macOS 26.5.1 (Apple Silicon), Android 12 (RayNeo
  // ARGF20, arm64), Windows 10 Pro 26200 and Ubuntu + Tesla T4 — gpu on all
  // four, no manual override. See
  // example/integration_test/hf_fileless_install_device_test.dart.
  //
  // Instruction-following is weak at this size: "say hello in one word"
  // produced a one-word reply on one of the four runs and a polite paragraph on
  // the other three. Fine for checking the pipeline works; not a quality bar.
  lfm25_230m(
    hfRepo: 'litert-community/LFM2.5-230M',
    baseUrl:
        'https://huggingface.co/litert-community/LFM2.5-230M/resolve/main/LFM2.5-230M_int4.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/LFM2.5-230M/resolve/main/LFM2.5-230M_int4.litertlm',
    filename: 'LFM2.5-230M_int4.litertlm',
    displayName: 'LFM2.5 230M (int4)',
    size: '0.17GB',
    licenseUrl: 'https://huggingface.co/litert-community/LFM2.5-230M',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.general,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 4096,
    supportsFunctionCalls: false,
  ),

  // === LiteRT-LM ENGINE MODELS (for testing parity with MediaPipe) ===

  // Gemma 3 Nano E2B LiteRT-LM (same model, different engine).
  // Web uses the `-Web.litertlm` build that `gemma3n_2B` already pointed at
  // via `webUrl` (was loaded through MediaPipe before flutter_gemma 0.16.2; now LiteRT-LM
  // via @litert-lm/core).
  gemma3n_2B_litertlm(
    baseUrl:
        'https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/resolve/main/gemma-3n-E2B-it-int4.litertlm',
    webUrl:
        'https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/resolve/main/gemma-3n-E2B-it-int4-Web.litertlm',
    desktopUrl:
        'https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/resolve/main/gemma-3n-E2B-it-int4.litertlm',
    filename: 'gemma-3n-E2B-it-int4.litertlm',
    displayName: 'Gemma 3 Nano E2B IT',
    size: '3.1GB',
    licenseUrl: 'https://huggingface.co/google/gemma-3n-E2B-it-litert-lm',
    needsAuth: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    supportImage:
        false, // Disabled: MediaPipe iOS can't find Vision/Audio calculators for .litertlm
    supportAudio: false, // Disabled: testing text-only mode first
    maxTokens: 4096,
  ),

  // Gemma 3 Nano E4B LiteRT-LM (same model, different engine).
  // Web variant, added in flutter_gemma 0.16.2, via @litert-lm/core.
  gemma3n_4B_litertlm(
    baseUrl:
        'https://huggingface.co/google/gemma-3n-E4B-it-litert-lm/resolve/main/gemma-3n-E4B-it-int4.litertlm',
    webUrl:
        'https://huggingface.co/google/gemma-3n-E4B-it-litert-lm/resolve/main/gemma-3n-E4B-it-int4-Web.litertlm',
    desktopUrl:
        'https://huggingface.co/google/gemma-3n-E4B-it-litert-lm/resolve/main/gemma-3n-E4B-it-int4.litertlm',
    filename: 'gemma-3n-E4B-it-int4.litertlm',
    displayName: 'Gemma 3 Nano E4B IT',
    size: '6.5GB',
    licenseUrl: 'https://huggingface.co/google/gemma-3n-E4B-it-litert-lm',
    needsAuth: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    supportImage: true,
    supportAudio: true, // .litertlm files have TF_LITE_AUDIO_ENCODER
    maxTokens: 4096,
    maxNumImages: 4,
    supportsFunctionCalls: true,
  ),

  // Local Gemma models (for testing)
  gemma3LocalAsset(
    // model file should be pre-downloaded and placed in the assets folder
    baseUrl: 'assets/models/gemma3-1b-it-int4-web.task',
    filename: 'gemma3-1b-it-int4-web.task',
    displayName: 'Gemma 3 1B IT (Local)',
    size: '0.5GB',
    licenseUrl: '',
    needsAuth: false,
    localModel: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    temperature: 0.1,
    topK: 40,
    topP: 0.95,
  ),
  gemma3nLocalAsset(
    // model file should be pre-downloaded and placed in the assets folder
    baseUrl: 'assets/gemma-3n-E2B-it-int4.task',
    filename: 'gemma-3n-E2B-it-int4.task',
    displayName: 'Gemma 3 Nano E2B IT (Local)',
    size: '3.1GB',
    licenseUrl: '',
    needsAuth: false,
    localModel: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    temperature: 0.1,
    topK: 5,
    topP: 0.95,
    supportsFunctionCalls: true,
    supportImage: true,
    supportAudio: false,
  ), // .task files don't have audio encoder
  gemma3nWebLocalAsset(
    // model file should be pre-downloaded and placed in the assets folder
    baseUrl: 'assets/gemma-3n-E4B-it-int4-Web.litertlm',
    filename: 'gemma-3n-E2B-it-int4.task',
    displayName: 'Gemma 3 Nano E4B IT Web (Local)',
    size: '4.27GB',
    licenseUrl: '',
    needsAuth: false,
    localModel: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
    temperature: 0.1,
    topK: 5,
    topP: 0.95,
    supportsFunctionCalls: false,
    supportImage: true,
    supportAudio: true,
  ),

  // === OTHER MODELS ===

  // Qwen3 0.6B (LiteRT-LM format for web/desktop)
  qwen3_0_6B(
    baseUrl:
        'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
    webUrl:
        'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
    filename: 'Qwen3-0.6B.litertlm',
    displayName: 'Qwen3 0.6B',
    size: '586MB',
    licenseUrl: 'https://huggingface.co/litert-community/Qwen3-0.6B',
    needsAuth: false,
    preferredBackend: PreferredBackend.cpu,
    modelType: ModelType.qwen3,
    fileType: ModelFileType.litertlm,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    maxTokens: 4096,
    supportsFunctionCalls: true,
    isThinking: true,
  ),

  deepseek(
    baseUrl:
        'https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B/resolve/main/deepseek_q8_ekv1280.task',
    filename: 'deepseek_q8_ekv1280.task',
    displayName: 'DeepSeek R1 Distill Qwen 1.5B',
    size: '1.7GB',
    licenseUrl: '',
    needsAuth: false,
    preferredBackend: PreferredBackend.cpu,
    modelType: ModelType.deepSeek,
    temperature: 0.6,
    topK: 40,
    topP: 0.7,
    supportsFunctionCalls: true,
    isThinking: true,
  ),

  // Qwen2.5 1.5B Instruct
  qwen25_1_5B_Instruct(
    baseUrl:
        'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
    desktopUrl:
        'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
    filename: 'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
    displayName: 'Qwen 2.5 1.5B Instruct',
    size: '1.6GB',
    licenseUrl: 'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct',
    needsAuth: false,
    preferredBackend: PreferredBackend.cpu,
    modelType: ModelType.qwen,
    temperature: 1.0,
    topK: 40,
    topP: 0.95,
    maxTokens: 1024,
    supportsFunctionCalls: true,
  ),

  // Qwen2.5 0.5B Instruct (mobile only - no litertlm)
  qwen25_0_5B_Instruct(
    baseUrl:
        'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct/resolve/main/Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
    filename: 'Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
    displayName: 'Qwen 2.5 0.5B Instruct',
    size: '0.5GB',
    licenseUrl: 'https://huggingface.co/litert-community/Qwen2.5-0.5B-Instruct',
    needsAuth: false,
    preferredBackend: PreferredBackend.cpu,
    modelType: ModelType.qwen,
    temperature: 1.0,
    topK: 40,
    topP: 0.95,
    maxTokens: 1024,
    supportsFunctionCalls: true,
  ),

  // Qwen2.5 0.5B Instruct — ONNX web text generation via Transformers.js
  // (`@huggingface/transformers`), flutter_edge_ai_onnx's web arm. Model
  // identity IS the Hugging Face repo id itself — `baseUrl` is the repo
  // root, not a file — Transformers.js resolves + caches the repo bytes
  // itself, so there is nothing for core's install pipeline to download
  // (fileType onnx routes the web install through the fileless identity
  // path in WebModelManager). Native platforms route `.onnx` through
  // ORT-GenAI instead, which needs a model DIRECTORY, not a repo root URL —
  // this entry only works on web.
  qwen25_0_5B_onnxWeb(
    baseUrl: 'https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct',
    // Web-only entry: `webUrl` is what keeps it visible under the web model
    // filter (`localModel || webUrl != null`). Same HF repo URL as baseUrl —
    // Transformers.js resolves the repo id from it (fileless install).
    webUrl: 'https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct',
    filename: 'Qwen2.5-0.5B-Instruct',
    displayName: 'Qwen 2.5 0.5B Instruct (ONNX Web/Transformers.js)',
    size: '0.5GB',
    licenseUrl: 'https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.qwen,
    fileType: ModelFileType.onnx,
    temperature: 1.0,
    topK: 40,
    topP: 0.95,
    maxTokens: 1024,
    supportsFunctionCalls: false,
  ),

  // SmolLM 135M Instruct (Ultra-small, mobile only)
  smolLM_135M(
    baseUrl:
        'https://huggingface.co/litert-community/SmolLM-135M-Instruct/resolve/main/SmolLM-135M-Instruct_multi-prefill-seq_q8_ekv1280.task',
    filename: 'SmolLM-135M-Instruct_multi-prefill-seq_q8_ekv1280.task',
    displayName: 'SmolLM 135M Instruct',
    size: '135MB',
    licenseUrl: 'https://huggingface.co/litert-community/SmolLM-135M-Instruct',
    needsAuth: false,
    preferredBackend: PreferredBackend.cpu,
    modelType: ModelType.general,
    temperature: 0.7,
    topK: 40,
    topP: 0.9,
    maxTokens: 1024,
    supportsFunctionCalls: false,
  ),

  // FastVLM 0.5B (Vision-Language Model, desktop only - litertlm)
  fastVLM_0_5B(
    baseUrl:
        'https://huggingface.co/litert-community/FastVLM-0.5B/resolve/main/FastVLM-0.5B.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/FastVLM-0.5B/resolve/main/FastVLM-0.5B.litertlm',
    filename: 'FastVLM-0.5B.litertlm',
    displayName: 'FastVLM 0.5B (Vision)',
    size: '0.5GB',
    licenseUrl: 'https://huggingface.co/litert-community/FastVLM-0.5B',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.general,
    fileType: ModelFileType.litertlm,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    maxTokens: 2048,
    supportImage: true,
    maxNumImages: 4,
    supportsFunctionCalls: false,
  ),

  // ── litert-community additions (v0.14.0 model-coverage testing) ──

  // SmolLM3-3B — modern multilingual small LLM with a reasoning mode.
  smolLM3_3B(
    baseUrl:
        'https://huggingface.co/litert-community/SmolLM3-3B/resolve/main/SmolLM3-3B_q4_block32_ekv4096.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/SmolLM3-3B/resolve/main/SmolLM3-3B_q4_block32_ekv4096.litertlm',
    filename: 'SmolLM3-3B_q4_block32_ekv4096.litertlm',
    displayName: 'SmolLM3 3B',
    size: '2.0GB',
    licenseUrl: 'https://huggingface.co/litert-community/SmolLM3-3B',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.general,
    fileType: ModelFileType.litertlm,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    maxTokens: 4096,
    isThinking: true,
  ),

  // Qwen2-VL-2B — vision-language model (image + text).
  qwen2VL_2B(
    baseUrl:
        'https://huggingface.co/litert-community/Qwen2-VL-2B/resolve/main/Qwen2-VL-2B.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/Qwen2-VL-2B/resolve/main/Qwen2-VL-2B.litertlm',
    filename: 'Qwen2-VL-2B.litertlm',
    displayName: 'Qwen2-VL 2B (Vision)',
    size: '1.8GB',
    licenseUrl: 'https://huggingface.co/litert-community/Qwen2-VL-2B',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.general,
    fileType: ModelFileType.litertlm,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    maxTokens: 4096,
    supportImage: true,
    maxNumImages: 4,
  ),

  // Phi-4-mini-reasoning — Phi-4 Mini tuned for step-by-step reasoning.
  phi4MiniReasoning(
    baseUrl:
        'https://huggingface.co/litert-community/Phi-4-mini-reasoning/resolve/main/model.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/Phi-4-mini-reasoning/resolve/main/model.litertlm',
    filename: 'Phi-4-mini-reasoning.litertlm',
    displayName: 'Phi-4 Mini Reasoning',
    size: '2.8GB',
    licenseUrl: 'https://huggingface.co/litert-community/Phi-4-mini-reasoning',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.general,
    fileType: ModelFileType.litertlm,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    maxTokens: 4096,
    isThinking: true,
  ),

  // SmolVLM2-500M — compact vision-language model (image + text).
  smolVLM2_500M(
    baseUrl:
        'https://huggingface.co/litert-community/SmolVLM2-500M/resolve/main/SmolVLM2-500M.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/SmolVLM2-500M/resolve/main/SmolVLM2-500M.litertlm',
    filename: 'SmolVLM2-500M.litertlm',
    displayName: 'SmolVLM2 500M (Vision)',
    size: '0.36GB',
    licenseUrl: 'https://huggingface.co/litert-community/SmolVLM2-500M',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.general,
    fileType: ModelFileType.litertlm,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    maxTokens: 4096,
    supportImage: true,
    maxNumImages: 1,
  ),

  // LLaVA-OneVision-0.5B — compact vision-language model (image + text).
  llavaOneVision_0_5B(
    baseUrl:
        'https://huggingface.co/litert-community/LLaVA-OneVision-0.5B/resolve/main/LLaVA-OneVision-0.5B.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/LLaVA-OneVision-0.5B/resolve/main/LLaVA-OneVision-0.5B.litertlm',
    filename: 'LLaVA-OneVision-0.5B.litertlm',
    displayName: 'LLaVA-OneVision 0.5B (Vision)',
    size: '0.83GB',
    licenseUrl: 'https://huggingface.co/litert-community/LLaVA-OneVision-0.5B',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.general,
    fileType: ModelFileType.litertlm,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    maxTokens: 4096,
    supportImage: true,
    maxNumImages: 1,
  ),

  // Phi-4 Mini Instruct
  phi4_mini(
    baseUrl:
        'https://huggingface.co/litert-community/Phi-4-mini-instruct/resolve/main/Phi-4-mini-instruct_multi-prefill-seq_q8_ekv4096.task',
    webUrl:
        'https://huggingface.co/litert-community/Phi-4-mini-instruct/resolve/main/Phi-4-mini-instruct_multi-prefill-seq_q8_ekv4096.litertlm',
    desktopUrl:
        'https://huggingface.co/litert-community/Phi-4-mini-instruct/resolve/main/Phi-4-mini-instruct_multi-prefill-seq_q8_ekv4096.litertlm',
    filename: 'Phi-4-mini-instruct_multi-prefill-seq_q8_ekv4096.task',
    displayName: 'Phi-4 Mini Instruct',
    size: '3.9GB',
    licenseUrl: 'https://huggingface.co/litert-community/Phi-4-mini-instruct',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.phi,
    temperature: 0.7,
    topK: 40,
    topP: 0.95,
    maxTokens: 4096,
    supportsFunctionCalls: true,
  ),

  // === FUNCTIONGEMMA MODELS ===

  // FunctionGemma 270M IT (LiteRT-LM) — used to probe tool-calling support on
  // the @litert-lm/core web path; small enough to validate end-to-end quickly.
  functionGemma_270M_litertlm(
    baseUrl:
        'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.litertlm',
    webUrl:
        'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.litertlm',
    desktopUrl:
        'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.litertlm',
    filename: 'functiongemma-270M-it.litertlm',
    displayName: 'FunctionGemma 270M IT',
    size: '284MB',
    licenseUrl: 'https://huggingface.co/google/functiongemma-270m-it',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.functionGemma,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 1024,
    supportsFunctionCalls: true,
  ),

  // FunctionGemma 270M IT — MOBILE MediaPipe (.task) build. The litertlm build
  // is the functionGemma_270M_litertlm entry above (litertlm everywhere). Keep
  // this .task entry mobile-only: a .litertlm desktopUrl under fileType task
  // routed the blob into the wrong engine.
  functionGemma_270M(
    baseUrl:
        'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.task',
    filename: 'functiongemma-270M-it.task',
    displayName: 'FunctionGemma 270M IT (MediaPipe)',
    size: '284MB',
    licenseUrl: 'https://huggingface.co/google/functiongemma-270m-it',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.functionGemma,
    fileType: ModelFileType.task,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 1024,
    supportsFunctionCalls: true,
  ),

  // FunctionGemma 270M IT (Local asset)
  functionGemma_270M_local(
    baseUrl: 'assets/models/functiongemma-270M-it.litertlm',
    filename: 'functiongemma-270M-it.litertlm',
    displayName: 'FunctionGemma 270M IT (Local)',
    size: '284MB',
    licenseUrl: '',
    needsAuth: false,
    localModel: true,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.functionGemma,
    fileType: ModelFileType.litertlm,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 1024,
    supportsFunctionCalls: true,
  ),

  // FunctionGemma Flutter Demo (Fine-tuned for example app)
  functionGemma_demo(
    baseUrl:
        'https://huggingface.co/sasha-denisov/functiongemma-flutter-gemma-demo/resolve/main/functiongemma-flutter_q8_ekv1024.task',
    filename: 'functiongemma-flutter_q8_ekv1024.task',
    displayName: 'FunctionGemma Demo (Fine-tuned)',
    size: '284MB',
    licenseUrl:
        'https://huggingface.co/sasha-denisov/functiongemma-flutter-gemma-demo',
    needsAuth: false,
    preferredBackend: PreferredBackend.gpu,
    modelType: ModelType.functionGemma,
    temperature: 1.0,
    topK: 64,
    topP: 0.95,
    maxTokens: 1024,
    supportsFunctionCalls: true,
  ),

  // === BUILT-IN OS AI MODELS ===
  // OS-owned system models via flutter_edge_ai_builtin_ai. fileType builtIn makes
  // core's install pipeline skip the (nonexistent) file — the OS owns the
  // weights, so there is no download. `baseUrl` carries the docs URL only (never
  // fetched). `localModel: true` keeps them visible on all platforms and out of
  // the web/network filters; model_selection_screen.dart platform-filters them
  // so geminiNano shows only on Android and appleFoundationModels only on
  // iOS/macOS. `size: 'system'`.
  geminiNano(
    baseUrl: 'https://developers.google.com/ml-kit/genai/prompt/android',
    filename: 'gemini-nano',
    displayName: 'Gemini Nano (Built-in, Android)',
    size: 'system',
    licenseUrl: 'https://developers.google.com/ml-kit/genai',
    needsAuth: false,
    localModel: true,
    preferredBackend: PreferredBackend.cpu,
    modelType: ModelType.general,
    fileType: ModelFileType.builtIn,
    temperature: 0.2,
    topK: 16,
    topP: 0.95,
    supportImage: true,
    maxTokens: 4096,
    supportsFunctionCalls: true,
  ),
  appleFoundationModels(
    baseUrl: 'https://developer.apple.com/documentation/foundationmodels',
    filename: 'apple-foundation-models',
    displayName: 'Apple Foundation Models (Built-in, iOS/macOS)',
    size: 'system',
    licenseUrl: 'https://developer.apple.com/documentation/foundationmodels',
    needsAuth: false,
    localModel: true,
    preferredBackend: PreferredBackend.cpu,
    modelType: ModelType.general,
    fileType: ModelFileType.builtIn,
    temperature: 0.2,
    topK: 16,
    topP: 0.95,
    supportImage: true,
    maxTokens: 4096,
    supportsFunctionCalls: true,
  );

  // Define fields for the enum
  final String baseUrl;
  final String? webUrl;
  final String? desktopUrl;

  /// Hugging Face repo for the one-call `installModel(...).fromHuggingFace(repo)`
  /// path: the resolver fetches the repo's `litertlm_manifest.json`, picks the
  /// revision-pinned variant and returns the runtime defaults, so none of the
  /// url/filename/backend fields above are consulted.
  ///
  /// Two conditions, not one. The repo must ship a manifest — 5 of the 42 repos
  /// this catalogue references do — AND the entry must have been run on the
  /// manifest's own defaults, because those defaults WIN here: passing
  /// `maxTokens`/`preferredBackend` as null is what lets them through, so a
  /// manifest saying `default_backend: cpu` silently moves an entry off gpu.
  ///
  /// That is why only LFM2.5-230M carries it today. The other four
  /// manifest-backed repos (SmolLM3-3B, Qwen2-VL-2B, SmolVLM2-500M,
  /// LLaVA-OneVision-0.5B) all declare `default_backend: cpu` against a
  /// catalogue that runs them on gpu — plausibly correct, since each carries
  /// `known_issues`, but it is a behaviour change nobody has measured. They keep
  /// [baseUrl] and `fromNetwork` until someone does.
  ///
  /// A missing manifest is a resolve failure, not a fallback.
  final String? hfRepo;

  @override
  final String filename;
  @override
  final String displayName;
  @override
  final String size;
  @override
  final String licenseUrl;
  @override
  final bool needsAuth;
  @override
  final bool localModel;
  @override
  final PreferredBackend preferredBackend;
  @override
  final ModelType modelType;
  @override
  final double temperature;
  @override
  final int topK;
  @override
  final double topP;
  // Raw capability flags from the enum literal. The public [supportImage] /
  // [supportAudio] getters below suppress these on web for .litertlm models,
  // where @litert-lm/core@0.17.1 does not expose the Vision/AudioExecutor
  // config yet — so image/audio inputs are silently dropped. Advertising them
  // in the UI would offer a picker that produces no result. Native and web
  // MediaPipe (.task) keep the declared value.
  final bool _supportImageRaw;
  final bool _supportAudioRaw;

  @override
  bool get supportImage =>
      _webLitertlmMultimodalBlocked ? false : _supportImageRaw;

  bool get supportAudio =>
      _webLitertlmMultimodalBlocked ? false : _supportAudioRaw;

  bool get _webLitertlmMultimodalBlocked =>
      kIsWeb && fileType == ModelFileType.litertlm;
  @override
  final int maxTokens;
  @override
  final int? maxNumImages;
  @override
  final bool supportsFunctionCalls;
  final bool isThinking;

  /// Whether this model is a good fit for the Agent Skills demo — it must do
  /// multi-step tool calling reliably, which is more demanding than plain
  /// function calling. Curated (not every `supportsFunctionCalls` model
  /// qualifies) and used to populate the agent screen's model picker.
  final bool agentic;

  final ModelFileType fileType;
  final bool? foregroundDownload;

  // Getter for url - returns platform-specific URL
  @override
  String get url {
    // Desktop platforms require .litertlm format
    if (_isDesktop && desktopUrl != null && desktopUrl!.isNotEmpty) {
      return desktopUrl!;
    }
    // Web platform may have different URL
    if (kIsWeb && webUrl != null && webUrl!.isNotEmpty) {
      return webUrl!;
    }
    return baseUrl;
  }

  // Check if model supports desktop (has .litertlm URL)
  bool get supportsDesktop =>
      (desktopUrl != null && desktopUrl!.isNotEmpty) ||
      baseUrl.endsWith('.litertlm');

  /// Whether this is an OS built-in model (Gemini Nano / Apple Foundation
  /// Models). The OS owns the weights — there is no file to download; the
  /// download screen short-circuits to an instant bundled install +
  /// `BuiltInAi.ensureReady`.
  bool get isBuiltIn => fileType == ModelFileType.builtIn;

  // Constructor for the enum
  const Model({
    required this.baseUrl,
    this.webUrl,
    this.desktopUrl,
    required this.filename,
    required this.displayName,
    required this.size,
    required this.licenseUrl,
    required this.needsAuth,
    this.localModel = false,
    required this.preferredBackend,
    required this.modelType,
    required this.temperature,
    required this.topK,
    required this.topP,
    bool supportImage = false,
    bool supportAudio = false,
    this.maxTokens = 1024,
    this.maxNumImages,
    this.supportsFunctionCalls = false,
    this.isThinking = false,
    this.agentic = false,
    this.fileType = ModelFileType.task,
    this.foregroundDownload,
    this.hfRepo,
  }) : _supportImageRaw = supportImage,
       _supportAudioRaw = supportAudio;

  // BaseModel interface implementation
  @override
  String get name => toString().split('.').last;

  @override
  ModelKind get kind => ModelKind.inference;

  // InferenceModelInterface implementation
  @override
  bool get supportsThinking => isThinking;

  /// Returns size in MB (parsed from size string like '3.1GB' or '500MB')
  int get sizeInMB {
    final sizeStr = size.toUpperCase();
    final numMatch = RegExp(r'(\d+\.?\d*)').firstMatch(sizeStr);
    if (numMatch == null) return 0;
    final num = double.parse(numMatch.group(1)!);
    if (sizeStr.contains('GB')) return (num * 1024).round();
    if (sizeStr.contains('MB')) return num.round();
    return 0;
  }

  /// Whether to use foreground service on Android (for large downloads >500MB)
  /// - Explicit foregroundDownload field takes priority
  /// - Otherwise auto-detect: >500MB = true, else null (auto)
  bool? get foreground => foregroundDownload ?? (sizeInMB > 500 ? true : null);
}
