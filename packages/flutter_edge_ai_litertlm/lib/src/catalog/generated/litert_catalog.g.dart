// GENERATED from model_registry/models/*.yaml by tool/model_registry:
//   cd tool/model_registry && dart run bin/registry.dart generate
// Do not edit: change the registry and generate again. `registry.dart check`
// fails when this file is stale.
// ignore_for_file: camel_case_types, non_constant_identifier_names

part of '../litert_catalog.dart';

/// The LLMs `flutter_edge_ai_litertlm` runs: `.litertlm` files pinned to Hugging Face commits.
abstract final class LiteRtLmModels {
  /// Every model, in one catalog.
  static const catalog = LiteRtCatalog._('flutter_edge_ai_litertlm', all);

  /// Every model.
  static const List<LiteRtLmModel> all = [
    deepseekR1DistillQwen1_5b,
    fastvlm0_5b,
    functiongemma270mFlutterDemo,
    functiongemma270mIt,
    gemma3_1bIt,
    gemma3_270mIt,
    gemma3nE2bIt,
    gemma3nE4bIt,
    gemma4E2bIt,
    gemma4E4bIt,
    lfm2_5_230m,
    llavaOnevision0_5b,
    phi4MiniInstruct,
    phi4MiniReasoning,
    qwen2Vl2b,
    qwen2_5_1_5bInstruct,
    qwen3_0_6b,
    smollm3_3b,
    smolvlm2_500m,
    translategemma4bIt,
  ];

  /// The model with [id], or null.
  static LiteRtLmModel? byId(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// DeepSeek R1 Distill Qwen 1.5B (`deepseek-r1-distill-qwen-1.5b`).
  static const deepseekR1DistillQwen1_5b =
      LiteRtLmDeepseekR1DistillQwen1_5b._();

  /// FastVLM 0.5B (`fastvlm-0.5b`).
  static const fastvlm0_5b = LiteRtLmFastvlm0_5b._();

  /// FunctionGemma 270M (Flutter demo fine-tune) (`functiongemma-270m-flutter-demo`).
  static const functiongemma270mFlutterDemo =
      LiteRtLmFunctiongemma270mFlutterDemo._();

  /// FunctionGemma 270M (`functiongemma-270m-it`).
  static const functiongemma270mIt = LiteRtLmFunctiongemma270mIt._();

  /// Gemma 3 1B (`gemma-3-1b-it`).
  static const gemma3_1bIt = LiteRtLmGemma3_1bIt._();

  /// Gemma 3 270M (`gemma-3-270m-it`).
  static const gemma3_270mIt = LiteRtLmGemma3_270mIt._();

  /// Gemma 3n E2B (`gemma-3n-e2b-it`).
  static const gemma3nE2bIt = LiteRtLmGemma3nE2bIt._();

  /// Gemma 3n E4B (`gemma-3n-e4b-it`).
  static const gemma3nE4bIt = LiteRtLmGemma3nE4bIt._();

  /// Gemma 4 E2B (`gemma-4-e2b-it`).
  static const gemma4E2bIt = LiteRtLmGemma4E2bIt._();

  /// Gemma 4 E4B (`gemma-4-e4b-it`).
  static const gemma4E4bIt = LiteRtLmGemma4E4bIt._();

  /// LFM2.5 230M (`lfm2.5-230m`).
  static const lfm2_5_230m = LiteRtLmLfm2_5_230m._();

  /// LLaVA-OneVision 0.5B (`llava-onevision-0.5b`).
  static const llavaOnevision0_5b = LiteRtLmLlavaOnevision0_5b._();

  /// Phi-4 Mini Instruct (`phi-4-mini-instruct`).
  static const phi4MiniInstruct = LiteRtLmPhi4MiniInstruct._();

  /// Phi-4 Mini Reasoning (`phi-4-mini-reasoning`).
  static const phi4MiniReasoning = LiteRtLmPhi4MiniReasoning._();

  /// Qwen2-VL 2B (`qwen2-vl-2b`).
  static const qwen2Vl2b = LiteRtLmQwen2Vl2b._();

  /// Qwen 2.5 1.5B Instruct (`qwen2.5-1.5b-instruct`).
  static const qwen2_5_1_5bInstruct = LiteRtLmQwen2_5_1_5bInstruct._();

  /// Qwen3 0.6B (`qwen3-0.6b`).
  static const qwen3_0_6b = LiteRtLmQwen3_0_6b._();

  /// SmolLM3 3B (`smollm3-3b`).
  static const smollm3_3b = LiteRtLmSmollm3_3b._();

  /// SmolVLM2 500M (`smolvlm2-500m`).
  static const smolvlm2_500m = LiteRtLmSmolvlm2_500m._();

  /// TranslateGemma 4B (`translategemma-4b-it`).
  static const translategemma4bIt = LiteRtLmTranslategemma4bIt._();
}

/// The embedding models `flutter_edge_ai_litertlm` runs: EmbeddingGemma 2 `.litertlm` bundles, and `.tflite` models with their tokenizers, pinned to Hugging Face commits.
abstract final class LiteRtEmbedders {
  /// Every model, in one catalog.
  static const catalog = LiteRtCatalog._('flutter_edge_ai_litertlm', all);

  /// Every model.
  static const List<LiteRtEmbedderModel> all = [
    embeddinggemma2_740m,
    embeddinggemma2Text270m,
    embeddinggemma2TextVision440m,
    embeddinggemma300m,
    gecko110mEn,
  ];

  /// The model with [id], or null.
  static LiteRtEmbedderModel? byId(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// EmbeddingGemma 2 Text + Vision + Audio 740M (`embeddinggemma-2-740m`).
  static const embeddinggemma2_740m = LiteRtEmbedderEmbeddinggemma2_740m._();

  /// EmbeddingGemma 2 Text 270M (`embeddinggemma-2-text-270m`).
  static const embeddinggemma2Text270m =
      LiteRtEmbedderEmbeddinggemma2Text270m._();

  /// EmbeddingGemma 2 Text + Vision 440M (`embeddinggemma-2-text-vision-440m`).
  static const embeddinggemma2TextVision440m =
      LiteRtEmbedderEmbeddinggemma2TextVision440m._();

  /// EmbeddingGemma 300M (`embeddinggemma-300m`).
  static const embeddinggemma300m = LiteRtEmbedderEmbeddinggemma300m._();

  /// Gecko 110M (English) (`gecko-110m-en`).
  static const gecko110mEn = LiteRtEmbedderGecko110mEn._();
}

/// DeepSeek R1 Distill Qwen 1.5B (`deepseek-r1-distill-qwen-1.5b`), mit.
final class LiteRtLmDeepseekR1DistillQwen1_5b extends LiteRtLmModel {
  const LiteRtLmDeepseekR1DistillQwen1_5b._()
    : super._(
        id: 'deepseek-r1-distill-qwen-1.5b',
        displayName: 'DeepSeek R1 Distill Qwen 1.5B',
        family: 'qwen2.5',
        archClass: 'dense',
        license: 'mit',
        licenseUrl: 'https://opensource.org/license/mit',
        variants: const [_deepseekR1DistillQwen1_5b$q8Ekv4096],
      );

  /// `DeepSeek-R1-Distill-Qwen-1.5B_multi-prefill-seq_q8_ekv4096.litertlm`, 1.83 GB.
  LiteRtLmVariant get q8Ekv4096 => _deepseekR1DistillQwen1_5b$q8Ekv4096;
}

const _deepseekR1DistillQwen1_5b$q8Ekv4096 = LiteRtLmVariant._(
  id: 'deepseek-r1-distill-qwen-1.5b/q8-ekv4096',
  modelId: 'deepseek-r1-distill-qwen-1.5b',
  file: ModelArtifact(
    repo: 'litert-community/DeepSeek-R1-Distill-Qwen-1.5B',
    revision: '9fd875541bb0f277e4b3cefe7d9622c4c1de2fb5',
    path: 'DeepSeek-R1-Distill-Qwen-1.5B_multi-prefill-seq_q8_ekv4096.litertlm',
    sha256: '69b35f01759eed765641ab4af589bbe98131fd2825662a086d9037409b8c1295',
    sizeBytes: 1833451520,
    installFilename:
        'DeepSeek-R1-Distill-Qwen-1.5B_multi-prefill-seq_q8_ekv4096.litertlm',
  ),
  modelType: ModelType.deepSeek,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// FastVLM 0.5B (`fastvlm-0.5b`), apple-amlr.
final class LiteRtLmFastvlm0_5b extends LiteRtLmModel {
  const LiteRtLmFastvlm0_5b._()
    : super._(
        id: 'fastvlm-0.5b',
        displayName: 'FastVLM 0.5B',
        family: 'fastvlm',
        archClass: 'vision-language',
        license: 'apple-amlr',
        licenseUrl: 'https://huggingface.co/litert-community/FastVLM-0.5B',
        variants: const [
          _fastvlm0_5b$generic,
          _fastvlm0_5b$npuSm8750,
          _fastvlm0_5b$npuSm8850,
        ],
      );

  /// `FastVLM-0.5B.litertlm`, 1.16 GB.
  LiteRtLmVariant get generic => _fastvlm0_5b$generic;

  /// `FastVLM-0.5B.qualcomm.sm8750.litertlm`, 943 MB.
  LiteRtLmVariant get npuSm8750 => _fastvlm0_5b$npuSm8750;

  /// `FastVLM-0.5B.qualcomm.sm8850.litertlm`, 942 MB.
  LiteRtLmVariant get npuSm8850 => _fastvlm0_5b$npuSm8850;
}

const _fastvlm0_5b$generic = LiteRtLmVariant._(
  id: 'fastvlm-0.5b/generic',
  modelId: 'fastvlm-0.5b',
  file: ModelArtifact(
    repo: 'litert-community/FastVLM-0.5B',
    revision: '460013246392191f8532e45e518576bb6513eace',
    path: 'FastVLM-0.5B.litertlm',
    sha256: 'ccba1e8bfa0bab78345f5d009fdffd20bd8c907cf39b4bc632e391b0a96f3b18',
    sizeBytes: 1156342768,
    installFilename: 'FastVLM-0.5B.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 2048,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: false,
  ),
  supportsImage: true,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _fastvlm0_5b$npuSm8750 = LiteRtLmVariant._(
  id: 'fastvlm-0.5b/npu-sm8750',
  modelId: 'fastvlm-0.5b',
  file: ModelArtifact(
    repo: 'litert-community/FastVLM-0.5B',
    revision: '460013246392191f8532e45e518576bb6513eace',
    path: 'FastVLM-0.5B.qualcomm.sm8750.litertlm',
    sha256: 'bb3625f0d887927b01a6f8a3444580514b6165e09a8eb1af276cc14ed22d783e',
    sizeBytes: 943226880,
    installFilename: 'FastVLM-0.5B.qualcomm.sm8750.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: true,
    supportAudio: false,
  ),
  supportsImage: true,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
  requiredMaxTokens: 1280,
);

const _fastvlm0_5b$npuSm8850 = LiteRtLmVariant._(
  id: 'fastvlm-0.5b/npu-sm8850',
  modelId: 'fastvlm-0.5b',
  file: ModelArtifact(
    repo: 'litert-community/FastVLM-0.5B',
    revision: '460013246392191f8532e45e518576bb6513eace',
    path: 'FastVLM-0.5B.qualcomm.sm8850.litertlm',
    sha256: '0eb6860d5c3800dc02c86515a54387f0d8289e5096db291ff6e4a993e312b482',
    sizeBytes: 942374912,
    installFilename: 'FastVLM-0.5B.qualcomm.sm8850.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: true,
    supportAudio: false,
  ),
  supportsImage: true,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
  requiredMaxTokens: 1280,
);

/// FunctionGemma 270M (Flutter demo fine-tune) (`functiongemma-270m-flutter-demo`), unspecified.
final class LiteRtLmFunctiongemma270mFlutterDemo extends LiteRtLmModel {
  const LiteRtLmFunctiongemma270mFlutterDemo._()
    : super._(
        id: 'functiongemma-270m-flutter-demo',
        displayName: 'FunctionGemma 270M (Flutter demo fine-tune)',
        family: 'gemma3',
        archClass: 'dense',
        license: 'unspecified',
        licenseUrl:
            'https://huggingface.co/sasha-denisov/functiongemma-flutter-gemma-demo',
        variants: const [_functiongemma270mFlutterDemo$q8Ekv1024],
      );

  /// `functiongemma-flutter_q8_ekv1024.litertlm`, 284 MB.
  LiteRtLmVariant get q8Ekv1024 => _functiongemma270mFlutterDemo$q8Ekv1024;
}

const _functiongemma270mFlutterDemo$q8Ekv1024 = LiteRtLmVariant._(
  id: 'functiongemma-270m-flutter-demo/q8-ekv1024',
  modelId: 'functiongemma-270m-flutter-demo',
  file: ModelArtifact(
    repo: 'sasha-denisov/functiongemma-flutter-gemma-demo',
    revision: '8ec9e7e36db12e8ca040b4b28263fdb793943996',
    path: 'functiongemma-flutter_q8_ekv1024.litertlm',
    sha256: '2afdc6caeb53f389229d1b5a23d5bf503b844ccd76a8d869ce10db3d14bd66f8',
    sizeBytes: 284426240,
    installFilename: 'functiongemma-flutter_q8_ekv1024.litertlm',
  ),
  modelType: ModelType.functionGemma,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// FunctionGemma 270M (`functiongemma-270m-it`), unspecified.
final class LiteRtLmFunctiongemma270mIt extends LiteRtLmModel {
  const LiteRtLmFunctiongemma270mIt._()
    : super._(
        id: 'functiongemma-270m-it',
        displayName: 'FunctionGemma 270M',
        family: 'gemma3',
        archClass: 'dense',
        license: 'unspecified',
        licenseUrl:
            'https://huggingface.co/sasha-denisov/function-gemma-270M-it',
        variants: const [_functiongemma270mIt$generic],
      );

  /// `functiongemma-270M-it.litertlm`, 284 MB.
  LiteRtLmVariant get generic => _functiongemma270mIt$generic;
}

const _functiongemma270mIt$generic = LiteRtLmVariant._(
  id: 'functiongemma-270m-it/generic',
  modelId: 'functiongemma-270m-it',
  file: ModelArtifact(
    repo: 'sasha-denisov/function-gemma-270M-it',
    revision: '5576af584d75618cdf0cd07b5e79c6fd9ac0ace5',
    path: 'functiongemma-270M-it.litertlm',
    sha256: '680fead1cca41a23220c904500a515d06e41f5c66d130aa4a9cc5905ec529a8e',
    sizeBytes: 284426240,
    installFilename: 'functiongemma-270M-it.litertlm',
  ),
  modelType: ModelType.functionGemma,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// Gemma 3 1B (`gemma-3-1b-it`), gemma.
final class LiteRtLmGemma3_1bIt extends LiteRtLmModel {
  const LiteRtLmGemma3_1bIt._()
    : super._(
        id: 'gemma-3-1b-it',
        displayName: 'Gemma 3 1B',
        family: 'gemma3',
        archClass: 'dense',
        license: 'gemma',
        licenseUrl: 'https://ai.google.dev/gemma/terms',
        variants: const [
          _gemma3_1bIt$q4Ekv4096,
          _gemma3_1bIt$npuMt6989,
          _gemma3_1bIt$npuMt6991,
          _gemma3_1bIt$npuMt6993,
          _gemma3_1bIt$npuSm8550,
          _gemma3_1bIt$npuSm8650,
          _gemma3_1bIt$npuSm8750,
          _gemma3_1bIt$npuSm8850,
          _gemma3_1bIt$npuTensorG5,
          _gemma3_1bIt$npuTensorG6,
        ],
      );

  /// `Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm`, 584 MB.
  LiteRtLmVariant get q4Ekv4096 => _gemma3_1bIt$q4Ekv4096;

  /// `Gemma3-1B-IT_q4_ekv1280_mt6989.litertlm`, 1.03 GB.
  LiteRtLmVariant get npuMt6989 => _gemma3_1bIt$npuMt6989;

  /// `Gemma3-1B-IT_q4_ekv1280_mt6991.litertlm`, 1.03 GB.
  LiteRtLmVariant get npuMt6991 => _gemma3_1bIt$npuMt6991;

  /// `Gemma3-1B-IT_q4_ekv1280_mt6993.litertlm`, 1.02 GB.
  LiteRtLmVariant get npuMt6993 => _gemma3_1bIt$npuMt6993;

  /// `Gemma3-1B-IT_q4_ekv1280_sm8550.litertlm`, 690 MB.
  LiteRtLmVariant get npuSm8550 => _gemma3_1bIt$npuSm8550;

  /// `Gemma3-1B-IT_q4_ekv1280_sm8650.litertlm`, 690 MB.
  LiteRtLmVariant get npuSm8650 => _gemma3_1bIt$npuSm8650;

  /// `Gemma3-1B-IT_q4_ekv1280_sm8750.litertlm`, 689 MB.
  LiteRtLmVariant get npuSm8750 => _gemma3_1bIt$npuSm8750;

  /// `Gemma3-1B-IT_q4_ekv1280_sm8850.litertlm`, 694 MB.
  LiteRtLmVariant get npuSm8850 => _gemma3_1bIt$npuSm8850;

  /// `Gemma3-1B-IT_q8_ekv1280_Google_Tensor_G5.litertlm`, 1.68 GB.
  LiteRtLmVariant get npuTensorG5 => _gemma3_1bIt$npuTensorG5;

  /// `Gemma3-1B-IT_q8_ekv1280_Google_Tensor_G6.litertlm`, 2.04 GB.
  LiteRtLmVariant get npuTensorG6 => _gemma3_1bIt$npuTensorG6;
}

const _gemma3_1bIt$q4Ekv4096 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/q4-ekv4096',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    sha256: '1325ae366d31950f137c9c357b9fa89448b176d76998180c08ceaca78bba98be',
    sizeBytes: 584417280,
    installFilename: 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma3_1bIt$npuMt6989 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-mt6989',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q4_ekv1280_mt6989.litertlm',
    sha256: '10b10bb55851448c54840d3730650f6242245828a904d0baa2255ec5c0e8ff89',
    sizeBytes: 1032830976,
    installFilename: 'Gemma3-1B-IT_q4_ekv1280_mt6989.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6989'),
  requiredMaxTokens: 1280,
);

const _gemma3_1bIt$npuMt6991 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-mt6991',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q4_ekv1280_mt6991.litertlm',
    sha256: '4bab56bdc34b38ab5341e578c2c8c9d8a4a88de752b9420c506a383535846faf',
    sizeBytes: 1033814016,
    installFilename: 'Gemma3-1B-IT_q4_ekv1280_mt6991.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
  requiredMaxTokens: 1280,
);

const _gemma3_1bIt$npuMt6993 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-mt6993',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q4_ekv1280_mt6993.litertlm',
    sha256: 'adb161e25d7f3ad753d07f66992a8b88015b662e343c35edd16a0a2914cd8960',
    sizeBytes: 1020411904,
    installFilename: 'Gemma3-1B-IT_q4_ekv1280_mt6993.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
  requiredMaxTokens: 1280,
);

const _gemma3_1bIt$npuSm8550 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-sm8550',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q4_ekv1280_sm8550.litertlm',
    sha256: '29426fd343eaeac9d54d67ca2bf72fce8c1f0cce947757e5e9c8009bcf5e72af',
    sizeBytes: 690143232,
    installFilename: 'Gemma3-1B-IT_q4_ekv1280_sm8550.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
  requiredMaxTokens: 1280,
);

const _gemma3_1bIt$npuSm8650 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-sm8650',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q4_ekv1280_sm8650.litertlm',
    sha256: '85d2ea5199802f913818d53897b3a304bcf983abb993393e6b1749fbdb005552',
    sizeBytes: 690094080,
    installFilename: 'Gemma3-1B-IT_q4_ekv1280_sm8650.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
  requiredMaxTokens: 1280,
);

const _gemma3_1bIt$npuSm8750 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-sm8750',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q4_ekv1280_sm8750.litertlm',
    sha256: '1904ceff9591e7a140df3a672c800e8e7bee8337526484b00f69ccef4fa2d60a',
    sizeBytes: 689291264,
    installFilename: 'Gemma3-1B-IT_q4_ekv1280_sm8750.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
  requiredMaxTokens: 1280,
);

const _gemma3_1bIt$npuSm8850 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-sm8850',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q4_ekv1280_sm8850.litertlm',
    sha256: 'fda5dca0e8c1c6f65ca5625c326ff79920c7eb82625a0c6515ae4f5711957b1f',
    sizeBytes: 693747712,
    installFilename: 'Gemma3-1B-IT_q4_ekv1280_sm8850.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
  requiredMaxTokens: 1280,
);

const _gemma3_1bIt$npuTensorG5 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-tensor-g5',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q8_ekv1280_Google_Tensor_G5.litertlm',
    sha256: '1ed29548b302764ce32ebf03d7df8fff943218b76d14230e97ee4bd0224cd8d1',
    sizeBytes: 1678542365,
    installFilename: 'Gemma3-1B-IT_q8_ekv1280_Google_Tensor_G5.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
  requiredMaxTokens: 1280,
);

const _gemma3_1bIt$npuTensorG6 = LiteRtLmVariant._(
  id: 'gemma-3-1b-it/npu-tensor-g6',
  modelId: 'gemma-3-1b-it',
  file: ModelArtifact(
    repo: 'litert-community/Gemma3-1B-IT',
    revision: 'd448835d84411a08f577e25f3afebe528402d73b',
    path: 'Gemma3-1B-IT_q8_ekv1280_Google_Tensor_G6.litertlm',
    sha256: 'f34684a6db0799bdcf6ed0331aca4e98756f153e4371f3872b80c1efc4bc9e36',
    sizeBytes: 2043971366,
    installFilename: 'Gemma3-1B-IT_q8_ekv1280_Google_Tensor_G6.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1280,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
  requiredMaxTokens: 1280,
);

/// Gemma 3 270M (`gemma-3-270m-it`), gemma.
final class LiteRtLmGemma3_270mIt extends LiteRtLmModel {
  const LiteRtLmGemma3_270mIt._()
    : super._(
        id: 'gemma-3-270m-it',
        displayName: 'Gemma 3 270M',
        family: 'gemma3',
        archClass: 'dense',
        license: 'gemma',
        licenseUrl: 'https://ai.google.dev/gemma/terms',
        variants: const [
          _gemma3_270mIt$q8,
          _gemma3_270mIt$npuMt6991,
          _gemma3_270mIt$npuMt6993,
          _gemma3_270mIt$npuSm8550,
          _gemma3_270mIt$npuSm8650,
          _gemma3_270mIt$npuSm8750,
          _gemma3_270mIt$npuSm8850,
        ],
      );

  /// `gemma3-270m-it-q8.litertlm`, 304 MB.
  LiteRtLmVariant get q8 => _gemma3_270mIt$q8;

  /// `gemma3-270m-it-q8.mediatek.mt6991.litertlm`, 554 MB.
  LiteRtLmVariant get npuMt6991 => _gemma3_270mIt$npuMt6991;

  /// `gemma3-270m-it-q8.mediatek.mt6993.litertlm`, 555 MB.
  LiteRtLmVariant get npuMt6993 => _gemma3_270mIt$npuMt6993;

  /// `gemma3-270m-it-q8.qualcomm.sm8550.litertlm`, 462 MB.
  LiteRtLmVariant get npuSm8550 => _gemma3_270mIt$npuSm8550;

  /// `gemma3-270m-it-q8.qualcomm.sm8650.litertlm`, 462 MB.
  LiteRtLmVariant get npuSm8650 => _gemma3_270mIt$npuSm8650;

  /// `gemma3-270m-it-q8.qualcomm.sm8750.litertlm`, 461 MB.
  LiteRtLmVariant get npuSm8750 => _gemma3_270mIt$npuSm8750;

  /// `gemma3-270m-it-q8.qualcomm.sm8850.litertlm`, 463 MB.
  LiteRtLmVariant get npuSm8850 => _gemma3_270mIt$npuSm8850;
}

const _gemma3_270mIt$q8 = LiteRtLmVariant._(
  id: 'gemma-3-270m-it/q8',
  modelId: 'gemma-3-270m-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-3-270m-it',
    revision: '9d2093270fb5aa49a986b49b5779d763dde7b630',
    path: 'gemma3-270m-it-q8.litertlm',
    sha256: '757e9119fa5bd667a2774fb470ac4afcd3190a21c677f8e69a5d6bc908abdd63',
    sizeBytes: 304005120,
    installFilename: 'gemma3-270m-it-q8.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma3_270mIt$npuMt6991 = LiteRtLmVariant._(
  id: 'gemma-3-270m-it/npu-mt6991',
  modelId: 'gemma-3-270m-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-3-270m-it',
    revision: '9d2093270fb5aa49a986b49b5779d763dde7b630',
    path: 'gemma3-270m-it-q8.mediatek.mt6991.litertlm',
    sha256: 'd4d3c01888195cc5b29d9b083eb574b360453964e89cd0d3cf3ea15f5de73df0',
    sizeBytes: 554467328,
    installFilename: 'gemma3-270m-it-q8.mediatek.mt6991.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
  requiredMaxTokens: 4096,
);

const _gemma3_270mIt$npuMt6993 = LiteRtLmVariant._(
  id: 'gemma-3-270m-it/npu-mt6993',
  modelId: 'gemma-3-270m-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-3-270m-it',
    revision: '9d2093270fb5aa49a986b49b5779d763dde7b630',
    path: 'gemma3-270m-it-q8.mediatek.mt6993.litertlm',
    sha256: 'fe85d0bc30f208a7d7d5767e5e3bcba4bbea23ca8da5ccc82a0ca9620554c412',
    sizeBytes: 554663936,
    installFilename: 'gemma3-270m-it-q8.mediatek.mt6993.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
  requiredMaxTokens: 4096,
);

const _gemma3_270mIt$npuSm8550 = LiteRtLmVariant._(
  id: 'gemma-3-270m-it/npu-sm8550',
  modelId: 'gemma-3-270m-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-3-270m-it',
    revision: '9d2093270fb5aa49a986b49b5779d763dde7b630',
    path: 'gemma3-270m-it-q8.qualcomm.sm8550.litertlm',
    sha256: '3de5b6e6affcabae4ba0ee6b8cd0de88e12b54dc2f210102ba57ffb09c093ff1',
    sizeBytes: 461750272,
    installFilename: 'gemma3-270m-it-q8.qualcomm.sm8550.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
  requiredMaxTokens: 4096,
);

const _gemma3_270mIt$npuSm8650 = LiteRtLmVariant._(
  id: 'gemma-3-270m-it/npu-sm8650',
  modelId: 'gemma-3-270m-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-3-270m-it',
    revision: '9d2093270fb5aa49a986b49b5779d763dde7b630',
    path: 'gemma3-270m-it-q8.qualcomm.sm8650.litertlm',
    sha256: '73b7bcfc6cdaf94f143158b089ea9c1c16de62a11ef07b387982820d804a93e9',
    sizeBytes: 461766656,
    installFilename: 'gemma3-270m-it-q8.qualcomm.sm8650.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
  requiredMaxTokens: 4096,
);

const _gemma3_270mIt$npuSm8750 = LiteRtLmVariant._(
  id: 'gemma-3-270m-it/npu-sm8750',
  modelId: 'gemma-3-270m-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-3-270m-it',
    revision: '9d2093270fb5aa49a986b49b5779d763dde7b630',
    path: 'gemma3-270m-it-q8.qualcomm.sm8750.litertlm',
    sha256: 'bfbb6c28112aa4bc8d954fb68c6587fab0cbc228c5e15cae4990eeecf1b652e3',
    sizeBytes: 461340672,
    installFilename: 'gemma3-270m-it-q8.qualcomm.sm8750.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
  requiredMaxTokens: 4096,
);

const _gemma3_270mIt$npuSm8850 = LiteRtLmVariant._(
  id: 'gemma-3-270m-it/npu-sm8850',
  modelId: 'gemma-3-270m-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-3-270m-it',
    revision: '9d2093270fb5aa49a986b49b5779d763dde7b630',
    path: 'gemma3-270m-it-q8.qualcomm.sm8850.litertlm',
    sha256: 'b032a3052dcff6d1b7a45325f5198fb775b97c7e064d97552ddb95712758ab2b',
    sizeBytes: 463011840,
    installFilename: 'gemma3-270m-it-q8.qualcomm.sm8850.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
  requiredMaxTokens: 4096,
);

/// Gemma 3n E2B (`gemma-3n-e2b-it`), gemma.
final class LiteRtLmGemma3nE2bIt extends LiteRtLmModel {
  const LiteRtLmGemma3nE2bIt._()
    : super._(
        id: 'gemma-3n-e2b-it',
        displayName: 'Gemma 3n E2B',
        family: 'gemma3n',
        archClass: 'matformer-ple',
        license: 'gemma',
        licenseUrl: 'https://ai.google.dev/gemma/terms',
        variants: const [
          _gemma3nE2bIt$generic,
          _gemma3nE2bIt$web,
          _gemma3nE2bIt$npuMt6993,
        ],
      );

  /// `gemma-3n-E2B-it-int4.litertlm`, 3.66 GB.
  LiteRtLmVariant get generic => _gemma3nE2bIt$generic;

  /// `gemma-3n-E2B-it-int4-Web.litertlm`, 3.04 GB.
  LiteRtLmVariant get web => _gemma3nE2bIt$web;

  /// `gemma-3n-E2B-it-int4.mediatek.mt6993.litertlm`, 4.33 GB.
  LiteRtLmVariant get npuMt6993 => _gemma3nE2bIt$npuMt6993;
}

const _gemma3nE2bIt$generic = LiteRtLmVariant._(
  id: 'gemma-3n-e2b-it/generic',
  modelId: 'gemma-3n-e2b-it',
  file: ModelArtifact(
    repo: 'google/gemma-3n-E2B-it-litert-lm',
    revision: 'c03b6f60b8da6c5400b6838a2cf26420f80c0a01',
    path: 'gemma-3n-E2B-it-int4.litertlm',
    sha256: '2ed7bc3a0026c93d5b8a4544b352d9d00cd66ff0bac3ef6a20ac3d2cba4010d6',
    sizeBytes: 3655827456,
    installFilename: 'gemma-3n-E2B-it-int4.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma3nE2bIt$web = LiteRtLmVariant._(
  id: 'gemma-3n-e2b-it/web',
  modelId: 'gemma-3n-e2b-it',
  file: ModelArtifact(
    repo: 'google/gemma-3n-E2B-it-litert-lm',
    revision: 'c03b6f60b8da6c5400b6838a2cf26420f80c0a01',
    path: 'gemma-3n-E2B-it-int4-Web.litertlm',
    sha256: 'b6c8e1081ec80730f14473a5ece941b48da5d8e2a80c97c2963da153f3eff3d2',
    sizeBytes: 3038117888,
    installFilename: 'gemma-3n-E2B-it-int4-Web.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: true,
  textBackends: {PreferredBackend.gpu},
);

const _gemma3nE2bIt$npuMt6993 = LiteRtLmVariant._(
  id: 'gemma-3n-e2b-it/npu-mt6993',
  modelId: 'gemma-3n-e2b-it',
  file: ModelArtifact(
    repo: 'google/gemma-3n-E2B-it-litert-lm',
    revision: 'c03b6f60b8da6c5400b6838a2cf26420f80c0a01',
    path: 'gemma-3n-E2B-it-int4.mediatek.mt6993.litertlm',
    sha256: 'ba38d54766a3a51cb977499a852d9839843c496a4f2f16c8b472a2cd52b8ab94',
    sizeBytes: 4330192896,
    installFilename: 'gemma-3n-E2B-it-int4.mediatek.mt6993.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 2048,
    preferredBackend: PreferredBackend.npu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
  requiredMaxTokens: 2048,
);

/// Gemma 3n E4B (`gemma-3n-e4b-it`), gemma.
final class LiteRtLmGemma3nE4bIt extends LiteRtLmModel {
  const LiteRtLmGemma3nE4bIt._()
    : super._(
        id: 'gemma-3n-e4b-it',
        displayName: 'Gemma 3n E4B',
        family: 'gemma3n',
        archClass: 'matformer-ple',
        license: 'gemma',
        licenseUrl: 'https://ai.google.dev/gemma/terms',
        variants: const [_gemma3nE4bIt$generic, _gemma3nE4bIt$web],
      );

  /// `gemma-3n-E4B-it-int4.litertlm`, 4.92 GB.
  LiteRtLmVariant get generic => _gemma3nE4bIt$generic;

  /// `gemma-3n-E4B-it-int4-Web.litertlm`, 4.28 GB.
  LiteRtLmVariant get web => _gemma3nE4bIt$web;
}

const _gemma3nE4bIt$generic = LiteRtLmVariant._(
  id: 'gemma-3n-e4b-it/generic',
  modelId: 'gemma-3n-e4b-it',
  file: ModelArtifact(
    repo: 'google/gemma-3n-E4B-it-litert-lm',
    revision: '297ed75955702dec3503e00c2c2ecbbf475300bc',
    path: 'gemma-3n-E4B-it-int4.litertlm',
    sha256: '2e67a6cd51dfe0f793431e6bd4ed8d029c88e10f52ca0469ad38445e3cd3c1f4',
    sizeBytes: 4919541760,
    installFilename: 'gemma-3n-E4B-it-int4.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: true,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma3nE4bIt$web = LiteRtLmVariant._(
  id: 'gemma-3n-e4b-it/web',
  modelId: 'gemma-3n-e4b-it',
  file: ModelArtifact(
    repo: 'google/gemma-3n-E4B-it-litert-lm',
    revision: '297ed75955702dec3503e00c2c2ecbbf475300bc',
    path: 'gemma-3n-E4B-it-int4-Web.litertlm',
    sha256: '63730ba3225a23a90d3292d89fdeff1a7537cedeb72aa687de9a35732d057e52',
    sizeBytes: 4275044352,
    installFilename: 'gemma-3n-E4B-it-int4-Web.litertlm',
    gated: true,
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: false,
  isWebBundle: true,
  textBackends: {PreferredBackend.gpu},
);

/// Gemma 4 E2B (`gemma-4-e2b-it`), apache-2.0.
final class LiteRtLmGemma4E2bIt extends LiteRtLmModel {
  const LiteRtLmGemma4E2bIt._()
    : super._(
        id: 'gemma-4-e2b-it',
        displayName: 'Gemma 4 E2B',
        family: 'gemma4',
        archClass: 'matformer-ple',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [
          _gemma4E2bIt$generic,
          _gemma4E2bIt$gpu,
          _gemma4E2bIt$web,
          _gemma4E2bIt$npuTensorG5,
          _gemma4E2bIt$npuTensorG6,
          _gemma4E2bIt$npuLnl,
          _gemma4E2bIt$npuPtl,
          _gemma4E2bIt$npuQcs8275,
          _gemma4E2bIt$npuSm8750,
        ],
      );

  /// `gemma-4-E2B-it.litertlm`, 2.59 GB.
  LiteRtLmVariant get generic => _gemma4E2bIt$generic;

  /// `gemma-4-E2B-it-gpu.litertlm`, 2.01 GB.
  LiteRtLmVariant get gpu => _gemma4E2bIt$gpu;

  /// `gemma-4-E2B-it-web.litertlm`, 2.01 GB.
  LiteRtLmVariant get web => _gemma4E2bIt$web;

  /// `gemma-4-E2B-it_Google_Tensor_G5.litertlm`, 3.11 GB.
  LiteRtLmVariant get npuTensorG5 => _gemma4E2bIt$npuTensorG5;

  /// `gemma-4-E2B-it_Google_Tensor_G6.litertlm`, 3.31 GB.
  LiteRtLmVariant get npuTensorG6 => _gemma4E2bIt$npuTensorG6;

  /// `gemma-4-E2B-it_intel_LNL.litertlm`, 2.96 GB.
  LiteRtLmVariant get npuLnl => _gemma4E2bIt$npuLnl;

  /// `gemma-4-E2B-it_intel_PTL.litertlm`, 2.95 GB.
  LiteRtLmVariant get npuPtl => _gemma4E2bIt$npuPtl;

  /// `gemma-4-E2B-it_qualcomm_qcs8275.litertlm`, 3.29 GB.
  LiteRtLmVariant get npuQcs8275 => _gemma4E2bIt$npuQcs8275;

  /// `gemma-4-E2B-it_qualcomm_sm8750.litertlm`, 3.02 GB.
  LiteRtLmVariant get npuSm8750 => _gemma4E2bIt$npuSm8750;
}

const _gemma4E2bIt$generic = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/generic',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it.litertlm',
    sha256: '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    sizeBytes: 2588147712,
    installFilename: 'gemma-4-E2B-it.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma4E2bIt$gpu = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/gpu',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it-gpu.litertlm',
    sha256: 'a53a59001894c58e6bdb5b9b227709f91a2e3e556baa7d85acf9c55402ba5cf5',
    sizeBytes: 2008432640,
    installFilename: 'gemma-4-E2B-it-gpu.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma4E2bIt$web = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/web',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it-web.litertlm',
    sha256: '3a08e8d94e23b814ae5414469c370c503813949acb8ceaa17e4ebf8a35af35b5',
    sizeBytes: 2008432640,
    installFilename: 'gemma-4-E2B-it-web.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: true,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma4E2bIt$npuTensorG5 = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/npu-tensor-g5',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it_Google_Tensor_G5.litertlm',
    sha256: 'af1082986639ecde7db95d91be6fe54f8b6b458104734c5bafc204e69d6852dc',
    sizeBytes: 3113545589,
    installFilename: 'gemma-4-E2B-it_Google_Tensor_G5.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
  requiredMaxTokens: 4096,
);

const _gemma4E2bIt$npuTensorG6 = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/npu-tensor-g6',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it_Google_Tensor_G6.litertlm',
    sha256: 'f86c7c19c736e9307267946edef58b0a45494a9127036d54d90dd6b7617c95b7',
    sizeBytes: 3313938293,
    installFilename: 'gemma-4-E2B-it_Google_Tensor_G6.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.npu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
  requiredMaxTokens: 4096,
);

const _gemma4E2bIt$npuLnl = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/npu-lnl',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it_intel_LNL.litertlm',
    sha256: 'dacc900381bdc837696fc5deb1f3b7dbfe0854295dc3934564e1841086ab0383',
    sizeBytes: 2960506880,
    installFilename: 'gemma-4-E2B-it_intel_LNL.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'LNL'),
  requiredMaxTokens: 4096,
);

const _gemma4E2bIt$npuPtl = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/npu-ptl',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it_intel_PTL.litertlm',
    sha256: '8c0877f721ff0c057a007b330bbf9f6ec4d0278e730f88db95f2252372c701e8',
    sizeBytes: 2948333568,
    installFilename: 'gemma-4-E2B-it_intel_PTL.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL'),
  requiredMaxTokens: 4096,
);

const _gemma4E2bIt$npuQcs8275 = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/npu-qcs8275',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it_qualcomm_qcs8275.litertlm',
    sha256: 'ebc103e548e76a34b8114a1dc1dd6d33a893c38add108d8bae8165b51f320f02',
    sizeBytes: 3294593024,
    installFilename: 'gemma-4-E2B-it_qualcomm_qcs8275.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'QCS8275'),
  requiredMaxTokens: 4096,
);

const _gemma4E2bIt$npuSm8750 = LiteRtLmVariant._(
  id: 'gemma-4-e2b-it/npu-sm8750',
  modelId: 'gemma-4-e2b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E2B-it-litert-lm',
    revision: 'b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1',
    path: 'gemma-4-E2B-it_qualcomm_sm8750.litertlm',
    sha256: '41dd675fbe735b6029012b5576a5716bac614fd8156de0128db4c9dff3cebd4e',
    sizeBytes: 3016294400,
    installFilename: 'gemma-4-E2B-it_qualcomm_sm8750.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
  requiredMaxTokens: 4096,
);

/// Gemma 4 E4B (`gemma-4-e4b-it`), apache-2.0.
final class LiteRtLmGemma4E4bIt extends LiteRtLmModel {
  const LiteRtLmGemma4E4bIt._()
    : super._(
        id: 'gemma-4-e4b-it',
        displayName: 'Gemma 4 E4B',
        family: 'gemma4',
        archClass: 'matformer-ple',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [
          _gemma4E4bIt$generic,
          _gemma4E4bIt$gpu,
          _gemma4E4bIt$web,
        ],
      );

  /// `gemma-4-E4B-it.litertlm`, 3.66 GB.
  LiteRtLmVariant get generic => _gemma4E4bIt$generic;

  /// `gemma-4-E4B-it-gpu.litertlm`, 2.97 GB.
  LiteRtLmVariant get gpu => _gemma4E4bIt$gpu;

  /// `gemma-4-E4B-it-web.litertlm`, 2.97 GB.
  LiteRtLmVariant get web => _gemma4E4bIt$web;
}

const _gemma4E4bIt$generic = LiteRtLmVariant._(
  id: 'gemma-4-e4b-it/generic',
  modelId: 'gemma-4-e4b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E4B-it-litert-lm',
    revision: '2eee7ac325f20eb8c9ac1d0e972f7c84663062da',
    path: 'gemma-4-E4B-it.litertlm',
    sha256: '0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0',
    sizeBytes: 3659530240,
    installFilename: 'gemma-4-E4B-it.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma4E4bIt$gpu = LiteRtLmVariant._(
  id: 'gemma-4-e4b-it/gpu',
  modelId: 'gemma-4-e4b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E4B-it-litert-lm',
    revision: '2eee7ac325f20eb8c9ac1d0e972f7c84663062da',
    path: 'gemma-4-E4B-it-gpu.litertlm',
    sha256: '4912bb5a9c30993c51a7711f763212077458529312175df0573a78323a2bb7ff',
    sizeBytes: 2969059328,
    installFilename: 'gemma-4-E4B-it-gpu.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: true,
  ),
  supportsImage: true,
  supportsAudio: true,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _gemma4E4bIt$web = LiteRtLmVariant._(
  id: 'gemma-4-e4b-it/web',
  modelId: 'gemma-4-e4b-it',
  file: ModelArtifact(
    repo: 'litert-community/gemma-4-E4B-it-litert-lm',
    revision: '2eee7ac325f20eb8c9ac1d0e972f7c84663062da',
    path: 'gemma-4-E4B-it-web.litertlm',
    sha256: '3904d826d5dddd25ea173e85204caec09e68ba038116e9b992b69cbdc94f57a0',
    sizeBytes: 2969059328,
    installFilename: 'gemma-4-E4B-it-web.litertlm',
  ),
  modelType: ModelType.gemma4,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: true,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// LFM2.5 230M (`lfm2.5-230m`), other.
final class LiteRtLmLfm2_5_230m extends LiteRtLmModel {
  const LiteRtLmLfm2_5_230m._()
    : super._(
        id: 'lfm2.5-230m',
        displayName: 'LFM2.5 230M',
        family: 'lfm2',
        archClass: 'conv-attention-hybrid',
        license: 'other',
        licenseUrl:
            'https://huggingface.co/LiquidAI/LFM2.5-230M/blob/main/LICENSE',
        variants: const [_lfm2_5_230m$int4, _lfm2_5_230m$int8],
      );

  /// `LFM2.5-230M_int4.litertlm`, 177 MB.
  LiteRtLmVariant get int4 => _lfm2_5_230m$int4;

  /// `LFM2.5-230M_int8.litertlm`, 266 MB.
  LiteRtLmVariant get int8 => _lfm2_5_230m$int8;
}

const _lfm2_5_230m$int4 = LiteRtLmVariant._(
  id: 'lfm2.5-230m/int4',
  modelId: 'lfm2.5-230m',
  file: ModelArtifact(
    repo: 'litert-community/LFM2.5-230M',
    revision: '58f0603b4576964013c87bbd75124a358d48cd44',
    path: 'LFM2.5-230M_int4.litertlm',
    sha256: 'c9065e28358a1f2f61a9c0d86172d6d16254d0f9097a519e82fc1346c17f9c62',
    sizeBytes: 176756720,
    installFilename: 'LFM2.5-230M_int4.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _lfm2_5_230m$int8 = LiteRtLmVariant._(
  id: 'lfm2.5-230m/int8',
  modelId: 'lfm2.5-230m',
  file: ModelArtifact(
    repo: 'litert-community/LFM2.5-230M',
    revision: '58f0603b4576964013c87bbd75124a358d48cd44',
    path: 'LFM2.5-230M_int8.litertlm',
    sha256: '3c891cb3ab299385b11d04b45b32593a2002f9a45abeb30b4be2385c09878179',
    sizeBytes: 266053344,
    installFilename: 'LFM2.5-230M_int8.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// LLaVA-OneVision 0.5B (`llava-onevision-0.5b`), apache-2.0.
final class LiteRtLmLlavaOnevision0_5b extends LiteRtLmModel {
  const LiteRtLmLlavaOnevision0_5b._()
    : super._(
        id: 'llava-onevision-0.5b',
        displayName: 'LLaVA-OneVision 0.5B',
        family: 'llava',
        archClass: 'vision-language',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [_llavaOnevision0_5b$generic],
      );

  /// `LLaVA-OneVision-0.5B.litertlm`, 829 MB.
  LiteRtLmVariant get generic => _llavaOnevision0_5b$generic;
}

const _llavaOnevision0_5b$generic = LiteRtLmVariant._(
  id: 'llava-onevision-0.5b/generic',
  modelId: 'llava-onevision-0.5b',
  file: ModelArtifact(
    repo: 'litert-community/LLaVA-OneVision-0.5B',
    revision: 'f7e470a3f4c9de3b980fbd845358eaa958c70c67',
    path: 'LLaVA-OneVision-0.5B.litertlm',
    sha256: '7f7cd7ae3d2ae435a1f69651de02a9d51e916be60fdfef5cadc721725310971a',
    sizeBytes: 828590400,
    installFilename: 'LLaVA-OneVision-0.5B.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: false,
  ),
  supportsImage: true,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// Phi-4 Mini Instruct (`phi-4-mini-instruct`), mit.
final class LiteRtLmPhi4MiniInstruct extends LiteRtLmModel {
  const LiteRtLmPhi4MiniInstruct._()
    : super._(
        id: 'phi-4-mini-instruct',
        displayName: 'Phi-4 Mini Instruct',
        family: 'phi4',
        archClass: 'dense',
        license: 'mit',
        licenseUrl: 'https://opensource.org/license/mit',
        variants: const [_phi4MiniInstruct$q8Ekv4096],
      );

  /// `Phi-4-mini-instruct_multi-prefill-seq_q8_ekv4096.litertlm`, 3.91 GB.
  LiteRtLmVariant get q8Ekv4096 => _phi4MiniInstruct$q8Ekv4096;
}

const _phi4MiniInstruct$q8Ekv4096 = LiteRtLmVariant._(
  id: 'phi-4-mini-instruct/q8-ekv4096',
  modelId: 'phi-4-mini-instruct',
  file: ModelArtifact(
    repo: 'litert-community/Phi-4-mini-instruct',
    revision: 'edafb1440931b748aeb7d0ae767109903d3d6d8d',
    path: 'Phi-4-mini-instruct_multi-prefill-seq_q8_ekv4096.litertlm',
    sha256: '7764d4deb53800578307be33039476b38a6c370fff71bedb3c0552563e23ab02',
    sizeBytes: 3910090752,
    installFilename:
        'Phi-4-mini-instruct_multi-prefill-seq_q8_ekv4096.litertlm',
  ),
  modelType: ModelType.phi,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// Phi-4 Mini Reasoning (`phi-4-mini-reasoning`), mit.
final class LiteRtLmPhi4MiniReasoning extends LiteRtLmModel {
  const LiteRtLmPhi4MiniReasoning._()
    : super._(
        id: 'phi-4-mini-reasoning',
        displayName: 'Phi-4 Mini Reasoning',
        family: 'phi4',
        archClass: 'dense',
        license: 'mit',
        licenseUrl: 'https://opensource.org/license/mit',
        variants: const [_phi4MiniReasoning$generic],
      );

  /// `model.litertlm`, 2.78 GB.
  LiteRtLmVariant get generic => _phi4MiniReasoning$generic;
}

const _phi4MiniReasoning$generic = LiteRtLmVariant._(
  id: 'phi-4-mini-reasoning/generic',
  modelId: 'phi-4-mini-reasoning',
  file: ModelArtifact(
    repo: 'litert-community/Phi-4-mini-reasoning',
    revision: '62a183af7b3d3d46f8df17dde9bf8381988bbf68',
    path: 'model.litertlm',
    sha256: 'd507262ca3d01d93d59c573a82e6f2eeb3aec21d9a67c31fb4c0f93d17225b8f',
    sizeBytes: 2784187376,
    installFilename: 'phi-4-mini-reasoning.litertlm',
  ),
  modelType: ModelType.phi,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// Qwen2-VL 2B (`qwen2-vl-2b`), apache-2.0.
final class LiteRtLmQwen2Vl2b extends LiteRtLmModel {
  const LiteRtLmQwen2Vl2b._()
    : super._(
        id: 'qwen2-vl-2b',
        displayName: 'Qwen2-VL 2B',
        family: 'qwen2-vl',
        archClass: 'vision-language',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [_qwen2Vl2b$generic],
      );

  /// `Qwen2-VL-2B.litertlm`, 1.78 GB.
  LiteRtLmVariant get generic => _qwen2Vl2b$generic;
}

const _qwen2Vl2b$generic = LiteRtLmVariant._(
  id: 'qwen2-vl-2b/generic',
  modelId: 'qwen2-vl-2b',
  file: ModelArtifact(
    repo: 'litert-community/Qwen2-VL-2B',
    revision: '98723e7d59acce5f56befd5c25164510e1fe790a',
    path: 'Qwen2-VL-2B.litertlm',
    sha256: 'cf481776bcb16fe539a38c924a67fc213bb5ee55e6fa600729f060e64849066b',
    sizeBytes: 1783424544,
    installFilename: 'Qwen2-VL-2B.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: false,
  ),
  supportsImage: true,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// Qwen 2.5 1.5B Instruct (`qwen2.5-1.5b-instruct`), apache-2.0.
final class LiteRtLmQwen2_5_1_5bInstruct extends LiteRtLmModel {
  const LiteRtLmQwen2_5_1_5bInstruct._()
    : super._(
        id: 'qwen2.5-1.5b-instruct',
        displayName: 'Qwen 2.5 1.5B Instruct',
        family: 'qwen2.5',
        archClass: 'dense',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [
          _qwen2_5_1_5bInstruct$q8Ekv4096,
          _qwen2_5_1_5bInstruct$f32Ekv4096,
        ],
      );

  /// `Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm`, 1.60 GB.
  LiteRtLmVariant get q8Ekv4096 => _qwen2_5_1_5bInstruct$q8Ekv4096;

  /// `Qwen2.5-1.5B-Instruct_multi-prefill-seq_f32_ekv4096.litertlm`, 6.18 GB.
  LiteRtLmVariant get f32Ekv4096 => _qwen2_5_1_5bInstruct$f32Ekv4096;
}

const _qwen2_5_1_5bInstruct$q8Ekv4096 = LiteRtLmVariant._(
  id: 'qwen2.5-1.5b-instruct/q8-ekv4096',
  modelId: 'qwen2.5-1.5b-instruct',
  file: ModelArtifact(
    repo: 'litert-community/Qwen2.5-1.5B-Instruct',
    revision: '5068b3fd9788a4ed5633dc868687f778143b73f3',
    path: 'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
    sha256: 'c4a9b7289365ab80fe599b844b77ad253eb3c53fb0e5d963d699146a6f01255e',
    sizeBytes: 1597922856,
    installFilename:
        'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
  ),
  modelType: ModelType.qwen,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _qwen2_5_1_5bInstruct$f32Ekv4096 = LiteRtLmVariant._(
  id: 'qwen2.5-1.5b-instruct/f32-ekv4096',
  modelId: 'qwen2.5-1.5b-instruct',
  file: ModelArtifact(
    repo: 'litert-community/Qwen2.5-1.5B-Instruct',
    revision: '5068b3fd9788a4ed5633dc868687f778143b73f3',
    path: 'Qwen2.5-1.5B-Instruct_multi-prefill-seq_f32_ekv4096.litertlm',
    sha256: '708483abb477c10dd8db8cc6b4995bbd9cd2deda5539249a37c218028a669391',
    sizeBytes: 6182436864,
    installFilename:
        'Qwen2.5-1.5B-Instruct_multi-prefill-seq_f32_ekv4096.litertlm',
  ),
  modelType: ModelType.qwen,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// Qwen3 0.6B (`qwen3-0.6b`), apache-2.0.
final class LiteRtLmQwen3_0_6b extends LiteRtLmModel {
  const LiteRtLmQwen3_0_6b._()
    : super._(
        id: 'qwen3-0.6b',
        displayName: 'Qwen3 0.6B',
        family: 'qwen3',
        archClass: 'dense',
        license: 'apache-2.0',
        licenseUrl: 'https://huggingface.co/Qwen/Qwen3-0.6B/blob/main/LICENSE',
        variants: const [
          _qwen3_0_6b$dynamicInt4,
          _qwen3_0_6b$mixedInt4,
          _qwen3_0_6b$npuMt6993,
        ],
      );

  /// `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`, 345 MB.
  LiteRtLmVariant get dynamicInt4 => _qwen3_0_6b$dynamicInt4;

  /// `qwen3_0_6b_mixed_int4.litertlm`, 498 MB.
  LiteRtLmVariant get mixedInt4 => _qwen3_0_6b$mixedInt4;

  /// `Qwen3-0.6B.mediatek.mt6993.litertlm`, 1.20 GB.
  LiteRtLmVariant get npuMt6993 => _qwen3_0_6b$npuMt6993;
}

const _qwen3_0_6b$dynamicInt4 = LiteRtLmVariant._(
  id: 'qwen3-0.6b/dynamic-int4',
  modelId: 'qwen3-0.6b',
  file: ModelArtifact(
    repo: 'litert-community/Qwen3-0.6B',
    revision: 'e6687177e00897731e7716267eebd4eba0dde7c2',
    path: 'Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm',
    sha256: '03e7da1eb1108b50dffaa9bb52cc7bcbad2eb0c66ca990267f480c1e545d2856',
    sizeBytes: 344671744,
    installFilename: 'Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm',
  ),
  modelType: ModelType.qwen3,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _qwen3_0_6b$mixedInt4 = LiteRtLmVariant._(
  id: 'qwen3-0.6b/mixed-int4',
  modelId: 'qwen3-0.6b',
  file: ModelArtifact(
    repo: 'litert-community/Qwen3-0.6B',
    revision: 'e6687177e00897731e7716267eebd4eba0dde7c2',
    path: 'qwen3_0_6b_mixed_int4.litertlm',
    sha256: '7900eb4e7362d88c58782c6f9999bb7a129e03544aa98b8f338ea0cc5d8c22c1',
    sizeBytes: 497516544,
    installFilename: 'qwen3_0_6b_mixed_int4.litertlm',
  ),
  modelType: ModelType.qwen3,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _qwen3_0_6b$npuMt6993 = LiteRtLmVariant._(
  id: 'qwen3-0.6b/npu-mt6993',
  modelId: 'qwen3-0.6b',
  file: ModelArtifact(
    repo: 'litert-community/Qwen3-0.6B',
    revision: 'e6687177e00897731e7716267eebd4eba0dde7c2',
    path: 'Qwen3-0.6B.mediatek.mt6993.litertlm',
    sha256: 'cc87c8a3df6eb680266a385c22fc3e867824495ff676583716ebe77e6ddd6c97',
    sizeBytes: 1202913280,
    installFilename: 'Qwen3-0.6B.mediatek.mt6993.litertlm',
  ),
  modelType: ModelType.qwen3,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.npu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: true,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.npu},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
  requiredMaxTokens: 4096,
);

/// SmolLM3 3B (`smollm3-3b`), apache-2.0.
final class LiteRtLmSmollm3_3b extends LiteRtLmModel {
  const LiteRtLmSmollm3_3b._()
    : super._(
        id: 'smollm3-3b',
        displayName: 'SmolLM3 3B',
        family: 'smollm3',
        archClass: 'dense',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [_smollm3_3b$q4Block32Ekv4096, _smollm3_3b$standard],
      );

  /// `SmolLM3-3B_q4_block32_ekv4096.litertlm`, 2.00 GB.
  LiteRtLmVariant get q4Block32Ekv4096 => _smollm3_3b$q4Block32Ekv4096;

  /// `SmolLM3-3B.litertlm`, 3.13 GB.
  LiteRtLmVariant get standard => _smollm3_3b$standard;
}

const _smollm3_3b$q4Block32Ekv4096 = LiteRtLmVariant._(
  id: 'smollm3-3b/q4-block32-ekv4096',
  modelId: 'smollm3-3b',
  file: ModelArtifact(
    repo: 'litert-community/SmolLM3-3B',
    revision: '7621a4f099a00b0518e0a6e7c5628af08ab4184e',
    path: 'SmolLM3-3B_q4_block32_ekv4096.litertlm',
    sha256: 'bdd7eb05b6764fb5a5173bdbdd59354a26f66e4c20b040f0d3da3532071d18f6',
    sizeBytes: 2004633520,
    installFilename: 'SmolLM3-3B_q4_block32_ekv4096.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

const _smollm3_3b$standard = LiteRtLmVariant._(
  id: 'smollm3-3b/standard',
  modelId: 'smollm3-3b',
  file: ModelArtifact(
    repo: 'litert-community/SmolLM3-3B',
    revision: '7621a4f099a00b0518e0a6e7c5628af08ab4184e',
    path: 'SmolLM3-3B.litertlm',
    sha256: 'c1c6c635194745456d03ba3a851b9ebf3a2714218ce35d930d9eb93f7cf97e20',
    sizeBytes: 3125204208,
    installFilename: 'SmolLM3-3B.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: true,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// SmolVLM2 500M (`smolvlm2-500m`), apache-2.0.
final class LiteRtLmSmolvlm2_500m extends LiteRtLmModel {
  const LiteRtLmSmolvlm2_500m._()
    : super._(
        id: 'smolvlm2-500m',
        displayName: 'SmolVLM2 500M',
        family: 'smolvlm',
        archClass: 'vision-language',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [_smolvlm2_500m$generic],
      );

  /// `SmolVLM2-500M.litertlm`, 361 MB.
  LiteRtLmVariant get generic => _smolvlm2_500m$generic;
}

const _smolvlm2_500m$generic = LiteRtLmVariant._(
  id: 'smolvlm2-500m/generic',
  modelId: 'smolvlm2-500m',
  file: ModelArtifact(
    repo: 'litert-community/SmolVLM2-500M',
    revision: '78a25681a0811230bfa3079504a717e9a4a139d1',
    path: 'SmolVLM2-500M.litertlm',
    sha256: 'b808b328d845a600a33c5295f93d9217487317bd334dbc91b2a8d50e26e60ad0',
    sizeBytes: 360822960,
    installFilename: 'SmolVLM2-500M.litertlm',
  ),
  modelType: ModelType.general,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: false,
  ),
  supportsImage: true,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.gpu, PreferredBackend.cpu},
);

/// TranslateGemma 4B (`translategemma-4b-it`), other.
final class LiteRtLmTranslategemma4bIt extends LiteRtLmModel {
  const LiteRtLmTranslategemma4bIt._()
    : super._(
        id: 'translategemma-4b-it',
        displayName: 'TranslateGemma 4B',
        family: 'gemma3',
        archClass: 'dense',
        license: 'other',
        licenseUrl:
            'https://huggingface.co/barakplasma/translategemma-4b-it-android-task-quantized',
        variants: const [
          _translategemma4bIt$int4,
          _translategemma4bIt$int8,
          _translategemma4bIt$int4Multimodal,
        ],
      );

  /// `artifacts/int4-generic/translategemma-4b-it-int4-generic.litertlm`, 2.01 GB.
  LiteRtLmVariant get int4 => _translategemma4bIt$int4;

  /// `artifacts/dynamic_int8-generic/translategemma-4b-it-dynamic_int8-generic.litertlm`, 3.92 GB.
  LiteRtLmVariant get int8 => _translategemma4bIt$int8;

  /// `artifacts/int4-multimodal/translategemma-4b-it-int4-multimodal.litertlm`, 2.76 GB.
  LiteRtLmVariant get int4Multimodal => _translategemma4bIt$int4Multimodal;
}

const _translategemma4bIt$int4 = LiteRtLmVariant._(
  id: 'translategemma-4b-it/int4',
  modelId: 'translategemma-4b-it',
  file: ModelArtifact(
    repo: 'barakplasma/translategemma-4b-it-android-task-quantized',
    revision: 'a45b06a66177e5cbc6d95babe2f89c1df75c0219',
    path: 'artifacts/int4-generic/translategemma-4b-it-int4-generic.litertlm',
    sha256: '94d2edceddeefe94aeb81fa3446f0b392c91e62f187392e049d4f74b2bb2315b',
    sizeBytes: 2011201536,
    installFilename: 'translategemma-4b-it-int4-generic.litertlm',
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.cpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.cpu},
);

const _translategemma4bIt$int8 = LiteRtLmVariant._(
  id: 'translategemma-4b-it/int8',
  modelId: 'translategemma-4b-it',
  file: ModelArtifact(
    repo: 'barakplasma/translategemma-4b-it-android-task-quantized',
    revision: 'a45b06a66177e5cbc6d95babe2f89c1df75c0219',
    path:
        'artifacts/dynamic_int8-generic/translategemma-4b-it-dynamic_int8-generic.litertlm',
    sha256: '6ccc74202695d3079797d1c1b5cc4a9e4a069a53f5a1b6c3e25c8775f295858b',
    sizeBytes: 3920576512,
    installFilename: 'translategemma-4b-it-dynamic_int8-generic.litertlm',
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.cpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.cpu},
);

const _translategemma4bIt$int4Multimodal = LiteRtLmVariant._(
  id: 'translategemma-4b-it/int4-multimodal',
  modelId: 'translategemma-4b-it',
  file: ModelArtifact(
    repo: 'barakplasma/translategemma-4b-it-android-task-quantized',
    revision: 'a45b06a66177e5cbc6d95babe2f89c1df75c0219',
    path:
        'artifacts/int4-multimodal/translategemma-4b-it-int4-multimodal.litertlm',
    sha256: '1bc8e828fbe56dfb503ac033ac84a9eb941d85a9c196803167fa39b35f7fb033',
    sizeBytes: 2757894128,
    installFilename: 'translategemma-4b-it-int4-multimodal.litertlm',
  ),
  modelType: ModelType.gemmaIt,
  runtimeDefaults: ModelRuntimeDefaults(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.cpu,
    supportImage: false,
    supportAudio: false,
  ),
  supportsImage: false,
  supportsAudio: false,
  supportsFunctionCalls: false,
  supportsThinking: false,
  isWebBundle: false,
  textBackends: {PreferredBackend.cpu},
);

/// EmbeddingGemma 2 Text + Vision + Audio 740M (`embeddinggemma-2-740m`), apache-2.0.
final class LiteRtEmbedderEmbeddinggemma2_740m extends LiteRtEmbedderModel {
  const LiteRtEmbedderEmbeddinggemma2_740m._()
    : super._(
        id: 'embeddinggemma-2-740m',
        displayName: 'EmbeddingGemma 2 Text + Vision + Audio 740M',
        family: 'embeddinggemma2',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [
          _embeddinggemma2_740m$generic,
          _embeddinggemma2_740m$npuMt6991,
          _embeddinggemma2_740m$npuMt6993,
          _embeddinggemma2_740m$npuPtl,
          _embeddinggemma2_740m$npuQcs8275,
          _embeddinggemma2_740m$npuSm8550,
          _embeddinggemma2_740m$npuSm8650,
          _embeddinggemma2_740m$npuSm8750,
          _embeddinggemma2_740m$npuSm8850,
          _embeddinggemma2_740m$npuTensorG5,
          _embeddinggemma2_740m$npuTensorG6,
        ],
      );

  /// `embeddinggemma-2-740m.litertlm`, 485 MB.
  LiteRtEmbedderVariant get generic => _embeddinggemma2_740m$generic;

  /// `embeddinggemma-2-740m_MediaTek_MT6991.litertlm`, 895 MB.
  LiteRtEmbedderVariant get npuMt6991 => _embeddinggemma2_740m$npuMt6991;

  /// `embeddinggemma-2-740m_MediaTek_MT6993.litertlm`, 865 MB.
  LiteRtEmbedderVariant get npuMt6993 => _embeddinggemma2_740m$npuMt6993;

  /// `embeddinggemma-2-740m_Intel_PTL.litertlm`, 856 MB.
  LiteRtEmbedderVariant get npuPtl => _embeddinggemma2_740m$npuPtl;

  /// `embeddinggemma-2-740m_Qualcomm_QCS8275.litertlm`, 563 MB.
  LiteRtEmbedderVariant get npuQcs8275 => _embeddinggemma2_740m$npuQcs8275;

  /// `embeddinggemma-2-740m_Qualcomm_SM8550.litertlm`, 563 MB.
  LiteRtEmbedderVariant get npuSm8550 => _embeddinggemma2_740m$npuSm8550;

  /// `embeddinggemma-2-740m_Qualcomm_SM8650.litertlm`, 563 MB.
  LiteRtEmbedderVariant get npuSm8650 => _embeddinggemma2_740m$npuSm8650;

  /// `embeddinggemma-2-740m_Qualcomm_SM8750.litertlm`, 544 MB.
  LiteRtEmbedderVariant get npuSm8750 => _embeddinggemma2_740m$npuSm8750;

  /// `embeddinggemma-2-740m_Qualcomm_SM8850.litertlm`, 559 MB.
  LiteRtEmbedderVariant get npuSm8850 => _embeddinggemma2_740m$npuSm8850;

  /// `embeddinggemma-2-740m_Google_Tensor_G5.litertlm`, 658 MB.
  LiteRtEmbedderVariant get npuTensorG5 => _embeddinggemma2_740m$npuTensorG5;

  /// `embeddinggemma-2-740m_Google_Tensor_G6.litertlm`, 616 MB.
  LiteRtEmbedderVariant get npuTensorG6 => _embeddinggemma2_740m$npuTensorG6;
}

const _embeddinggemma2_740m$generic = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/generic',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m.litertlm',
    sha256: 'e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c',
    sizeBytes: 484622336,
    installFilename: 'embeddinggemma-2-740m__rev-24d962e906c7.litertlm',
  ),
  ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
);

const _embeddinggemma2_740m$npuMt6991 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-mt6991',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_MediaTek_MT6991.litertlm',
    sha256: '99e6a35b824b4f7ad4f7c7f20c59ba380aa90e0b4442aadfee3674230c6c7cca',
    sizeBytes: 895008768,
    installFilename:
        'embeddinggemma-2-740m_MediaTek_MT6991__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6991',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6991-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _embeddinggemma2_740m$npuMt6993 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-mt6993',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_MediaTek_MT6993.litertlm',
    sha256: 'ed2a2554bfb6d7abcafd0e9e36ee2f8d7de82888e7ed0fc52dd144e65b171742',
    sizeBytes: 864681984,
    installFilename:
        'embeddinggemma-2-740m_MediaTek_MT6993__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6993',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6993-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _embeddinggemma2_740m$npuPtl = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-ptl',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_Intel_PTL.litertlm',
    sha256: '7cdcd24f08947aa9ad46d6e4d43caa4ee8b146d3c37d7c51248302b56902ae51',
    sizeBytes: 856410804,
    installFilename:
        'embeddinggemma-2-740m_Intel_PTL__rev-24d962e906c7.litertlm',
  ),
  ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-ptl',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-ptl-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL'),
);

const _embeddinggemma2_740m$npuQcs8275 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-qcs8275',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_Qualcomm_QCS8275.litertlm',
    sha256: '4d99a14e63e01cd2947961a1b4939395ad50d3a101a411e05f8397f4a80dbd80',
    sizeBytes: 562888704,
    installFilename:
        'embeddinggemma-2-740m_Qualcomm_QCS8275__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-qcs8275',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-qcs8275-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'QCS8275'),
);

const _embeddinggemma2_740m$npuSm8550 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-sm8550',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_Qualcomm_SM8550.litertlm',
    sha256: '802686a865fd7350f2ce4b6fa17ce02a411f56b5b508ec2bd8cb7310b2db82e6',
    sizeBytes: 562905088,
    installFilename:
        'embeddinggemma-2-740m_Qualcomm_SM8550__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8550',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8550-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _embeddinggemma2_740m$npuSm8650 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-sm8650',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_Qualcomm_SM8650.litertlm',
    sha256: '3b8a18c6d043b8132c4eda45611296e1ae455ada82cda8b591ec0ca141e041c5',
    sizeBytes: 562659328,
    installFilename:
        'embeddinggemma-2-740m_Qualcomm_SM8650__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8650',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8650-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _embeddinggemma2_740m$npuSm8750 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-sm8750',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_Qualcomm_SM8750.litertlm',
    sha256: 'ac1973c0195dc6e28a621651f2f5e04d35fdc7a7b11cdbbe94f29f5dccb57996',
    sizeBytes: 543522816,
    installFilename:
        'embeddinggemma-2-740m_Qualcomm_SM8750__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8750',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8750-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _embeddinggemma2_740m$npuSm8850 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-sm8850',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_Qualcomm_SM8850.litertlm',
    sha256: '19f6e8db6aa74b116d1c558c862ee131f60ce093576d3c8dd1898f656ca8080b',
    sizeBytes: 559448064,
    installFilename:
        'embeddinggemma-2-740m_Qualcomm_SM8850__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

const _embeddinggemma2_740m$npuTensorG5 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-tensor-g5',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_Google_Tensor_G5.litertlm',
    sha256: '5b53d76c2c7c66d2dc6230ff158ea0033ac5939ac7cfcf827c3a22cdfc742a5e',
    sizeBytes: 657656500,
    installFilename:
        'embeddinggemma-2-740m_Google_Tensor_G5__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g5',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g5-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
);

const _embeddinggemma2_740m$npuTensorG6 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-740m/npu-tensor-g6',
  modelId: 'embeddinggemma-2-740m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-740m-litert-lm',
    revision: '24d962e906c7d332c6428e71c9676855024569e2',
    path: 'embeddinggemma-2-740m_Google_Tensor_G6.litertlm',
    sha256: 'ed0e4f413e705946eda544078d8bf5acf10fe5aee2946451c81919a1f59665e7',
    sizeBytes: 615713460,
    installFilename:
        'embeddinggemma-2-740m_Google_Tensor_G6__rev-24d962e906c7.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g6',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g6-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {
    EmbeddingModality.text,
    EmbeddingModality.image,
    EmbeddingModality.audio,
  },
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
);

/// EmbeddingGemma 2 Text 270M (`embeddinggemma-2-text-270m`), apache-2.0.
final class LiteRtEmbedderEmbeddinggemma2Text270m extends LiteRtEmbedderModel {
  const LiteRtEmbedderEmbeddinggemma2Text270m._()
    : super._(
        id: 'embeddinggemma-2-text-270m',
        displayName: 'EmbeddingGemma 2 Text 270M',
        family: 'embeddinggemma2',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [
          _embeddinggemma2Text270m$generic,
          _embeddinggemma2Text270m$npuMt6991,
          _embeddinggemma2Text270m$npuMt6993,
          _embeddinggemma2Text270m$npuPtl,
          _embeddinggemma2Text270m$npuQcs8275,
          _embeddinggemma2Text270m$npuSm8550,
          _embeddinggemma2Text270m$npuSm8650,
          _embeddinggemma2Text270m$npuSm8750,
          _embeddinggemma2Text270m$npuSm8850,
          _embeddinggemma2Text270m$npuTensorG5,
          _embeddinggemma2Text270m$npuTensorG6,
        ],
      );

  /// `embeddinggemma-2-text-270m.litertlm`, 165 MB.
  LiteRtEmbedderVariant get generic => _embeddinggemma2Text270m$generic;

  /// `embeddinggemma-2-text-270m_MediaTek_MT6991.litertlm`, 416 MB.
  LiteRtEmbedderVariant get npuMt6991 => _embeddinggemma2Text270m$npuMt6991;

  /// `embeddinggemma-2-text-270m_MediaTek_MT6993.litertlm`, 386 MB.
  LiteRtEmbedderVariant get npuMt6993 => _embeddinggemma2Text270m$npuMt6993;

  /// `embeddinggemma-2-text-270m_Intel_PTL.litertlm`, 317 MB.
  LiteRtEmbedderVariant get npuPtl => _embeddinggemma2Text270m$npuPtl;

  /// `embeddinggemma-2-text-270m_Qualcomm_QCS8275.litertlm`, 208 MB.
  LiteRtEmbedderVariant get npuQcs8275 => _embeddinggemma2Text270m$npuQcs8275;

  /// `embeddinggemma-2-text-270m_Qualcomm_SM8550.litertlm`, 208 MB.
  LiteRtEmbedderVariant get npuSm8550 => _embeddinggemma2Text270m$npuSm8550;

  /// `embeddinggemma-2-text-270m_Qualcomm_SM8650.litertlm`, 208 MB.
  LiteRtEmbedderVariant get npuSm8650 => _embeddinggemma2Text270m$npuSm8650;

  /// `embeddinggemma-2-text-270m_Qualcomm_SM8750.litertlm`, 188 MB.
  LiteRtEmbedderVariant get npuSm8750 => _embeddinggemma2Text270m$npuSm8750;

  /// `embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm`, 202 MB.
  LiteRtEmbedderVariant get npuSm8850 => _embeddinggemma2Text270m$npuSm8850;

  /// `embeddinggemma-2-text-270m_Google_Tensor_G5.litertlm`, 166 MB.
  LiteRtEmbedderVariant get npuTensorG5 => _embeddinggemma2Text270m$npuTensorG5;

  /// `embeddinggemma-2-text-270m_Google_Tensor_G6.litertlm`, 200 MB.
  LiteRtEmbedderVariant get npuTensorG6 => _embeddinggemma2Text270m$npuTensorG6;
}

const _embeddinggemma2Text270m$generic = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/generic',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m.litertlm',
    sha256: '2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb',
    sizeBytes: 164626432,
    installFilename: 'embeddinggemma-2-text-270m__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
);

const _embeddinggemma2Text270m$npuMt6991 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-mt6991',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_MediaTek_MT6991.litertlm',
    sha256: '7acc8e334d882216207c23b7a477179d5af530d67fd8e2cb50ab42d3457f90c0',
    sizeBytes: 416350208,
    installFilename:
        'embeddinggemma-2-text-270m_MediaTek_MT6991__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6991',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _embeddinggemma2Text270m$npuMt6993 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-mt6993',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_MediaTek_MT6993.litertlm',
    sha256: 'eff006451073498117f454c7ab27f274b5fe14a54af49be239e8f480ee49fa36',
    sizeBytes: 385925120,
    installFilename:
        'embeddinggemma-2-text-270m_MediaTek_MT6993__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6993',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _embeddinggemma2Text270m$npuPtl = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-ptl',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_Intel_PTL.litertlm',
    sha256: '048e219d702d23cf19cb9a75e7595e61e320bc61a3919e0cbf1a30dfb5cc64f4',
    sizeBytes: 316715544,
    installFilename:
        'embeddinggemma-2-text-270m_Intel_PTL__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-ptl',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL'),
);

const _embeddinggemma2Text270m$npuQcs8275 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-qcs8275',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_Qualcomm_QCS8275.litertlm',
    sha256: '128c32151613a5bbf8b5695b2d9ae271057338febbf06e3aeebf29e1353cb51d',
    sizeBytes: 208011264,
    installFilename:
        'embeddinggemma-2-text-270m_Qualcomm_QCS8275__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-qcs8275',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'QCS8275'),
);

const _embeddinggemma2Text270m$npuSm8550 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-sm8550',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_Qualcomm_SM8550.litertlm',
    sha256: '6a5043146940e738cfa9111aa445b1cdb3dc7bbef30caef367622f14ada1a895',
    sizeBytes: 207896576,
    installFilename:
        'embeddinggemma-2-text-270m_Qualcomm_SM8550__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8550',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _embeddinggemma2Text270m$npuSm8650 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-sm8650',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_Qualcomm_SM8650.litertlm',
    sha256: '7dabcb17eed982d6de4435aaf29cc56147a627f6ab20a1e37aadd7af5399457b',
    sizeBytes: 207798272,
    installFilename:
        'embeddinggemma-2-text-270m_Qualcomm_SM8650__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8650',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _embeddinggemma2Text270m$npuSm8750 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-sm8750',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_Qualcomm_SM8750.litertlm',
    sha256: 'b5615709768db4ca4fb4f04514e7e41b0680ccb12dd5f90371193f7fd12e7c99',
    sizeBytes: 187596800,
    installFilename:
        'embeddinggemma-2-text-270m_Qualcomm_SM8750__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8750',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _embeddinggemma2Text270m$npuSm8850 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-sm8850',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm',
    sha256: '72992b649c812ae9e30ffa9ad88fc662e649f7b643500d28051fbd457ad0d22a',
    sizeBytes: 202293248,
    installFilename:
        'embeddinggemma-2-text-270m_Qualcomm_SM8850__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

const _embeddinggemma2Text270m$npuTensorG5 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-tensor-g5',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_Google_Tensor_G5.litertlm',
    sha256: 'f066663433a31a8228b46f3271d2714a3b72a341ed4563cbc6d90f2e3dd0162d',
    sizeBytes: 166007264,
    installFilename:
        'embeddinggemma-2-text-270m_Google_Tensor_G5__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g5',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
);

const _embeddinggemma2Text270m$npuTensorG6 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-270m/npu-tensor-g6',
  modelId: 'embeddinggemma-2-text-270m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-270m-litert-lm',
    revision: '9be6e8b90982095dc05c2bd162e4b954ee4dbac7',
    path: 'embeddinggemma-2-text-270m_Google_Tensor_G6.litertlm',
    sha256: '4cd282395a7b611ec8dec95160cd31a1f471a7b1cde1fc71717aa539c2a29883',
    sizeBytes: 199532256,
    installFilename:
        'embeddinggemma-2-text-270m_Google_Tensor_G6__rev-9be6e8b90982.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g6',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
);

/// EmbeddingGemma 2 Text + Vision 440M (`embeddinggemma-2-text-vision-440m`), apache-2.0.
final class LiteRtEmbedderEmbeddinggemma2TextVision440m
    extends LiteRtEmbedderModel {
  const LiteRtEmbedderEmbeddinggemma2TextVision440m._()
    : super._(
        id: 'embeddinggemma-2-text-vision-440m',
        displayName: 'EmbeddingGemma 2 Text + Vision 440M',
        family: 'embeddinggemma2',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [
          _embeddinggemma2TextVision440m$generic,
          _embeddinggemma2TextVision440m$npuMt6991,
          _embeddinggemma2TextVision440m$npuMt6993,
          _embeddinggemma2TextVision440m$npuPtl,
          _embeddinggemma2TextVision440m$npuQcs8275,
          _embeddinggemma2TextVision440m$npuSm8550,
          _embeddinggemma2TextVision440m$npuSm8650,
          _embeddinggemma2TextVision440m$npuSm8750,
          _embeddinggemma2TextVision440m$npuSm8850,
          _embeddinggemma2TextVision440m$npuTensorG5,
          _embeddinggemma2TextVision440m$npuTensorG6,
        ],
      );

  /// `embeddinggemma-2-text-vision-440m.litertlm`, 388 MB.
  LiteRtEmbedderVariant get generic => _embeddinggemma2TextVision440m$generic;

  /// `embeddinggemma-2-text-vision-440m_MediaTek_MT6991.litertlm`, 798 MB.
  LiteRtEmbedderVariant get npuMt6991 =>
      _embeddinggemma2TextVision440m$npuMt6991;

  /// `embeddinggemma-2-text-vision-440m_MediaTek_MT6993.litertlm`, 768 MB.
  LiteRtEmbedderVariant get npuMt6993 =>
      _embeddinggemma2TextVision440m$npuMt6993;

  /// `embeddinggemma-2-text-vision-440m_Intel_PTL.litertlm`, 752 MB.
  LiteRtEmbedderVariant get npuPtl => _embeddinggemma2TextVision440m$npuPtl;

  /// `embeddinggemma-2-text-vision-440m_Qualcomm_QCS8275.litertlm`, 466 MB.
  LiteRtEmbedderVariant get npuQcs8275 =>
      _embeddinggemma2TextVision440m$npuQcs8275;

  /// `embeddinggemma-2-text-vision-440m_Qualcomm_SM8550.litertlm`, 466 MB.
  LiteRtEmbedderVariant get npuSm8550 =>
      _embeddinggemma2TextVision440m$npuSm8550;

  /// `embeddinggemma-2-text-vision-440m_Qualcomm_SM8650.litertlm`, 466 MB.
  LiteRtEmbedderVariant get npuSm8650 =>
      _embeddinggemma2TextVision440m$npuSm8650;

  /// `embeddinggemma-2-text-vision-440m_Qualcomm_SM8750.litertlm`, 447 MB.
  LiteRtEmbedderVariant get npuSm8750 =>
      _embeddinggemma2TextVision440m$npuSm8750;

  /// `embeddinggemma-2-text-vision-440m_Qualcomm_SM8850.litertlm`, 463 MB.
  LiteRtEmbedderVariant get npuSm8850 =>
      _embeddinggemma2TextVision440m$npuSm8850;

  /// `embeddinggemma-2-text-vision-440m_Google_Tensor_G5.litertlm`, 559 MB.
  LiteRtEmbedderVariant get npuTensorG5 =>
      _embeddinggemma2TextVision440m$npuTensorG5;

  /// `embeddinggemma-2-text-vision-440m_Google_Tensor_G6.litertlm`, 513 MB.
  LiteRtEmbedderVariant get npuTensorG6 =>
      _embeddinggemma2TextVision440m$npuTensorG6;
}

const _embeddinggemma2TextVision440m$generic = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/generic',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m.litertlm',
    sha256: '92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0',
    sizeBytes: 387710976,
    installFilename:
        'embeddinggemma-2-text-vision-440m__rev-e301f74d5551.litertlm',
  ),
  ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
);

const _embeddinggemma2TextVision440m$npuMt6991 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-mt6991',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_MediaTek_MT6991.litertlm',
    sha256: '53cb4b8b3d8ca3e022ceec1dd809ddd26c281721c4652e1fadc82d2433cbc5de',
    sizeBytes: 798097408,
    installFilename:
        'embeddinggemma-2-text-vision-440m_MediaTek_MT6991__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6991',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6991-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _embeddinggemma2TextVision440m$npuMt6993 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-mt6993',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_MediaTek_MT6993.litertlm',
    sha256: '1cfc52d73266fe0e099e853b816150c22deb32fea421cabf9647dc8d8112ede9',
    sizeBytes: 767770624,
    installFilename:
        'embeddinggemma-2-text-vision-440m_MediaTek_MT6993__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6993',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-mt6993-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _embeddinggemma2TextVision440m$npuPtl = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-ptl',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_Intel_PTL.litertlm',
    sha256: '7f4c104b30ea6185516439aef534b84d9e7066366112506d5d8843e350fd08c9',
    sizeBytes: 752061108,
    installFilename:
        'embeddinggemma-2-text-vision-440m_Intel_PTL__rev-e301f74d5551.litertlm',
  ),
  ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-ptl',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-ptl-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL'),
);

const _embeddinggemma2TextVision440m$npuQcs8275 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-qcs8275',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_Qualcomm_QCS8275.litertlm',
    sha256: 'ce8ccce80a12f6bc9acfe664b76c3cc46a698f0da81ae857f706b06b9a4c7d38',
    sizeBytes: 465977344,
    installFilename:
        'embeddinggemma-2-text-vision-440m_Qualcomm_QCS8275__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-qcs8275',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-qcs8275-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'QCS8275'),
);

const _embeddinggemma2TextVision440m$npuSm8550 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-sm8550',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_Qualcomm_SM8550.litertlm',
    sha256: '4427eecca4289555e72b297308f4c9cf97110a657de25dd2fe7946ac824f6214',
    sizeBytes: 465993728,
    installFilename:
        'embeddinggemma-2-text-vision-440m_Qualcomm_SM8550__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8550',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8550-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _embeddinggemma2TextVision440m$npuSm8650 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-sm8650',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_Qualcomm_SM8650.litertlm',
    sha256: 'ec7d2ee513830337343567409f32fea4a3e4f8f7b94facd0a20f3d3523cd7480',
    sizeBytes: 465747968,
    installFilename:
        'embeddinggemma-2-text-vision-440m_Qualcomm_SM8650__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8650',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8650-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _embeddinggemma2TextVision440m$npuSm8750 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-sm8750',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_Qualcomm_SM8750.litertlm',
    sha256: 'c5c05cb59833541a2d0d9374c7b50d2c3a406a4a84c85762775e5f9c6d96cd0c',
    sizeBytes: 446611456,
    installFilename:
        'embeddinggemma-2-text-vision-440m_Qualcomm_SM8750__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8750',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8750-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _embeddinggemma2TextVision440m$npuSm8850 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-sm8850',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_Qualcomm_SM8850.litertlm',
    sha256: '661369235aa9fc23cf04a213d4e445c4634073832279f5a261ed22650a8ebc5b',
    sizeBytes: 462536704,
    installFilename:
        'embeddinggemma-2-text-vision-440m_Qualcomm_SM8850__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

const _embeddinggemma2TextVision440m$npuTensorG5 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-tensor-g5',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_Google_Tensor_G5.litertlm',
    sha256: '96cdbae7b3dd6fa0f829fef2d0dd5bafc0179890d9bafbfe972db852e818d758',
    sizeBytes: 559418036,
    installFilename:
        'embeddinggemma-2-text-vision-440m_Google_Tensor_G5__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g5',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g5-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
);

const _embeddinggemma2TextVision440m$npuTensorG6 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-2-text-vision-440m/npu-tensor-g6',
  modelId: 'embeddinggemma-2-text-vision-440m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-2-text-vision-440m-litert-lm',
    revision: 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
    path: 'embeddinggemma-2-text-vision-440m_Google_Tensor_G6.litertlm',
    sha256: '40e98aeed9ef08abfd91d5d309f64f4fa06195c513931e917bcf5ea41a910668',
    sizeBytes: 513166004,
    installFilename:
        'embeddinggemma-2-text-vision-440m_Google_Tensor_G6__rev-e301f74d5551.litertlm',
  ),
  ragProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g6',
  imageRagProfileId:
      'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g6-vis140',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text, EmbeddingModality.image},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
);

/// EmbeddingGemma 300M (`embeddinggemma-300m`), gemma.
final class LiteRtEmbedderEmbeddinggemma300m extends LiteRtEmbedderModel {
  const LiteRtEmbedderEmbeddinggemma300m._()
    : super._(
        id: 'embeddinggemma-300m',
        displayName: 'EmbeddingGemma 300M',
        family: 'embeddinggemma',
        license: 'gemma',
        licenseUrl: 'https://ai.google.dev/gemma/terms',
        variants: const [
          _embeddinggemma300m$seq256,
          _embeddinggemma300m$seq256NpuMt6991,
          _embeddinggemma300m$seq256NpuMt6993,
          _embeddinggemma300m$seq256NpuSm8550,
          _embeddinggemma300m$seq256NpuSm8650,
          _embeddinggemma300m$seq256NpuSm8750,
          _embeddinggemma300m$seq256NpuSm8850,
          _embeddinggemma300m$seq256NpuTensorG5,
          _embeddinggemma300m$seq256NpuTensorG6,
          _embeddinggemma300m$seq512,
          _embeddinggemma300m$seq512NpuMt6991,
          _embeddinggemma300m$seq512NpuMt6993,
          _embeddinggemma300m$seq512NpuSm8550,
          _embeddinggemma300m$seq512NpuSm8650,
          _embeddinggemma300m$seq512NpuSm8750,
          _embeddinggemma300m$seq512NpuSm8850,
          _embeddinggemma300m$seq512NpuTensorG5,
          _embeddinggemma300m$seq512NpuTensorG6,
          _embeddinggemma300m$seq1024,
          _embeddinggemma300m$seq1024NpuMt6991,
          _embeddinggemma300m$seq1024NpuMt6993,
          _embeddinggemma300m$seq1024NpuSm8550,
          _embeddinggemma300m$seq1024NpuSm8650,
          _embeddinggemma300m$seq1024NpuSm8750,
          _embeddinggemma300m$seq1024NpuSm8850,
          _embeddinggemma300m$seq1024NpuTensorG5,
          _embeddinggemma300m$seq1024NpuTensorG6,
          _embeddinggemma300m$seq2048,
          _embeddinggemma300m$seq2048NpuMt6991,
          _embeddinggemma300m$seq2048NpuMt6993,
          _embeddinggemma300m$seq2048NpuSm8550,
          _embeddinggemma300m$seq2048NpuSm8650,
          _embeddinggemma300m$seq2048NpuSm8750,
          _embeddinggemma300m$seq2048NpuSm8850,
          _embeddinggemma300m$seq2048NpuTensorG5,
          _embeddinggemma300m$seq2048NpuTensorG6,
        ],
      );

  /// `embeddinggemma-300M_seq256_mixed-precision.tflite`, 179 MB.
  LiteRtEmbedderVariant get seq256 => _embeddinggemma300m$seq256;

  /// `embeddinggemma-300M_seq256_mixed-precision.mediatek.mt6991.tflite`, 188 MB.
  LiteRtEmbedderVariant get seq256NpuMt6991 =>
      _embeddinggemma300m$seq256NpuMt6991;

  /// `embeddinggemma-300M_seq256_mixed-precision.mediatek.mt6993.tflite`, 176 MB.
  LiteRtEmbedderVariant get seq256NpuMt6993 =>
      _embeddinggemma300m$seq256NpuMt6993;

  /// `embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8550.tflite`, 184 MB.
  LiteRtEmbedderVariant get seq256NpuSm8550 =>
      _embeddinggemma300m$seq256NpuSm8550;

  /// `embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8650.tflite`, 184 MB.
  LiteRtEmbedderVariant get seq256NpuSm8650 =>
      _embeddinggemma300m$seq256NpuSm8650;

  /// `embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8750.tflite`, 182 MB.
  LiteRtEmbedderVariant get seq256NpuSm8750 =>
      _embeddinggemma300m$seq256NpuSm8750;

  /// `embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8850.tflite`, 182 MB.
  LiteRtEmbedderVariant get seq256NpuSm8850 =>
      _embeddinggemma300m$seq256NpuSm8850;

  /// `embeddinggemma-300M_seq256_mixed-precision.google.tensor_g5.tflite`, 191 MB.
  LiteRtEmbedderVariant get seq256NpuTensorG5 =>
      _embeddinggemma300m$seq256NpuTensorG5;

  /// `embeddinggemma-300M_seq256_mixed-precision.google.tensor_g6.tflite`, 201 MB.
  LiteRtEmbedderVariant get seq256NpuTensorG6 =>
      _embeddinggemma300m$seq256NpuTensorG6;

  /// `embeddinggemma-300M_seq512_mixed-precision.tflite`, 179 MB.
  LiteRtEmbedderVariant get seq512 => _embeddinggemma300m$seq512;

  /// `embeddinggemma-300M_seq512_mixed-precision.mediatek.mt6991.tflite`, 188 MB.
  LiteRtEmbedderVariant get seq512NpuMt6991 =>
      _embeddinggemma300m$seq512NpuMt6991;

  /// `embeddinggemma-300M_seq512_mixed-precision.mediatek.mt6993.tflite`, 184 MB.
  LiteRtEmbedderVariant get seq512NpuMt6993 =>
      _embeddinggemma300m$seq512NpuMt6993;

  /// `embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8550.tflite`, 190 MB.
  LiteRtEmbedderVariant get seq512NpuSm8550 =>
      _embeddinggemma300m$seq512NpuSm8550;

  /// `embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8650.tflite`, 190 MB.
  LiteRtEmbedderVariant get seq512NpuSm8650 =>
      _embeddinggemma300m$seq512NpuSm8650;

  /// `embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8750.tflite`, 184 MB.
  LiteRtEmbedderVariant get seq512NpuSm8750 =>
      _embeddinggemma300m$seq512NpuSm8750;

  /// `embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8850.tflite`, 184 MB.
  LiteRtEmbedderVariant get seq512NpuSm8850 =>
      _embeddinggemma300m$seq512NpuSm8850;

  /// `embeddinggemma-300M_seq512_mixed-precision.google.tensor_g5.tflite`, 192 MB.
  LiteRtEmbedderVariant get seq512NpuTensorG5 =>
      _embeddinggemma300m$seq512NpuTensorG5;

  /// `embeddinggemma-300M_seq512_mixed-precision.google.tensor_g6.tflite`, 202 MB.
  LiteRtEmbedderVariant get seq512NpuTensorG6 =>
      _embeddinggemma300m$seq512NpuTensorG6;

  /// `embeddinggemma-300M_seq1024_mixed-precision.tflite`, 183 MB.
  LiteRtEmbedderVariant get seq1024 => _embeddinggemma300m$seq1024;

  /// `embeddinggemma-300M_seq1024_mixed-precision.mediatek.mt6991.tflite`, 188 MB.
  LiteRtEmbedderVariant get seq1024NpuMt6991 =>
      _embeddinggemma300m$seq1024NpuMt6991;

  /// `embeddinggemma-300M_seq1024_mixed-precision.mediatek.mt6993.tflite`, 186 MB.
  LiteRtEmbedderVariant get seq1024NpuMt6993 =>
      _embeddinggemma300m$seq1024NpuMt6993;

  /// `embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8550.tflite`, 195 MB.
  LiteRtEmbedderVariant get seq1024NpuSm8550 =>
      _embeddinggemma300m$seq1024NpuSm8550;

  /// `embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8650.tflite`, 195 MB.
  LiteRtEmbedderVariant get seq1024NpuSm8650 =>
      _embeddinggemma300m$seq1024NpuSm8650;

  /// `embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8750.tflite`, 195 MB.
  LiteRtEmbedderVariant get seq1024NpuSm8750 =>
      _embeddinggemma300m$seq1024NpuSm8750;

  /// `embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8850.tflite`, 199 MB.
  LiteRtEmbedderVariant get seq1024NpuSm8850 =>
      _embeddinggemma300m$seq1024NpuSm8850;

  /// `embeddinggemma-300M_seq1024_mixed-precision.google.tensor_g5.tflite`, 202 MB.
  LiteRtEmbedderVariant get seq1024NpuTensorG5 =>
      _embeddinggemma300m$seq1024NpuTensorG5;

  /// `embeddinggemma-300M_seq1024_mixed-precision.google.tensor_g6.tflite`, 210 MB.
  LiteRtEmbedderVariant get seq1024NpuTensorG6 =>
      _embeddinggemma300m$seq1024NpuTensorG6;

  /// `embeddinggemma-300M_seq2048_mixed-precision.tflite`, 196 MB.
  LiteRtEmbedderVariant get seq2048 => _embeddinggemma300m$seq2048;

  /// `embeddinggemma-300M_seq2048_mixed-precision.mediatek.mt6991.tflite`, 194 MB.
  LiteRtEmbedderVariant get seq2048NpuMt6991 =>
      _embeddinggemma300m$seq2048NpuMt6991;

  /// `embeddinggemma-300M_seq2048_mixed-precision.mediatek.mt6993.tflite`, 192 MB.
  LiteRtEmbedderVariant get seq2048NpuMt6993 =>
      _embeddinggemma300m$seq2048NpuMt6993;

  /// `embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8550.tflite`, 245 MB.
  LiteRtEmbedderVariant get seq2048NpuSm8550 =>
      _embeddinggemma300m$seq2048NpuSm8550;

  /// `embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8650.tflite`, 245 MB.
  LiteRtEmbedderVariant get seq2048NpuSm8650 =>
      _embeddinggemma300m$seq2048NpuSm8650;

  /// `embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8750.tflite`, 220 MB.
  LiteRtEmbedderVariant get seq2048NpuSm8750 =>
      _embeddinggemma300m$seq2048NpuSm8750;

  /// `embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8850.tflite`, 222 MB.
  LiteRtEmbedderVariant get seq2048NpuSm8850 =>
      _embeddinggemma300m$seq2048NpuSm8850;

  /// `embeddinggemma-300M_seq2048_mixed-precision.google.tensor_g5.tflite`, 248 MB.
  LiteRtEmbedderVariant get seq2048NpuTensorG5 =>
      _embeddinggemma300m$seq2048NpuTensorG5;

  /// `embeddinggemma-300M_seq2048_mixed-precision.google.tensor_g6.tflite`, 252 MB.
  LiteRtEmbedderVariant get seq2048NpuTensorG6 =>
      _embeddinggemma300m$seq2048NpuTensorG6;
}

const _embeddinggemma300m$seq256 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '29888fcee3216acadc7e844906e5fe0d79a61875',
    path: 'embeddinggemma-300M_seq256_mixed-precision.tflite',
    sha256: '37115ef7bff76cd37dd86abe503ff511b1032bf85fc624a85c49c84899e92bc5',
    sizeBytes: 179131736,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision__rev-29888fcee321.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '29888fcee3216acadc7e844906e5fe0d79a61875',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256__sentencepiece__rev-29888fcee321.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
);

const _embeddinggemma300m$seq256NpuMt6991 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256-npu-mt6991',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq256_mixed-precision.mediatek.mt6991.tflite',
    sha256: '066e924697e81230f527e9d09ef2c8052a788de44cdf1854c599b03e0956020b',
    sizeBytes: 187654076,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision.mediatek.mt6991__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256-mt6991__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-mt6991',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _embeddinggemma300m$seq256NpuMt6993 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256-npu-mt6993',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq256_mixed-precision.mediatek.mt6993.tflite',
    sha256: 'dfcef4645e74e6587cdb57a3b68e96eb2eb974ee8d49279d1c95fadaef01271e',
    sizeBytes: 176160768,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision.mediatek.mt6993__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256-mt6993__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-mt6993',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _embeddinggemma300m$seq256NpuSm8550 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256-npu-sm8550',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8550.tflite',
    sha256: 'd2e7f905fbf04fe5ba9137be75bd60dae368878ee1910698a9d3f805c8ad6641',
    sizeBytes: 184412704,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8550__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256-sm8550__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8550',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _embeddinggemma300m$seq256NpuSm8650 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256-npu-sm8650',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8650.tflite',
    sha256: 'f58530f8a729f5de2407ea0beacd15034ed803c82842f4254b22eea5ca4d57c4',
    sizeBytes: 184400416,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8650__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256-sm8650__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8650',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _embeddinggemma300m$seq256NpuSm8750 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256-npu-sm8750',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8750.tflite',
    sha256: 'b55c394309b349de5c917666b953f9364c4b248cd1cecff22d4fbb42bac4c67f',
    sizeBytes: 181676576,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8750__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256-sm8750__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8750',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _embeddinggemma300m$seq256NpuSm8850 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256-npu-sm8850',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8850.tflite',
    sha256: '134ae8fccbf1c390a35b685771aa18704ac83569a06284285a3a42ef343bf209',
    sizeBytes: 181987872,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision.qualcomm.sm8850__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256-sm8850__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8850',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

const _embeddinggemma300m$seq256NpuTensorG5 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256-npu-tensor-g5',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq256_mixed-precision.google.tensor_g5.tflite',
    sha256: 'e49a10b5769296953906fd4b7d75805a2d8729d4cd3a2c53c887390332da3ace',
    sizeBytes: 191474704,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision.google.tensor_g5__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256-tensor-g5__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-tensor_g5',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
);

const _embeddinggemma300m$seq256NpuTensorG6 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq256-npu-tensor-g6',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq256_mixed-precision.google.tensor_g6.tflite',
    sha256: '3ed0bdc4aa284dd1ba07cc5591744e681880a6d773fa799fbc92fe7e6314c7ce',
    sizeBytes: 201284320,
    installFilename:
        'embeddinggemma-300M_seq256_mixed-precision.google.tensor_g6__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq256-tensor-g6__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq256-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-tensor_g6',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
);

const _embeddinggemma300m$seq512 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '29888fcee3216acadc7e844906e5fe0d79a61875',
    path: 'embeddinggemma-300M_seq512_mixed-precision.tflite',
    sha256: 'ad09e81557203cb0e177abf9bf8727dfe138a7d394aa0f70f0b2ed16432e121a',
    sizeBytes: 179132472,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision__rev-29888fcee321.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '29888fcee3216acadc7e844906e5fe0d79a61875',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512__sentencepiece__rev-29888fcee321.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
);

const _embeddinggemma300m$seq512NpuMt6991 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512-npu-mt6991',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq512_mixed-precision.mediatek.mt6991.tflite',
    sha256: '7776785538a594d77fc72d22e5a8d3548a8b616e99897b5b7040b8dc211d0767',
    sizeBytes: 187803028,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision.mediatek.mt6991__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512-mt6991__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-mt6991',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _embeddinggemma300m$seq512NpuMt6993 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512-npu-mt6993',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq512_mixed-precision.mediatek.mt6993.tflite',
    sha256: '8ae9ffccdd1ff29e019b872297476d0be9c21f30911e162246f1059f16ddf24e',
    sizeBytes: 183543612,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision.mediatek.mt6993__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512-mt6993__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-mt6993',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _embeddinggemma300m$seq512NpuSm8550 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512-npu-sm8550',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8550.tflite',
    sha256: 'a47e4f049a29b55ffdfad0ab78dc4a3d43608829350568253c30501e7d6053ef',
    sizeBytes: 190290464,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8550__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512-sm8550__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8550',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _embeddinggemma300m$seq512NpuSm8650 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512-npu-sm8650',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8650.tflite',
    sha256: '412bb42e65bbcab91158ebf514ba5597a6e7312076fba0c07c8278948398779e',
    sizeBytes: 190294560,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8650__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512-sm8650__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8650',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _embeddinggemma300m$seq512NpuSm8750 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512-npu-sm8750',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8750.tflite',
    sha256: 'd9ccceaa73ab38f5b72bdf48fb370fd84c06c28e9b05aa1d5a91c3f03b2ae217',
    sizeBytes: 184363552,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8750__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512-sm8750__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8750',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _embeddinggemma300m$seq512NpuSm8850 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512-npu-sm8850',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8850.tflite',
    sha256: 'd25c0e6e7eeb0fdec75ee4e06cb67ce5a193c4fcc0dd1eb87eaafa0c75bf7700',
    sizeBytes: 184474144,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision.qualcomm.sm8850__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512-sm8850__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8850',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

const _embeddinggemma300m$seq512NpuTensorG5 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512-npu-tensor-g5',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq512_mixed-precision.google.tensor_g5.tflite',
    sha256: 'de396c28f9af37977fae920eca8bb571c876ce34c845326a8151a7bc60097f86',
    sizeBytes: 191971472,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision.google.tensor_g5__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512-tensor-g5__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-tensor_g5',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
);

const _embeddinggemma300m$seq512NpuTensorG6 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq512-npu-tensor-g6',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq512_mixed-precision.google.tensor_g6.tflite',
    sha256: '8b4a7b805dfc7b44ce4713cb0236e823ed9ebb902842d1da0a0ed0aa333f14e1',
    sizeBytes: 201824480,
    installFilename:
        'embeddinggemma-300M_seq512_mixed-precision.google.tensor_g6__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq512-tensor-g6__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq512-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-tensor_g6',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
);

const _embeddinggemma300m$seq1024 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '29888fcee3216acadc7e844906e5fe0d79a61875',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.tflite',
    sha256: '8b0b8bbd0aa95f9f747c25a6c87cd05a8286933282660f6a50da877662917e31',
    sizeBytes: 183329528,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision__rev-29888fcee321.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '29888fcee3216acadc7e844906e5fe0d79a61875',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024__sentencepiece__rev-29888fcee321.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
);

const _embeddinggemma300m$seq1024NpuMt6991 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024-npu-mt6991',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.mediatek.mt6991.tflite',
    sha256: '2cedc201332ba6562448cd2d4ab624840c0e2b1076a7d10909c1fc5e13e2dc49',
    sizeBytes: 187525992,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision.mediatek.mt6991__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024-mt6991__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-mt6991',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _embeddinggemma300m$seq1024NpuMt6993 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024-npu-mt6993',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.mediatek.mt6993.tflite',
    sha256: '1dfa2b1d37ff4a59e5e42d3d27d133fb721dbfd2d9c88801a21442ef4cd4cc0e',
    sizeBytes: 185540768,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision.mediatek.mt6993__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024-mt6993__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-mt6993',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _embeddinggemma300m$seq1024NpuSm8550 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024-npu-sm8550',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8550.tflite',
    sha256: '74cfad70f31d3759e9a6ada6c4f31d601f245e6bb957391e56b2fa7c38e5dd68',
    sizeBytes: 195254816,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8550__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024-sm8550__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8550',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _embeddinggemma300m$seq1024NpuSm8650 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024-npu-sm8650',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8650.tflite',
    sha256: 'acdb80aa131e0c1d45379aa9eb29459cc5d2d49280e7b0f67de1d81dbccf7283',
    sizeBytes: 195361312,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8650__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024-sm8650__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8650',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _embeddinggemma300m$seq1024NpuSm8750 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024-npu-sm8750',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8750.tflite',
    sha256: '3c68b9887a0148f25443e6287a6f9ada838ada89dddf6de36830a943becd5ca8',
    sizeBytes: 195271200,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8750__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024-sm8750__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8750',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _embeddinggemma300m$seq1024NpuSm8850 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024-npu-sm8850',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8850.tflite',
    sha256: 'e57de03a0b531a8a4ad850a0d11cf3c9dca81f7902217c3df356082194817df5',
    sizeBytes: 198740512,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision.qualcomm.sm8850__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024-sm8850__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8850',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

const _embeddinggemma300m$seq1024NpuTensorG5 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024-npu-tensor-g5',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.google.tensor_g5.tflite',
    sha256: 'e3aeec6a721366c360478856501c895ce0e6e8b91b7e0168359f4b25a7d6c6a5',
    sizeBytes: 201603664,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision.google.tensor_g5__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024-tensor-g5__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-tensor_g5',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
);

const _embeddinggemma300m$seq1024NpuTensorG6 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq1024-npu-tensor-g6',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq1024_mixed-precision.google.tensor_g6.tflite',
    sha256: '8469a099d33bc5c5335bc99e5dea1c028d81e0e5615917fd1f3006f78bf5ae2e',
    sizeBytes: 209530336,
    installFilename:
        'embeddinggemma-300M_seq1024_mixed-precision.google.tensor_g6__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq1024-tensor-g6__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq1024-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-tensor_g6',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
);

const _embeddinggemma300m$seq2048 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '29888fcee3216acadc7e844906e5fe0d79a61875',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.tflite',
    sha256: 'd39b0bb3346bfb4f884f3bbce3196b261895aeece7e7ac02ffb44ed6e0f39381',
    sizeBytes: 195912440,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision__rev-29888fcee321.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '29888fcee3216acadc7e844906e5fe0d79a61875',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048__sentencepiece__rev-29888fcee321.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
);

const _embeddinggemma300m$seq2048NpuMt6991 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048-npu-mt6991',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.mediatek.mt6991.tflite',
    sha256: 'dc56fcfd305fea2a3daaec82bff772a9de3f746a8b7bf216fa015e8b2d9c6785',
    sizeBytes: 194214772,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision.mediatek.mt6991__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048-mt6991__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-mt6991',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _embeddinggemma300m$seq2048NpuMt6993 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048-npu-mt6993',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.mediatek.mt6993.tflite',
    sha256: '64c5e51d918e8047850dd1d4debcf81ec4e6985d9ae5cbc0a17521de45b5f59b',
    sizeBytes: 192133828,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision.mediatek.mt6993__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048-mt6993__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-mt6993',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _embeddinggemma300m$seq2048NpuSm8550 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048-npu-sm8550',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8550.tflite',
    sha256: '15d5d5dca08ccc7f026bdeb3983b4a0856b527654cad5c7e72027ae5edfbc0e7',
    sizeBytes: 244877856,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8550__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048-sm8550__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8550',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _embeddinggemma300m$seq2048NpuSm8650 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048-npu-sm8650',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8650.tflite',
    sha256: '3665698c5b632f621d85e2b4b6d135fadd0a92365a1b4e510afbc6dbcca4a870',
    sizeBytes: 244771360,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8650__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048-sm8650__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8650',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _embeddinggemma300m$seq2048NpuSm8750 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048-npu-sm8750',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8750.tflite',
    sha256: '21e814671507b5a1a1748b2200275d6c7f9fdf0e8fcdb42d84f5c3164a712d92',
    sizeBytes: 219793952,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8750__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048-sm8750__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8750',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _embeddinggemma300m$seq2048NpuSm8850 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048-npu-sm8850',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8850.tflite',
    sha256: '7172747e73500528d2f61de8df43609ff6344eb61b9e9e1f40acd9e0e38cbb55',
    sizeBytes: 221776416,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision.qualcomm.sm8850__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048-sm8850__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-sm8850',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

const _embeddinggemma300m$seq2048NpuTensorG5 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048-npu-tensor-g5',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.google.tensor_g5.tflite',
    sha256: 'e659122c0ab3d02075a9e624efd7c8919a8f2e9dbc2d7284f41cb437e675f060',
    sizeBytes: 247708816,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision.google.tensor_g5__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048-tensor-g5__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-tensor_g5',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
);

const _embeddinggemma300m$seq2048NpuTensorG6 = LiteRtEmbedderVariant._(
  id: 'embeddinggemma-300m/seq2048-npu-tensor-g6',
  modelId: 'embeddinggemma-300m',
  model: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'embeddinggemma-300M_seq2048_mixed-precision.google.tensor_g6.tflite',
    sha256: '83500348f3ddeb82df1b6cacda879d49a2de83ac45d94738e6659cbf4c88d756',
    sizeBytes: 252056544,
    installFilename:
        'embeddinggemma-300M_seq2048_mixed-precision.google.tensor_g6__rev-459f1d37fec9.tflite',
    gated: true,
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/embeddinggemma-300m',
    revision: '459f1d37fec9635eb1730ebdbc219bfc3226c8e7',
    path: 'sentencepiece.model',
    sha256: 'd6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7',
    sizeBytes: 4683319,
    installFilename:
        'embeddinggemma-300m-seq2048-tensor-g6__sentencepiece__rev-459f1d37fec9.model',
    gated: true,
  ),
  ragProfileId:
      'embeddinggemma-300m-seq2048-mp-rev-459f1d37fec9-retrieval-prefix-meanpool-l2-v1-npu-tensor_g6',
  dimension: 768,
  maxInputTokens: 2048,
  modalities: {EmbeddingModality.text},
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
);

/// Gecko 110M (English) (`gecko-110m-en`), apache-2.0.
final class LiteRtEmbedderGecko110mEn extends LiteRtEmbedderModel {
  const LiteRtEmbedderGecko110mEn._()
    : super._(
        id: 'gecko-110m-en',
        displayName: 'Gecko 110M (English)',
        family: 'gecko',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [
          _gecko110mEn$seq64Quant,
          _gecko110mEn$seq256Quant,
          _gecko110mEn$seq512Quant,
          _gecko110mEn$seq1024Quant,
          _gecko110mEn$seq64F32,
          _gecko110mEn$seq256F32,
          _gecko110mEn$seq512F32,
          _gecko110mEn$seq1024F32,
        ],
      );

  /// `Gecko_64_quant.tflite`, 112 MB.
  LiteRtEmbedderVariant get seq64Quant => _gecko110mEn$seq64Quant;

  /// `Gecko_256_quant.tflite`, 114 MB.
  LiteRtEmbedderVariant get seq256Quant => _gecko110mEn$seq256Quant;

  /// `Gecko_512_quant.tflite`, 120 MB.
  LiteRtEmbedderVariant get seq512Quant => _gecko110mEn$seq512Quant;

  /// `Gecko_1024_quant.tflite`, 146 MB.
  LiteRtEmbedderVariant get seq1024Quant => _gecko110mEn$seq1024Quant;

  /// `Gecko_64_f32.tflite`, 441 MB.
  LiteRtEmbedderVariant get seq64F32 => _gecko110mEn$seq64F32;

  /// `Gecko_256_f32.tflite`, 443 MB.
  LiteRtEmbedderVariant get seq256F32 => _gecko110mEn$seq256F32;

  /// `Gecko_512_f32.tflite`, 449 MB.
  LiteRtEmbedderVariant get seq512F32 => _gecko110mEn$seq512F32;

  /// `Gecko_1024_f32.tflite`, 475 MB.
  LiteRtEmbedderVariant get seq1024F32 => _gecko110mEn$seq1024F32;
}

const _gecko110mEn$seq64Quant = LiteRtEmbedderVariant._(
  id: 'gecko-110m-en/seq64-quant',
  modelId: 'gecko-110m-en',
  model: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'Gecko_64_quant.tflite',
    sha256: '19f04c9397c814c293d8c6caa045b89da298c77064d65e90d8f85f4c02ad466f',
    sizeBytes: 112175104,
    installFilename: 'Gecko_64_quant__rev-61a0d0c2cdc9.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'sentencepiece.model',
    sha256: '839ffa4b9afae8d77834a88b87781849aa021975d6063dec6085633fcaf7171c',
    sizeBytes: 794346,
    installFilename:
        'gecko-110m-en-seq64__sentencepiece__rev-61a0d0c2cdc9.model',
  ),
  ragProfileId:
      'gecko-110m-en-seq64-quant-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 64,
  modalities: {EmbeddingModality.text},
);

const _gecko110mEn$seq256Quant = LiteRtEmbedderVariant._(
  id: 'gecko-110m-en/seq256-quant',
  modelId: 'gecko-110m-en',
  model: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'Gecko_256_quant.tflite',
    sha256: '81505c2a296878467fba5bb066fe3646f75e04d19220fbf219c0c968f5ea2ce4',
    sizeBytes: 114141184,
    installFilename: 'Gecko_256_quant__rev-61a0d0c2cdc9.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'sentencepiece.model',
    sha256: '839ffa4b9afae8d77834a88b87781849aa021975d6063dec6085633fcaf7171c',
    sizeBytes: 794346,
    installFilename:
        'gecko-110m-en-seq256__sentencepiece__rev-61a0d0c2cdc9.model',
  ),
  ragProfileId:
      'gecko-110m-en-seq256-quant-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
);

const _gecko110mEn$seq512Quant = LiteRtEmbedderVariant._(
  id: 'gecko-110m-en/seq512-quant',
  modelId: 'gecko-110m-en',
  model: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'Gecko_512_quant.tflite',
    sha256: '2b11bb47da36b6085e65f46af28609f64ec13feb039e8d319cdaa0a10d608b19',
    sizeBytes: 120432640,
    installFilename: 'Gecko_512_quant__rev-61a0d0c2cdc9.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'sentencepiece.model',
    sha256: '839ffa4b9afae8d77834a88b87781849aa021975d6063dec6085633fcaf7171c',
    sizeBytes: 794346,
    installFilename:
        'gecko-110m-en-seq512__sentencepiece__rev-61a0d0c2cdc9.model',
  ),
  ragProfileId:
      'gecko-110m-en-seq512-quant-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
);

const _gecko110mEn$seq1024Quant = LiteRtEmbedderVariant._(
  id: 'gecko-110m-en/seq1024-quant',
  modelId: 'gecko-110m-en',
  model: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'Gecko_1024_quant.tflite',
    sha256: '2334395c8192ea6466093dc39177c524535ba8318c876232096d023518d323e6',
    sizeBytes: 145598464,
    installFilename: 'Gecko_1024_quant__rev-61a0d0c2cdc9.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'sentencepiece.model',
    sha256: '839ffa4b9afae8d77834a88b87781849aa021975d6063dec6085633fcaf7171c',
    sizeBytes: 794346,
    installFilename:
        'gecko-110m-en-seq1024__sentencepiece__rev-61a0d0c2cdc9.model',
  ),
  ragProfileId:
      'gecko-110m-en-seq1024-quant-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
);

const _gecko110mEn$seq64F32 = LiteRtEmbedderVariant._(
  id: 'gecko-110m-en/seq64-f32',
  modelId: 'gecko-110m-en',
  model: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'Gecko_64_f32.tflite',
    sha256: '31e402e85fd0f45ec82588939ba1f0424c1366b17dbe8a6cd431007bfeefabe3',
    sizeBytes: 441231836,
    installFilename: 'Gecko_64_f32__rev-61a0d0c2cdc9.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'sentencepiece.model',
    sha256: '839ffa4b9afae8d77834a88b87781849aa021975d6063dec6085633fcaf7171c',
    sizeBytes: 794346,
    installFilename:
        'gecko-110m-en-seq64-f32__sentencepiece__rev-61a0d0c2cdc9.model',
  ),
  ragProfileId:
      'gecko-110m-en-seq64-f32-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 64,
  modalities: {EmbeddingModality.text},
);

const _gecko110mEn$seq256F32 = LiteRtEmbedderVariant._(
  id: 'gecko-110m-en/seq256-f32',
  modelId: 'gecko-110m-en',
  model: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'Gecko_256_f32.tflite',
    sha256: 'eb738ab8cd002380ba5e052cd00cc6abf5e7d20fb94fa1ef447ab318bfe3a123',
    sizeBytes: 443197916,
    installFilename: 'Gecko_256_f32__rev-61a0d0c2cdc9.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'sentencepiece.model',
    sha256: '839ffa4b9afae8d77834a88b87781849aa021975d6063dec6085633fcaf7171c',
    sizeBytes: 794346,
    installFilename:
        'gecko-110m-en-seq256-f32__sentencepiece__rev-61a0d0c2cdc9.model',
  ),
  ragProfileId:
      'gecko-110m-en-seq256-f32-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 256,
  modalities: {EmbeddingModality.text},
);

const _gecko110mEn$seq512F32 = LiteRtEmbedderVariant._(
  id: 'gecko-110m-en/seq512-f32',
  modelId: 'gecko-110m-en',
  model: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'Gecko_512_f32.tflite',
    sha256: 'ab5b20c443e6fa60c1a5bad45e6f8d1b11e3c60d5850c2f62bb8402b904ae6c1',
    sizeBytes: 449489372,
    installFilename: 'Gecko_512_f32__rev-61a0d0c2cdc9.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'sentencepiece.model',
    sha256: '839ffa4b9afae8d77834a88b87781849aa021975d6063dec6085633fcaf7171c',
    sizeBytes: 794346,
    installFilename:
        'gecko-110m-en-seq512-f32__sentencepiece__rev-61a0d0c2cdc9.model',
  ),
  ragProfileId:
      'gecko-110m-en-seq512-f32-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 512,
  modalities: {EmbeddingModality.text},
);

const _gecko110mEn$seq1024F32 = LiteRtEmbedderVariant._(
  id: 'gecko-110m-en/seq1024-f32',
  modelId: 'gecko-110m-en',
  model: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'Gecko_1024_f32.tflite',
    sha256: 'd594eebd0dc01b6009d6392cc3d6e6950f1104caf1712cedc62ac0373ea71183',
    sizeBytes: 474655196,
    installFilename: 'Gecko_1024_f32__rev-61a0d0c2cdc9.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'litert-community/Gecko-110m-en',
    revision: '61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2',
    path: 'sentencepiece.model',
    sha256: '839ffa4b9afae8d77834a88b87781849aa021975d6063dec6085633fcaf7171c',
    sizeBytes: 794346,
    installFilename:
        'gecko-110m-en-seq1024-f32__sentencepiece__rev-61a0d0c2cdc9.model',
  ),
  ragProfileId:
      'gecko-110m-en-seq1024-f32-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  dimension: 768,
  maxInputTokens: 1024,
  modalities: {EmbeddingModality.text},
);
