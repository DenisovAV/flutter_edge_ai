// GENERATED from model_registry/models/*.yaml by tool/model_registry:
//   cd tool/model_registry && dart run bin/registry.dart generate
// Do not edit: change the registry and generate again. `registry.dart check`
// fails when this file is stale.
// ignore_for_file: camel_case_types, non_constant_identifier_names

part of '../speech_catalog.dart';

/// The speech models `flutter_edge_ai_speech` runs: speech-to-text `.tflite` models with their tokenizers, and text-to-speech bundles, pinned to Hugging Face commits.
abstract final class LiteRtSpeechModels {
  /// Every speech-to-text model, in one catalog.
  static const sttCatalog = LiteRtSpeechCatalog._(
    'flutter_edge_ai_speech',
    stt,
  );

  /// Every text-to-speech model, in one catalog.
  static const ttsCatalog = LiteRtSpeechCatalog._(
    'flutter_edge_ai_speech',
    tts,
  );

  /// Every speech-to-text model.
  static const List<LiteRtSttModel> stt = [
    moonshineTiny,
    parakeetCtc0_6b,
    whisperBase,
    whisperTiny,
  ];

  /// Every text-to-speech model.
  static const List<LiteRtTtsModel> tts = [
    inflectNanoV2,
    matchaTts,
    qwen3Tts0_6b,
  ];

  /// The speech-to-text model with [id], or null.
  static LiteRtSttModel? sttById(String id) {
    for (final m in stt) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The text-to-speech model with [id], or null.
  static LiteRtTtsModel? ttsById(String id) {
    for (final m in tts) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Moonshine Tiny (`moonshine-tiny`).
  static const moonshineTiny = LiteRtSttMoonshineTiny._();

  /// Parakeet CTC 0.6B (`parakeet-ctc-0.6b`).
  static const parakeetCtc0_6b = LiteRtSttParakeetCtc0_6b._();

  /// Whisper Base (`whisper-base`).
  static const whisperBase = LiteRtSttWhisperBase._();

  /// Whisper Tiny (`whisper-tiny`).
  static const whisperTiny = LiteRtSttWhisperTiny._();

  /// Inflect-Nano-v2 (`inflect-nano-v2`).
  static const inflectNanoV2 = LiteRtTtsInflectNanoV2._();

  /// Matcha-TTS (`matcha-tts`).
  static const matchaTts = LiteRtTtsMatchaTts._();

  /// Qwen3-TTS 0.6B (`qwen3-tts-0.6b`).
  static const qwen3Tts0_6b = LiteRtTtsQwen3Tts0_6b._();
}

/// Moonshine Tiny (`moonshine-tiny`), mit.
final class LiteRtSttMoonshineTiny extends LiteRtSttModel {
  const LiteRtSttMoonshineTiny._()
    : super._(
        id: 'moonshine-tiny',
        displayName: 'Moonshine Tiny',
        family: 'moonshine',
        license: 'mit',
        licenseUrl: 'https://opensource.org/license/mit',
        variants: const [
          _moonshineTiny$f32,
          _moonshineTiny$i8,
          _moonshineTiny$f32NpuMt6877,
          _moonshineTiny$f32NpuMt6878,
          _moonshineTiny$f32NpuMt6879,
          _moonshineTiny$f32NpuMt6897,
          _moonshineTiny$f32NpuMt6983,
          _moonshineTiny$f32NpuMt6985,
          _moonshineTiny$f32NpuMt6989,
          _moonshineTiny$f32NpuMt6991,
          _moonshineTiny$f32NpuMt6993,
          _moonshineTiny$f32NpuMt8171,
          _moonshineTiny$f32NpuMt8188,
          _moonshineTiny$f32NpuMt8189,
          _moonshineTiny$f32NpuSa8255,
          _moonshineTiny$f32NpuSa8295,
          _moonshineTiny$f32NpuSm8450,
          _moonshineTiny$f32NpuSm8550,
          _moonshineTiny$f32NpuSm8650,
          _moonshineTiny$f32NpuSm8750,
          _moonshineTiny$f32NpuSm8850,
        ],
      );

  /// `moonshine_tiny_5s_f32.tflite`, 109 MB.
  LiteRtSttVariant get f32 => _moonshineTiny$f32;

  /// `moonshine_tiny_5s_i8.tflite`, 52 MB.
  LiteRtSttVariant get i8 => _moonshineTiny$i8;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6877.tflite`, 102 MB.
  LiteRtSttVariant get f32NpuMt6877 => _moonshineTiny$f32NpuMt6877;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6878.tflite`, 98 MB.
  LiteRtSttVariant get f32NpuMt6878 => _moonshineTiny$f32NpuMt6878;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6879.tflite`, 102 MB.
  LiteRtSttVariant get f32NpuMt6879 => _moonshineTiny$f32NpuMt6879;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6897.tflite`, 98 MB.
  LiteRtSttVariant get f32NpuMt6897 => _moonshineTiny$f32NpuMt6897;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6983.tflite`, 98 MB.
  LiteRtSttVariant get f32NpuMt6983 => _moonshineTiny$f32NpuMt6983;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6985.tflite`, 98 MB.
  LiteRtSttVariant get f32NpuMt6985 => _moonshineTiny$f32NpuMt6985;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6989.tflite`, 97 MB.
  LiteRtSttVariant get f32NpuMt6989 => _moonshineTiny$f32NpuMt6989;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6991.tflite`, 98 MB.
  LiteRtSttVariant get f32NpuMt6991 => _moonshineTiny$f32NpuMt6991;

  /// `moonshine_tiny_5s_f32_MediaTek_MT6993.tflite`, 95 MB.
  LiteRtSttVariant get f32NpuMt6993 => _moonshineTiny$f32NpuMt6993;

  /// `moonshine_tiny_5s_f32_MediaTek_MT8171.tflite`, 98 MB.
  LiteRtSttVariant get f32NpuMt8171 => _moonshineTiny$f32NpuMt8171;

  /// `moonshine_tiny_5s_f32_MediaTek_MT8188.tflite`, 98 MB.
  LiteRtSttVariant get f32NpuMt8188 => _moonshineTiny$f32NpuMt8188;

  /// `moonshine_tiny_5s_f32_MediaTek_MT8189.tflite`, 98 MB.
  LiteRtSttVariant get f32NpuMt8189 => _moonshineTiny$f32NpuMt8189;

  /// `moonshine_tiny_5s_f32_Qualcomm_SA8255.tflite`, 77 MB.
  LiteRtSttVariant get f32NpuSa8255 => _moonshineTiny$f32NpuSa8255;

  /// `moonshine_tiny_5s_f32_Qualcomm_SA8295.tflite`, 77 MB.
  LiteRtSttVariant get f32NpuSa8295 => _moonshineTiny$f32NpuSa8295;

  /// `moonshine_tiny_5s_f32_Qualcomm_SM8450.tflite`, 77 MB.
  LiteRtSttVariant get f32NpuSm8450 => _moonshineTiny$f32NpuSm8450;

  /// `moonshine_tiny_5s_f32_Qualcomm_SM8550.tflite`, 77 MB.
  LiteRtSttVariant get f32NpuSm8550 => _moonshineTiny$f32NpuSm8550;

  /// `moonshine_tiny_5s_f32_Qualcomm_SM8650.tflite`, 77 MB.
  LiteRtSttVariant get f32NpuSm8650 => _moonshineTiny$f32NpuSm8650;

  /// `moonshine_tiny_5s_f32_Qualcomm_SM8750.tflite`, 77 MB.
  LiteRtSttVariant get f32NpuSm8750 => _moonshineTiny$f32NpuSm8750;

  /// `moonshine_tiny_5s_f32_Qualcomm_SM8850.tflite`, 78 MB.
  LiteRtSttVariant get f32NpuSm8850 => _moonshineTiny$f32NpuSm8850;
}

const _moonshineTiny$f32 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32.tflite',
    sha256: '16f281f1d3d23124e6adbdead8730d46f97cd105c299a9b94608d033c1151b12',
    sizeBytes: 109373140,
    installFilename: 'moonshine_tiny_5s_f32.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
);

const _moonshineTiny$i8 = LiteRtSttVariant._(
  id: 'moonshine-tiny/i8',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_i8.tflite',
    sha256: '97abdeea122d579229091659c24c59d988c6419d453a200f6471241a53b9a9b9',
    sizeBytes: 51936896,
    installFilename: 'moonshine_tiny_5s_i8.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
);

const _moonshineTiny$f32NpuMt6877 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6877',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6877.tflite',
    sha256: 'aa89556f7f16ed4c98405f53e6d7335b9249191d644f12b814439d6cc735fe73',
    sizeBytes: 101947496,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6877.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6877'),
);

const _moonshineTiny$f32NpuMt6878 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6878',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6878.tflite',
    sha256: '955683ce3d968ba6e35cef741911d99e6981b21da6aa65928d7254f63345cbb0',
    sizeBytes: 98265852,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6878.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6878'),
);

const _moonshineTiny$f32NpuMt6879 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6879',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6879.tflite',
    sha256: 'f3cec70fbefc3c0995e3b64ba168531e8f1ac1bca3243889ac527ac60908ed90',
    sizeBytes: 101947496,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6879.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6879'),
);

const _moonshineTiny$f32NpuMt6897 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6897',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6897.tflite',
    sha256: '95d48832839473d145b31e1b2e404d691fd568fe2c3bc0bc9d30c4fbb8989db2',
    sizeBytes: 97534400,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6897.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6897'),
);

const _moonshineTiny$f32NpuMt6983 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6983',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6983.tflite',
    sha256: 'e0f359d0783191a97301e264d7e957310ccfff48ccee224b590334210471a06e',
    sizeBytes: 98265852,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6983.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6983'),
);

const _moonshineTiny$f32NpuMt6985 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6985',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6985.tflite',
    sha256: 'f11b1f48b48bd3969b50e384ee846a9f56045ab64e632e3cd237448b5fa2060f',
    sizeBytes: 98265852,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6985.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6985'),
);

const _moonshineTiny$f32NpuMt6989 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6989',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6989.tflite',
    sha256: '171723ab7a9256d971b3b22c1acd221e7d1836f041c104673c4b9ff9e724004d',
    sizeBytes: 97291772,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6989.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6989'),
);

const _moonshineTiny$f32NpuMt6991 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6991',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6991.tflite',
    sha256: '4dbff02824f8fc67853fb7003987e79fd6ac0ddcf42d0675394f8c99be0ed8a3',
    sizeBytes: 97548784,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6991.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _moonshineTiny$f32NpuMt6993 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt6993',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT6993.tflite',
    sha256: '2821a5f1ac1457d879c581ef5e88949eefcb20ef734b827d8f347bb502b0ad38',
    sizeBytes: 94990336,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT6993.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _moonshineTiny$f32NpuMt8171 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt8171',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT8171.tflite',
    sha256: 'f65ad4e7d0d12e56748bfff2168b49bfec2eb3dc82ffe2d1801368eeab4a41ab',
    sizeBytes: 97548784,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT8171.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8171'),
);

const _moonshineTiny$f32NpuMt8188 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt8188',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT8188.tflite',
    sha256: '9a0632e8b9004256e68d80b2ce760641cafaee1061847082f8a55c8f55daf093',
    sizeBytes: 98265852,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT8188.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8188'),
);

const _moonshineTiny$f32NpuMt8189 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-mt8189',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_MediaTek_MT8189.tflite',
    sha256: '2b263c02ab3ebd3fec8a3253699f74af99b9eecaf990dd93bfec565fddb959cd',
    sizeBytes: 97548784,
    installFilename: 'moonshine_tiny_5s_f32_MediaTek_MT8189.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8189'),
);

const _moonshineTiny$f32NpuSa8255 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-sa8255',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_Qualcomm_SA8255.tflite',
    sha256: '3c44a69c9c767dc4fceaa37760c0044f85668119bb72ccdad90e07000d8c4e17',
    sizeBytes: 77371856,
    installFilename: 'moonshine_tiny_5s_f32_Qualcomm_SA8255.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SA8255'),
);

const _moonshineTiny$f32NpuSa8295 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-sa8295',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_Qualcomm_SA8295.tflite',
    sha256: 'fca5c9a7a785bfae9c3934fb2ce4d9a426dedc6828c002b2f1074ab470ffde13',
    sizeBytes: 77183440,
    installFilename: 'moonshine_tiny_5s_f32_Qualcomm_SA8295.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SA8295'),
);

const _moonshineTiny$f32NpuSm8450 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-sm8450',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_Qualcomm_SM8450.tflite',
    sha256: 'b366e09eec0480cd9205c87add3a16b6cbcc43b19e7148d93413160453e8f7bd',
    sizeBytes: 77208016,
    installFilename: 'moonshine_tiny_5s_f32_Qualcomm_SM8450.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8450'),
);

const _moonshineTiny$f32NpuSm8550 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-sm8550',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_Qualcomm_SM8550.tflite',
    sha256: '14f47ef1267bd0cecd935f803271a723a3a95c27e574c216f483fc94eaebec75',
    sizeBytes: 77371856,
    installFilename: 'moonshine_tiny_5s_f32_Qualcomm_SM8550.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _moonshineTiny$f32NpuSm8650 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-sm8650',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_Qualcomm_SM8650.tflite',
    sha256: '2d1081120e7cb51169bdbeba713d9e93eb8071219600bbb2cc11b5a84dc16fc6',
    sizeBytes: 77392336,
    installFilename: 'moonshine_tiny_5s_f32_Qualcomm_SM8650.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _moonshineTiny$f32NpuSm8750 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-sm8750',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_Qualcomm_SM8750.tflite',
    sha256: 'd45a43cc7fa0daf80d7291b9ec1f290ba655ca5ca86a02f9ca1098ffb66afa0a',
    sizeBytes: 77421008,
    installFilename: 'moonshine_tiny_5s_f32_Qualcomm_SM8750.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _moonshineTiny$f32NpuSm8850 = LiteRtSttVariant._(
  id: 'moonshine-tiny/f32-npu-sm8850',
  modelId: 'moonshine-tiny',
  type: SttModelType.moonshine,
  model: ModelArtifact(
    repo: 'litert-community/moonshine-tiny',
    revision: 'eb73d789d7eebcd4d3d5f1a851692923a8e76763',
    path: 'moonshine_tiny_5s_f32_Qualcomm_SM8850.tflite',
    sha256: 'b2b5ec846a354680cbc82d42e7f0d72d3bbb466b5ce22db65cca5725b3630b86',
    sizeBytes: 77588944,
    installFilename: 'moonshine_tiny_5s_f32_Qualcomm_SM8850.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'moonshine-ai/moonshine',
    revision: '48b4e427b587bcf67797a5be706d6ddc4a298149',
    path: 'ctranslate2/tiny/tokenizer.json',
    sha256: 'ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4',
    sizeBytes: 1985534,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

/// Parakeet CTC 0.6B (`parakeet-ctc-0.6b`), cc-by-4.0.
final class LiteRtSttParakeetCtc0_6b extends LiteRtSttModel {
  const LiteRtSttParakeetCtc0_6b._()
    : super._(
        id: 'parakeet-ctc-0.6b',
        displayName: 'Parakeet CTC 0.6B',
        family: 'parakeet',
        license: 'cc-by-4.0',
        licenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
        variants: const [
          _parakeetCtc0_6b$f32,
          _parakeetCtc0_6b$i8,
          _parakeetCtc0_6b$f32NpuMt6877,
          _parakeetCtc0_6b$f32NpuMt6878,
          _parakeetCtc0_6b$f32NpuMt6879,
          _parakeetCtc0_6b$f32NpuMt6897,
          _parakeetCtc0_6b$f32NpuMt6983,
          _parakeetCtc0_6b$f32NpuMt6985,
          _parakeetCtc0_6b$f32NpuMt6989,
          _parakeetCtc0_6b$f32NpuMt6991,
          _parakeetCtc0_6b$f32NpuMt6993,
          _parakeetCtc0_6b$f32NpuMt8171,
          _parakeetCtc0_6b$f32NpuMt8188,
          _parakeetCtc0_6b$f32NpuMt8189,
          _parakeetCtc0_6b$f32NpuSa8255,
          _parakeetCtc0_6b$f32NpuSa8295,
          _parakeetCtc0_6b$f32NpuSm8450,
          _parakeetCtc0_6b$f32NpuSm8550,
          _parakeetCtc0_6b$f32NpuSm8650,
          _parakeetCtc0_6b$f32NpuSm8750,
          _parakeetCtc0_6b$f32NpuSm8850,
          _parakeetCtc0_6b$f32NpuTensorG3,
        ],
      );

  /// `parakeet_ctc_0.6b_5s_f32.tflite`, 2.35 GB.
  LiteRtSttVariant get f32 => _parakeetCtc0_6b$f32;

  /// `parakeet_ctc_0.6b_5s_i8.tflite`, 596 MB.
  LiteRtSttVariant get i8 => _parakeetCtc0_6b$i8;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6877.tflite`, 1.20 GB.
  LiteRtSttVariant get f32NpuMt6877 => _parakeetCtc0_6b$f32NpuMt6877;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6878.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt6878 => _parakeetCtc0_6b$f32NpuMt6878;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6879.tflite`, 1.20 GB.
  LiteRtSttVariant get f32NpuMt6879 => _parakeetCtc0_6b$f32NpuMt6879;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6897.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt6897 => _parakeetCtc0_6b$f32NpuMt6897;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6983.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt6983 => _parakeetCtc0_6b$f32NpuMt6983;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6985.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt6985 => _parakeetCtc0_6b$f32NpuMt6985;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6989.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt6989 => _parakeetCtc0_6b$f32NpuMt6989;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6991.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt6991 => _parakeetCtc0_6b$f32NpuMt6991;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT6993.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt6993 => _parakeetCtc0_6b$f32NpuMt6993;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT8171.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt8171 => _parakeetCtc0_6b$f32NpuMt8171;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT8188.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt8188 => _parakeetCtc0_6b$f32NpuMt8188;

  /// `parakeet_ctc_0.6b_5s_f32_MediaTek_MT8189.tflite`, 1.18 GB.
  LiteRtSttVariant get f32NpuMt8189 => _parakeetCtc0_6b$f32NpuMt8189;

  /// `parakeet_ctc_0.6b_5s_f32_Qualcomm_SA8255.tflite`, 1.21 GB.
  LiteRtSttVariant get f32NpuSa8255 => _parakeetCtc0_6b$f32NpuSa8255;

  /// `parakeet_ctc_0.6b_5s_f32_Qualcomm_SA8295.tflite`, 1.20 GB.
  LiteRtSttVariant get f32NpuSa8295 => _parakeetCtc0_6b$f32NpuSa8295;

  /// `parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8450.tflite`, 1.20 GB.
  LiteRtSttVariant get f32NpuSm8450 => _parakeetCtc0_6b$f32NpuSm8450;

  /// `parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8550.tflite`, 1.21 GB.
  LiteRtSttVariant get f32NpuSm8550 => _parakeetCtc0_6b$f32NpuSm8550;

  /// `parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8650.tflite`, 1.21 GB.
  LiteRtSttVariant get f32NpuSm8650 => _parakeetCtc0_6b$f32NpuSm8650;

  /// `parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8750.tflite`, 1.21 GB.
  LiteRtSttVariant get f32NpuSm8750 => _parakeetCtc0_6b$f32NpuSm8750;

  /// `parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8850.tflite`, 1.21 GB.
  LiteRtSttVariant get f32NpuSm8850 => _parakeetCtc0_6b$f32NpuSm8850;

  /// `parakeet_ctc_0.6b_5s_f32_Google_Tensor_G3.tflite`, 2 MB.
  LiteRtSttVariant get f32NpuTensorG3 => _parakeetCtc0_6b$f32NpuTensorG3;
}

const _parakeetCtc0_6b$f32 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32.tflite',
    sha256: '8b4c970ac8814d065b1cf54af6c31facbb4ee4dc0c4926fc1ef6c9c13c8e5423',
    sizeBytes: 2348753728,
    installFilename: 'parakeet_ctc_0.6b_5s_f32.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
);

const _parakeetCtc0_6b$i8 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/i8',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_i8.tflite',
    sha256: '3d0799f625842fded4580c9b51d321667f0bd5f334cb325fb1b9051c6534e102',
    sizeBytes: 596365072,
    installFilename: 'parakeet_ctc_0.6b_5s_i8.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
);

const _parakeetCtc0_6b$f32NpuMt6877 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6877',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6877.tflite',
    sha256: '994440d0ae302f860c09481ab5cbca55aba4e7b44133feeb0566f71d6bcf573f',
    sizeBytes: 1196961964,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6877.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6877'),
);

const _parakeetCtc0_6b$f32NpuMt6878 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6878',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6878.tflite',
    sha256: '9d985851b1a7615bafefcb161779a146e8c2a042a7e88adc23bb5c9cbf62b3fc',
    sizeBytes: 1184354080,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6878.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6878'),
);

const _parakeetCtc0_6b$f32NpuMt6879 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6879',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6879.tflite',
    sha256: 'c9ef538f9731e9c96cf03616f2a77bd6c9bb31709634e0dd7f6fe455ab3aeff8',
    sizeBytes: 1196961964,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6879.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6879'),
);

const _parakeetCtc0_6b$f32NpuMt6897 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6897',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6897.tflite',
    sha256: '78310c00eef6c46b1bdfdcaa1fda9d12a70c0e0e449ae3ea7985936a0d5f1f3c',
    sizeBytes: 1178468328,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6897.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6897'),
);

const _parakeetCtc0_6b$f32NpuMt6983 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6983',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6983.tflite',
    sha256: '66dc0a55da54877ea4a562a519caf16ea9551e87bfe9d8c4b339583debcded5d',
    sizeBytes: 1184354080,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6983.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6983'),
);

const _parakeetCtc0_6b$f32NpuMt6985 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6985',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6985.tflite',
    sha256: 'c24dd1fe215698ab24b65685de593116941cd1bb14e902eb4d5002db78c40415',
    sizeBytes: 1184354080,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6985.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6985'),
);

const _parakeetCtc0_6b$f32NpuMt6989 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6989',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6989.tflite',
    sha256: '495d466abe824d54da2d5ff33cfb13b61160cba81c4d7746d0edea02bf46da2a',
    sizeBytes: 1177565528,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6989.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6989'),
);

const _parakeetCtc0_6b$f32NpuMt6991 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6991',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6991.tflite',
    sha256: '1527b411e0331e22dcc5f0b8105e6effc846d43f1fed58644ebcaf6ce18efbe2',
    sizeBytes: 1177686972,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6991.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _parakeetCtc0_6b$f32NpuMt6993 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt6993',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6993.tflite',
    sha256: '8470aeb1639a444b082f4217b533d8da4f14ee5bf715b9d11e9427a261badb57',
    sizeBytes: 1179106896,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT6993.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _parakeetCtc0_6b$f32NpuMt8171 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt8171',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT8171.tflite',
    sha256: '08fe9bee898933e19aa1d9cb5a4e11f33e066220a474a5337126736146f9c8a7',
    sizeBytes: 1177686972,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT8171.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8171'),
);

const _parakeetCtc0_6b$f32NpuMt8188 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt8188',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT8188.tflite',
    sha256: 'eee1c1b381c1772e72033acfbf435cd5a9c1d19e8881cee2886c43a98e6a5524',
    sizeBytes: 1184354080,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT8188.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8188'),
);

const _parakeetCtc0_6b$f32NpuMt8189 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-mt8189',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT8189.tflite',
    sha256: 'b0f37f5828fb7221a6d758954b4f483ac90f0abc6b2f469f3d7a44abe63e4fcc',
    sizeBytes: 1177686972,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_MediaTek_MT8189.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8189'),
);

const _parakeetCtc0_6b$f32NpuSa8255 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-sa8255',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SA8255.tflite',
    sha256: '6dbfe74bbfa6eb19bde24226d54fcefe9018ac46549a35c9461d8db5511d1da6',
    sizeBytes: 1210545648,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SA8255.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SA8255'),
);

const _parakeetCtc0_6b$f32NpuSa8295 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-sa8295',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SA8295.tflite',
    sha256: '9f7f26cdff6ec13fa2455c1afaab204a2c8cab2e553627d74bc90851de5b40cd',
    sizeBytes: 1202861552,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SA8295.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SA8295'),
);

const _parakeetCtc0_6b$f32NpuSm8450 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-sm8450',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8450.tflite',
    sha256: '4ef1a04099a1f6c391e036bf3f8af3bffeb169c3c1a529c34d2ebb6f5a53aa30',
    sizeBytes: 1202873840,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8450.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8450'),
);

const _parakeetCtc0_6b$f32NpuSm8550 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-sm8550',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8550.tflite',
    sha256: 'a702ca925d2b69eef886db4f11186c22c5dd0f610dab992426fcdc89bf3222c5',
    sizeBytes: 1210512880,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8550.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _parakeetCtc0_6b$f32NpuSm8650 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-sm8650',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8650.tflite',
    sha256: '38da51cb643a37248a06bb3d72e18ebb9695444e2c2c6e08cafeca7ea69f5440',
    sizeBytes: 1210516976,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8650.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _parakeetCtc0_6b$f32NpuSm8750 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-sm8750',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8750.tflite',
    sha256: '86ae6549115f817691ba1913d406a8a81fe8c65ad72474b3b6a0edebbe284f4e',
    sizeBytes: 1210320368,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8750.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _parakeetCtc0_6b$f32NpuSm8850 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-sm8850',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8850.tflite',
    sha256: '30e431db44f40f7de869776ad37869e0e3847a30717232b3667e9ce4688352fb',
    sizeBytes: 1210738160,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_Qualcomm_SM8850.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

const _parakeetCtc0_6b$f32NpuTensorG3 = LiteRtSttVariant._(
  id: 'parakeet-ctc-0.6b/f32-npu-tensor-g3',
  modelId: 'parakeet-ctc-0.6b',
  type: SttModelType.parakeet,
  model: ModelArtifact(
    repo: 'litert-community/parakeet-ctc-0.6b',
    revision: 'e3c5b655c0159f79bc90be2d6769fa7cc6386856',
    path: 'parakeet_ctc_0.6b_5s_f32_Google_Tensor_G3.tflite',
    sha256: 'd503174ccdf8bd484b89d13d706cb173d1a442ec90ab81b8d51b95cf0312ef44',
    sizeBytes: 2319024,
    installFilename: 'parakeet_ctc_0.6b_5s_f32_Google_Tensor_G3.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'nvidia/parakeet-ctc-0.6b',
    revision: 'ad09ba1cc62743fbc9814de5d2016fca9096485a',
    path: 'tokenizer.json',
    sha256: 'f3f1dd45c3889ed2b5bf67180caf05f51d7d7e4948c20e5f24d8c24df9cc47aa',
    sizeBytes: 412363,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G3'),
);

/// Whisper Base (`whisper-base`), apache-2.0.
final class LiteRtSttWhisperBase extends LiteRtSttModel {
  const LiteRtSttWhisperBase._()
    : super._(
        id: 'whisper-base',
        displayName: 'Whisper Base',
        family: 'whisper',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [_whisperBase$f32, _whisperBase$i8],
      );

  /// `whisper_base_30s_f32.tflite`, 290 MB.
  LiteRtSttVariant get f32 => _whisperBase$f32;

  /// `whisper_base_30s_i8.tflite`, 77 MB.
  LiteRtSttVariant get i8 => _whisperBase$i8;
}

const _whisperBase$f32 = LiteRtSttVariant._(
  id: 'whisper-base/f32',
  modelId: 'whisper-base',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-base',
    revision: 'ba2c613646edc2b72f5a51fa0b5b0b322e436101',
    path: 'whisper_base_30s_f32.tflite',
    sha256: '83f90febae74f6db2b671d792ce844f93de5dfa6d6743cdba8c7a208c8dd708a',
    sizeBytes: 290082636,
    installFilename: 'whisper_base_30s_f32.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-base',
    revision: 'e37978b90ca9030d5170a5c07aadb050351a65bb',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
);

const _whisperBase$i8 = LiteRtSttVariant._(
  id: 'whisper-base/i8',
  modelId: 'whisper-base',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-base',
    revision: 'ba2c613646edc2b72f5a51fa0b5b0b322e436101',
    path: 'whisper_base_30s_i8.tflite',
    sha256: 'f6943d9d293138850b729e074057956c664891c57837692b1bac4608c4506cd1',
    sizeBytes: 77012960,
    installFilename: 'whisper_base_30s_i8.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-base',
    revision: 'e37978b90ca9030d5170a5c07aadb050351a65bb',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
);

/// Whisper Tiny (`whisper-tiny`), apache-2.0.
final class LiteRtSttWhisperTiny extends LiteRtSttModel {
  const LiteRtSttWhisperTiny._()
    : super._(
        id: 'whisper-tiny',
        displayName: 'Whisper Tiny',
        family: 'whisper',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [
          _whisperTiny$f32,
          _whisperTiny$i8,
          _whisperTiny$f32NpuMt6877,
          _whisperTiny$f32NpuMt6878,
          _whisperTiny$f32NpuMt6879,
          _whisperTiny$f32NpuMt6897,
          _whisperTiny$f32NpuMt6983,
          _whisperTiny$f32NpuMt6985,
          _whisperTiny$f32NpuMt6989,
          _whisperTiny$f32NpuMt6991,
          _whisperTiny$f32NpuMt6993,
          _whisperTiny$f32NpuMt8171,
          _whisperTiny$f32NpuMt8188,
          _whisperTiny$f32NpuMt8189,
          _whisperTiny$f32NpuSa8255,
          _whisperTiny$f32NpuSa8295,
          _whisperTiny$f32NpuSm8450,
          _whisperTiny$f32NpuSm8550,
          _whisperTiny$f32NpuSm8650,
          _whisperTiny$f32NpuSm8750,
          _whisperTiny$f32NpuSm8850,
        ],
      );

  /// `whisper_tiny_30s_f32.tflite`, 151 MB.
  LiteRtSttVariant get f32 => _whisperTiny$f32;

  /// `whisper_tiny_30s_i8.tflite`, 41 MB.
  LiteRtSttVariant get i8 => _whisperTiny$i8;

  /// `whisper_tiny_30s_f32_MediaTek_MT6877.tflite`, 158 MB.
  LiteRtSttVariant get f32NpuMt6877 => _whisperTiny$f32NpuMt6877;

  /// `whisper_tiny_30s_f32_MediaTek_MT6878.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt6878 => _whisperTiny$f32NpuMt6878;

  /// `whisper_tiny_30s_f32_MediaTek_MT6879.tflite`, 158 MB.
  LiteRtSttVariant get f32NpuMt6879 => _whisperTiny$f32NpuMt6879;

  /// `whisper_tiny_30s_f32_MediaTek_MT6897.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt6897 => _whisperTiny$f32NpuMt6897;

  /// `whisper_tiny_30s_f32_MediaTek_MT6983.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt6983 => _whisperTiny$f32NpuMt6983;

  /// `whisper_tiny_30s_f32_MediaTek_MT6985.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt6985 => _whisperTiny$f32NpuMt6985;

  /// `whisper_tiny_30s_f32_MediaTek_MT6989.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt6989 => _whisperTiny$f32NpuMt6989;

  /// `whisper_tiny_30s_f32_MediaTek_MT6991.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt6991 => _whisperTiny$f32NpuMt6991;

  /// `whisper_tiny_30s_f32_MediaTek_MT6993.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt6993 => _whisperTiny$f32NpuMt6993;

  /// `whisper_tiny_30s_f32_MediaTek_MT8171.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt8171 => _whisperTiny$f32NpuMt8171;

  /// `whisper_tiny_30s_f32_MediaTek_MT8188.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt8188 => _whisperTiny$f32NpuMt8188;

  /// `whisper_tiny_30s_f32_MediaTek_MT8189.tflite`, 156 MB.
  LiteRtSttVariant get f32NpuMt8189 => _whisperTiny$f32NpuMt8189;

  /// `whisper_tiny_30s_f32_Qualcomm_SA8255.tflite`, 120 MB.
  LiteRtSttVariant get f32NpuSa8255 => _whisperTiny$f32NpuSa8255;

  /// `whisper_tiny_30s_f32_Qualcomm_SA8295.tflite`, 119 MB.
  LiteRtSttVariant get f32NpuSa8295 => _whisperTiny$f32NpuSa8295;

  /// `whisper_tiny_30s_f32_Qualcomm_SM8450.tflite`, 119 MB.
  LiteRtSttVariant get f32NpuSm8450 => _whisperTiny$f32NpuSm8450;

  /// `whisper_tiny_30s_f32_Qualcomm_SM8550.tflite`, 120 MB.
  LiteRtSttVariant get f32NpuSm8550 => _whisperTiny$f32NpuSm8550;

  /// `whisper_tiny_30s_f32_Qualcomm_SM8650.tflite`, 120 MB.
  LiteRtSttVariant get f32NpuSm8650 => _whisperTiny$f32NpuSm8650;

  /// `whisper_tiny_30s_f32_Qualcomm_SM8750.tflite`, 120 MB.
  LiteRtSttVariant get f32NpuSm8750 => _whisperTiny$f32NpuSm8750;

  /// `whisper_tiny_30s_f32_Qualcomm_SM8850.tflite`, 120 MB.
  LiteRtSttVariant get f32NpuSm8850 => _whisperTiny$f32NpuSm8850;
}

const _whisperTiny$f32 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32.tflite',
    sha256: '0c8f0e2a1855909a0c027b4ac3c586fdd299e2b47bf1a4fdab51191bca1e0e89',
    sizeBytes: 150979184,
    installFilename: 'whisper_tiny_30s_f32.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
);

const _whisperTiny$i8 = LiteRtSttVariant._(
  id: 'whisper-tiny/i8',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_i8.tflite',
    sha256: '6748ac565a228c4a00b18d11ea1e2fd7cead3db6fba94e3f0bf35756b13ba4a9',
    sizeBytes: 41116288,
    installFilename: 'whisper_tiny_30s_i8.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
);

const _whisperTiny$f32NpuMt6877 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6877',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6877.tflite',
    sha256: '5796d1877d6bcc6e307d744bbfd3d1b99f8d517bbe59aa755dffbf0779a0a869',
    sizeBytes: 158197360,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6877.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6877'),
);

const _whisperTiny$f32NpuMt6878 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6878',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6878.tflite',
    sha256: '0db6686f62bb7c473b1d30082703502138707c1da56408d7b49b0ffffd0bc430',
    sizeBytes: 155711828,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6878.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6878'),
);

const _whisperTiny$f32NpuMt6879 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6879',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6879.tflite',
    sha256: '7522769c42180f98c176a232fa500bb34a1ac6e2bf6bcfa09801fcc19961f97e',
    sizeBytes: 158197360,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6879.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6879'),
);

const _whisperTiny$f32NpuMt6897 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6897',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6897.tflite',
    sha256: '462ee83c1d5f58d7fde60de3efad489797f27e159662c772184b4c05f5ef62d9',
    sizeBytes: 155814356,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6897.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6897'),
);

const _whisperTiny$f32NpuMt6983 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6983',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6983.tflite',
    sha256: '3902fd38bb485295c592b0c83edabf540b2e700ac0e0e22b92a55c3d0ee9bafe',
    sizeBytes: 155711828,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6983.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6983'),
);

const _whisperTiny$f32NpuMt6985 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6985',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6985.tflite',
    sha256: '7a3b106d8e820c68967b1465141020b53aec379ac17b1c0c7fccfc99c5eaaa25',
    sizeBytes: 155711828,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6985.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6985'),
);

const _whisperTiny$f32NpuMt6989 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6989',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6989.tflite',
    sha256: 'fcc46116d520b7514e1d423e740e9703d5893f9c455f49a7acd130ef1cf58796',
    sizeBytes: 155634208,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6989.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6989'),
);

const _whisperTiny$f32NpuMt6991 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6991',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6991.tflite',
    sha256: '539386c03dcac03f1409d672a9805973f5afc93a6f1d0e0d808570d16d111aa9',
    sizeBytes: 155717804,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6991.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6991'),
);

const _whisperTiny$f32NpuMt6993 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt6993',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT6993.tflite',
    sha256: '8b0d0267c6c874705eff82124cebb7cabd7a843e775973bf15c5f650a59efb26',
    sizeBytes: 155720152,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT6993.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt6993'),
);

const _whisperTiny$f32NpuMt8171 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt8171',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT8171.tflite',
    sha256: '6128e86917d78aca67b1f4ed0dcbe866f0cc8329593e72bca38c94fa6bfc7603',
    sizeBytes: 155717804,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT8171.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8171'),
);

const _whisperTiny$f32NpuMt8188 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt8188',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT8188.tflite',
    sha256: '208de1204756eb158dd1f0db971e850ad44a537521e0ab7bad61053d5f154939',
    sizeBytes: 155711828,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT8188.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8188'),
);

const _whisperTiny$f32NpuMt8189 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-mt8189',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_MediaTek_MT8189.tflite',
    sha256: '948c2a1255e580506b619e704d22ea1c1415e17cc340c292a0b9cfc056d0b81f',
    sizeBytes: 155717804,
    installFilename: 'whisper_tiny_30s_f32_MediaTek_MT8189.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'mt8189'),
);

const _whisperTiny$f32NpuSa8255 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-sa8255',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_Qualcomm_SA8255.tflite',
    sha256: '09115cde157641170fa80875456e07cfcdabcdfdb560478e0d601a4d550d2d0f',
    sizeBytes: 119933264,
    installFilename: 'whisper_tiny_30s_f32_Qualcomm_SA8255.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SA8255'),
);

const _whisperTiny$f32NpuSa8295 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-sa8295',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_Qualcomm_SA8295.tflite',
    sha256: '628844c285638c4cb948ee8a22bde86062c6bb4be50cd924c4d5a71843607f6d',
    sizeBytes: 118782288,
    installFilename: 'whisper_tiny_30s_f32_Qualcomm_SA8295.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SA8295'),
);

const _whisperTiny$f32NpuSm8450 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-sm8450',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_Qualcomm_SM8450.tflite',
    sha256: 'ff876f01485f7b0140b5061056e3847e35e1a67b25166e5be9f7a9dc5bd95cab',
    sizeBytes: 118831440,
    installFilename: 'whisper_tiny_30s_f32_Qualcomm_SM8450.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8450'),
);

const _whisperTiny$f32NpuSm8550 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-sm8550',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_Qualcomm_SM8550.tflite',
    sha256: 'c00cdd5ced2c12682754a89069e32dff3ca465e5aa648ec1d0b717330a8ee207',
    sizeBytes: 119949648,
    installFilename: 'whisper_tiny_30s_f32_Qualcomm_SM8550.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8550'),
);

const _whisperTiny$f32NpuSm8650 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-sm8650',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_Qualcomm_SM8650.tflite',
    sha256: 'e72a316010b502e9607f53ad76eb6097b445d1272272611203b8638af04336e0',
    sizeBytes: 119859536,
    installFilename: 'whisper_tiny_30s_f32_Qualcomm_SM8650.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8650'),
);

const _whisperTiny$f32NpuSm8750 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-sm8750',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_Qualcomm_SM8750.tflite',
    sha256: '6280afec96131a07a1af111684380bf1b6bfaf3fbba2001433e9205d3d887144',
    sizeBytes: 119916880,
    installFilename: 'whisper_tiny_30s_f32_Qualcomm_SM8750.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
);

const _whisperTiny$f32NpuSm8850 = LiteRtSttVariant._(
  id: 'whisper-tiny/f32-npu-sm8850',
  modelId: 'whisper-tiny',
  type: SttModelType.whisper,
  model: ModelArtifact(
    repo: 'litert-community/whisper-tiny',
    revision: 'd0662bbcb13106e6f740632b9ff961c8e22f7a13',
    path: 'whisper_tiny_30s_f32_Qualcomm_SM8850.tflite',
    sha256: '67207435852ac403b90dcb60f57631526f528ceb88ff074993816c77a2f7e147',
    sizeBytes: 120109392,
    installFilename: 'whisper_tiny_30s_f32_Qualcomm_SM8850.tflite',
  ),
  tokenizer: ModelArtifact(
    repo: 'openai/whisper-tiny',
    revision: '169d4a4341b33bc18d8881c4b69c2e104e1cc0af',
    path: 'tokenizer.json',
    sha256: '27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566',
    sizeBytes: 2480466,
    installFilename: 'tokenizer.json',
  ),
  npuTarget: LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850'),
);

/// Inflect-Nano-v2 (`inflect-nano-v2`), apache-2.0.
final class LiteRtTtsInflectNanoV2 extends LiteRtTtsModel {
  const LiteRtTtsInflectNanoV2._()
    : super._(
        id: 'inflect-nano-v2',
        displayName: 'Inflect-Nano-v2',
        family: 'inflect',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [_inflectNanoV2$bundle],
      );

  /// 6 files, 36 MB.
  LiteRtTtsVariant get bundle => _inflectNanoV2$bundle;
}

const _inflectNanoV2$bundle = LiteRtTtsVariant._(
  id: 'inflect-nano-v2/bundle',
  modelId: 'inflect-nano-v2',
  type: TtsModelType.inflect,
  baseUrl:
      'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/4f03cf68b5447ab22cdfa8bd052a78c6c9763891/',
  files: [
    ModelArtifact(
      repo: 'sasha-denisov/inflect-nano-v2-litert',
      revision: '4f03cf68b5447ab22cdfa8bd052a78c6c9763891',
      path: 'inflect_text_encoder_fp16.tflite',
      sha256:
          'c778f516b8557c69734f4d4308084c411b8d3a4575566385d163209bf504f083',
      sizeBytes: 1782268,
      installFilename: 'inflect_text_encoder_fp16.tflite',
    ),
    ModelArtifact(
      repo: 'sasha-denisov/inflect-nano-v2-litert',
      revision: '4f03cf68b5447ab22cdfa8bd052a78c6c9763891',
      path: 'inflect_decoder_fp16.tflite',
      sha256:
          '155d5072f104248983015e82d1b90968ab2e87bd7f96c4016928fc83231efbd0',
      sizeBytes: 6375948,
      installFilename: 'inflect_decoder_fp16.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: 'ee32148115e2dd25913f70b1d71b587c73e0866e',
      path: 'config.json',
      sha256:
          '7363e9e4dda1613aebff7005f2e8c0c76d9b0a1cac31de0f3483bef3089c6906',
      sizeBytes: 2071,
      installFilename: 'config.json',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: 'ee32148115e2dd25913f70b1d71b587c73e0866e',
      path: 'g2p_dict.txt.gz',
      sha256:
          '5b3493a8cd4d20b72c7b91415afaf3f32335ebd81f349698e1cedc898c59f979',
      sizeBytes: 1762038,
      installFilename: 'g2p_dict.txt.gz',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: 'ee32148115e2dd25913f70b1d71b587c73e0866e',
      path: 'dp_g2p_matcha_fp16.tflite',
      sha256:
          '6e4b481f6874dfabc32ce73bf6f0ea1ba6ab5986ee6f76a27779364be8a53c73',
      sizeBytes: 25785872,
      installFilename: 'dp_g2p_matcha_fp16.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: 'ee32148115e2dd25913f70b1d71b587c73e0866e',
      path: 'g2p_meta.json',
      sha256:
          '7b87bfeaaa072be236e8491d771b0cb97cc92c3e5d83e3558fff8849868810f5',
      sizeBytes: 1904,
      installFilename: 'g2p_meta.json',
    ),
  ],
);

/// Matcha-TTS (`matcha-tts`), mit.
final class LiteRtTtsMatchaTts extends LiteRtTtsModel {
  const LiteRtTtsMatchaTts._()
    : super._(
        id: 'matcha-tts',
        displayName: 'Matcha-TTS',
        family: 'matcha',
        license: 'mit',
        licenseUrl: 'https://opensource.org/license/mit',
        variants: const [_matchaTts$bundle],
      );

  /// 8 files, 94 MB.
  LiteRtTtsVariant get bundle => _matchaTts$bundle;
}

const _matchaTts$bundle = LiteRtTtsVariant._(
  id: 'matcha-tts/bundle',
  modelId: 'matcha-tts',
  type: TtsModelType.matcha,
  baseUrl:
      'https://huggingface.co/litert-community/Matcha-TTS/resolve/6dd0418da3204f5704d7afb66722d795e84fcbe5/',
  files: [
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: '6dd0418da3204f5704d7afb66722d795e84fcbe5',
      path: 'matcha_textenc_fp16.tflite',
      sha256:
          'adf2642699b09a9f0cc302a64396554ac698401d93cffad4462792d6df8589a5',
      sizeBytes: 14774576,
      installFilename: 'matcha_textenc_fp16.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: '6dd0418da3204f5704d7afb66722d795e84fcbe5',
      path: 'matcha_decoder_fp16.tflite',
      sha256:
          '2c2e70235f0daaa9d82366416aad69b4f6e916f080a2da8b4b3b759f7cfd3069',
      sizeBytes: 22614528,
      installFilename: 'matcha_decoder_fp16.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: '6dd0418da3204f5704d7afb66722d795e84fcbe5',
      path: 'matcha_vocoder_fp16.tflite',
      sha256:
          '7d0b4d975eb1558d02c0fa781b329f5fc650cfee6bffcf311de4b190d62020ac',
      sizeBytes: 28973856,
      installFilename: 'matcha_vocoder_fp16.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: '6dd0418da3204f5704d7afb66722d795e84fcbe5',
      path: 'dp_g2p_matcha_fp16.tflite',
      sha256:
          '6e4b481f6874dfabc32ce73bf6f0ea1ba6ab5986ee6f76a27779364be8a53c73',
      sizeBytes: 25785872,
      installFilename: 'dp_g2p_matcha_fp16.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: '6dd0418da3204f5704d7afb66722d795e84fcbe5',
      path: 'g2p_dict.txt.gz',
      sha256:
          '5b3493a8cd4d20b72c7b91415afaf3f32335ebd81f349698e1cedc898c59f979',
      sizeBytes: 1762038,
      installFilename: 'g2p_dict.txt.gz',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: '6dd0418da3204f5704d7afb66722d795e84fcbe5',
      path: 'emb.bin',
      sha256:
          '18be34cda4afa1f59b9fb0b80d03f048bd9dd650e29846e4c6467e0b614c1ee7',
      sizeBytes: 136704,
      installFilename: 'emb.bin',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: '6dd0418da3204f5704d7afb66722d795e84fcbe5',
      path: 'config.json',
      sha256:
          '7363e9e4dda1613aebff7005f2e8c0c76d9b0a1cac31de0f3483bef3089c6906',
      sizeBytes: 2071,
      installFilename: 'config.json',
    ),
    ModelArtifact(
      repo: 'litert-community/Matcha-TTS',
      revision: '6dd0418da3204f5704d7afb66722d795e84fcbe5',
      path: 'g2p_meta.json',
      sha256:
          '7b87bfeaaa072be236e8491d771b0cb97cc92c3e5d83e3558fff8849868810f5',
      sizeBytes: 1904,
      installFilename: 'g2p_meta.json',
    ),
  ],
);

/// Qwen3-TTS 0.6B (`qwen3-tts-0.6b`), apache-2.0.
final class LiteRtTtsQwen3Tts0_6b extends LiteRtTtsModel {
  const LiteRtTtsQwen3Tts0_6b._()
    : super._(
        id: 'qwen3-tts-0.6b',
        displayName: 'Qwen3-TTS 0.6B',
        family: 'qwen3',
        license: 'apache-2.0',
        licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
        variants: const [_qwen3Tts0_6b$bundle],
      );

  /// 9 files, 1.89 GB.
  LiteRtTtsVariant get bundle => _qwen3Tts0_6b$bundle;
}

const _qwen3Tts0_6b$bundle = LiteRtTtsVariant._(
  id: 'qwen3-tts-0.6b/bundle',
  modelId: 'qwen3-tts-0.6b',
  type: TtsModelType.qwen3,
  baseUrl:
      'https://huggingface.co/litert-community/Qwen3-TTS-12Hz-0.6B-Base/resolve/5ad41057956abe19b6a3b78e677a0356ea606663/',
  files: [
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'talker_int4.tflite',
      sha256:
          'e03df54e73ed1f88b2ae6d47bbf82dd64ea90a3620d753a0f3c8d6a8d60848db',
      sizeBytes: 255998768,
      installFilename: 'talker_int4.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'mtp_fp32.tflite',
      sha256:
          '7cc01b402637c850432ee9171c9cc9103813c0406b70c455ea8752833adf1f03',
      sizeBytes: 440526692,
      installFilename: 'mtp_fp32.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'codec_decoder_fp32.tflite',
      sha256:
          '491e10c263c498d9f305ae655dbcce18455d54e44421480afe2d7da2b07da39d',
      sizeBytes: 456820324,
      installFilename: 'codec_decoder_fp32.tflite',
    ),
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'tokenizer.json',
      sha256:
          'a7d41145c408f3062e824f965be1c29854cd809e111cdf8170aa8b0bcd5d1fab',
      sizeBytes: 11424262,
      installFilename: 'tokenizer.json',
    ),
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'tables/text_embedding_fp16.npy',
      sha256:
          '6fab9de0a8bc144aa3efefdacb5e8292b8499a9ae1d60fcee240bac528b7441e',
      sizeBytes: 622329984,
      installFilename: 'text_embedding_fp16.npy',
    ),
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'tables/text_projection_fp32.npz',
      sha256:
          'ebb0f6a7aaacdbc903e825e33480b2da4d4b71c43c90acb0e89988049c77c100',
      sizeBytes: 25179078,
      installFilename: 'text_projection_fp32.npz',
    ),
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'tables/codec_embedding_fp32.npy',
      sha256:
          '47fa9e30f98b1528fc9b332d314f22a32fa33e187509a4d3537f8b2c31199e39',
      sizeBytes: 12583040,
      installFilename: 'codec_embedding_fp32.npy',
    ),
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'tables/mtp_embeddings_fp16.npy',
      sha256:
          'fea581b6a04f1cbec20b49511c36a00011411ccfba31f89b7571f82fe6b36706',
      sizeBytes: 62914688,
      installFilename: 'mtp_embeddings_fp16.npy',
    ),
    ModelArtifact(
      repo: 'litert-community/Qwen3-TTS-12Hz-0.6B-Base',
      revision: '5ad41057956abe19b6a3b78e677a0356ea606663',
      path: 'voices/demo_speaker.npy',
      sha256:
          'b1527f54f68f44ca98bfddcaa9dc0018deb2db62590c9d2699efabbd0dfc1c3c',
      sizeBytes: 4224,
      installFilename: 'demo_speaker.npy',
    ),
  ],
);
