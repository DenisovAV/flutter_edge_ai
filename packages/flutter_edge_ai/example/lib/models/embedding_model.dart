import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show EmbeddingModality, NpuVendor, PreferredBackend;

import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtEmbedderVariant, LiteRtEmbedders;

import 'base_model.dart';

// The model registry's builds (LiteRtEmbedders), as functions: a variant is
// read through a getter, which is not a constant. Their files, install
// names, profile ids, sizes and NPU targets are fixed there; a published
// one never changes, so an installed model and a stored index keep working.
LiteRtEmbedderVariant _embeddingGemma1024() =>
    LiteRtEmbedders.embeddinggemma300m.seq1024;
LiteRtEmbedderVariant _embeddingGemma2048() =>
    LiteRtEmbedders.embeddinggemma300m.seq2048;
LiteRtEmbedderVariant _embeddingGemma256() =>
    LiteRtEmbedders.embeddinggemma300m.seq256;
LiteRtEmbedderVariant _embeddingGemma512() =>
    LiteRtEmbedders.embeddinggemma300m.seq512;
LiteRtEmbedderVariant _embeddingGemma2Text270m() =>
    LiteRtEmbedders.embeddinggemma2Text270m.generic;
LiteRtEmbedderVariant _embeddingGemma2TextVision440m() =>
    LiteRtEmbedders.embeddinggemma2TextVision440m.generic;
LiteRtEmbedderVariant _embeddingGemma2TextVisionAudio740m() =>
    LiteRtEmbedders.embeddinggemma2_740m.generic;
LiteRtEmbedderVariant _embeddingGemma2Text270mSm8850() =>
    LiteRtEmbedders.embeddinggemma2Text270m.npuSm8850;
LiteRtEmbedderVariant _embeddingGemma2TextVision440mSm8850() =>
    LiteRtEmbedders.embeddinggemma2TextVision440m.npuSm8850;
LiteRtEmbedderVariant _embeddingGemma2TextVisionAudio740mSm8850() =>
    LiteRtEmbedders.embeddinggemma2_740m.npuSm8850;
LiteRtEmbedderVariant _embeddingGemma2Text270mSm8650() =>
    LiteRtEmbedders.embeddinggemma2Text270m.npuSm8650;
LiteRtEmbedderVariant _embeddingGemma2TextVision440mSm8650() =>
    LiteRtEmbedders.embeddinggemma2TextVision440m.npuSm8650;
LiteRtEmbedderVariant _embeddingGemma2Text270mQcs8275() =>
    LiteRtEmbedders.embeddinggemma2Text270m.npuQcs8275;
LiteRtEmbedderVariant _embeddingGemma2TextVision440mQcs8275() =>
    LiteRtEmbedders.embeddinggemma2TextVision440m.npuQcs8275;
LiteRtEmbedderVariant _embeddingGemma2Text270mPtl() =>
    LiteRtEmbedders.embeddinggemma2Text270m.npuPtl;
LiteRtEmbedderVariant _embeddingGemma2TextVision440mPtl() =>
    LiteRtEmbedders.embeddinggemma2TextVision440m.npuPtl;
LiteRtEmbedderVariant _embeddingGemma2Text270mTensorG6() =>
    LiteRtEmbedders.embeddinggemma2Text270m.npuTensorG6;
LiteRtEmbedderVariant _embeddingGemma2TextVision440mTensorG6() =>
    LiteRtEmbedders.embeddinggemma2TextVision440m.npuTensorG6;
LiteRtEmbedderVariant _embeddingGemma2Text270mMt6991() =>
    LiteRtEmbedders.embeddinggemma2Text270m.npuMt6991;
LiteRtEmbedderVariant _gecko64() => LiteRtEmbedders.gecko110mEn.seq64Quant;
LiteRtEmbedderVariant _gecko256() => LiteRtEmbedders.gecko110mEn.seq256Quant;
LiteRtEmbedderVariant _gecko512() => LiteRtEmbedders.gecko110mEn.seq512Quant;

/// Vision tokens per EmbeddingGemma 2 image in this app: the
/// `LiteRtEmbeddingBackend` default, registered in gemma_bootstrap.dart.
const kExampleVisionTokensPerImage = 140;

/// The profile id of an image index over [textProfileId]'s embedding space:
/// image vectors also depend on the vision budget (R5 §5.6).
String imageIndexProfileId(String textProfileId) =>
    '$textProfileId-vis$kExampleVisionTokensPerImage';

enum EmbeddingModel implements EmbeddingModelInterface {
  // EmbeddingGemma-300M models (all generate 768D embeddings)
  // Numbers in names indicate max sequence length, not embedding dimension
  embeddingGemma1024(
    variant: _embeddingGemma1024,
    displayName: 'EmbeddingGemma (seq=1024)',
    size: '183MB',
  ),

  embeddingGemma2048(
    variant: _embeddingGemma2048,
    displayName: 'EmbeddingGemma (seq=2048)',
    size: '196MB',
  ),

  embeddingGemma256(
    variant: _embeddingGemma256,
    displayName: 'EmbeddingGemma (seq=256)',
    size: '179MB',
  ),

  // Local model for fast testing (no auth required)
  // Files are in example/assets/models/
  // AssetSource works in both debug and production builds
  localEmbeddingGemma256(
    url: 'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite',
    tokenizerUrl: 'assets/models/sentencepiece.model',
    filename:
        'embeddinggemma-300M_seq256_mixed-precision__example-asset-v1.tflite',
    tokenizerFilename:
        'embeddinggemma-300m-seq256__sentencepiece__example-asset-v1.model',
    displayName: '🚀 Local EmbeddingGemma (seq=256)',
    size: '171MB (Local - No Auth)',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 256,
    sourceType: ModelSourceType
        .asset, // Use Flutter assets - works in debug and production
    // Kept separate from the hosted seq=256 profile until the checked-in asset
    // is proven byte-identical to that immutable Hugging Face revision.
    ragProfileId:
        'embeddinggemma-300m-seq256-mp-example-asset-v1-retrieval-prefix-meanpool-l2-v1',
  ),

  embeddingGemma512(
    variant: _embeddingGemma512,
    displayName: 'EmbeddingGemma (seq=512)',
    size: '179MB',
  ),

  // EmbeddingGemma 2 text (270M): ONE self-contained `.litertlm` bundle that
  // carries its own tokenizer, so there is no tokenizer file. Ungated.
  // Android, iOS, macOS, Linux, Windows (CPU), and the web (WebGPU, since
  // flutter_edge_ai_litertlm 1.13.1; no CPU path there). Input cap 1024 tokens
  // (prefix, BOS and EOS included) — keep RAG chunks at 512 or below.
  embeddingGemma2Text270m(
    variant: _embeddingGemma2Text270m,
    displayName: 'EmbeddingGemma 2 Text (270M)',
    size: '165MB',
  ),

  // EmbeddingGemma 2 Text + Vision (440M): the 270M's text tower (the same
  // bytes, so the same text vectors and the same text profile id) plus a
  // vision encoder, so it embeds images too — the Image Search screen needs
  // it. Ungated; every platform, the web included. What the images cost over
  // the 270M (macOS figures): 388 MB on disk instead of 165, a 218 MB vision
  // weight cache written at every load, even for text-only use (native; the
  // web keeps no weight cache), and about 385 MB more RAM from the first image
  // on. For text alone the 270M is the better choice.
  embeddingGemma2TextVision440m(
    variant: _embeddingGemma2TextVision440m,
    displayName: 'EmbeddingGemma 2 Text + Vision (440M)',
    size: '388MB',
  ),

  // EmbeddingGemma 2 (740M): the 440M's text and vision towers (the same
  // bytes, so the same text and image vectors and the same profile ids) plus
  // an audio encoder, so it also embeds audio (WAV, MP3, FLAC; about 25
  // tokens per second, so a clip of up to about 40 s fits the 1024-token cap)
  // and combinations — a photo with its caption, a clip with a note — in one
  // vector, natively and on the web (WebGPU, litertlm 1.13.2). Ungated. On top
  // of the 440M (macOS figures): 485 MB on disk, a further 95 MB audio weight
  // cache written at every load (385 MB of caches in all, even for text-only
  // use), and more RAM on the first clip. Audio vectors do not depend on the
  // vision budget, so an audio index keeps the text id.
  embeddingGemma2TextVisionAudio740m(
    variant: _embeddingGemma2TextVisionAudio740m,
    displayName: 'EmbeddingGemma 2 Text + Vision + Audio (740M)',
    size: '485MB',
  ),

  // EmbeddingGemma 2 compiled for one Qualcomm NPU (Google's per-SoC
  // bundles, same repos and revisions as above). They run ONLY on that SoC's
  // NPU — `getActiveEmbedder(preferredBackend: PreferredBackend.npu)` on
  // Qualcomm Android or Qualcomm Linux arm64, in an app built with
  // `qualcomm_npu: true` (this one is) — and are refused everywhere else, so
  // the list shows them on Android and Linux only. SM8850 (Snapdragon 8 Elite
  // Gen 5), SM8650 (Snapdragon 8 Gen 3) and QCS8275 (VENTUNO Q) are the ones
  // verified; Google also publishes SM8550, SM8750, Tensor G5/G6 and MediaTek
  // MT6991/MT6993 builds (the Tensor and MediaTek ones below), and Intel PTL
  // (below). Their vectors are not the CPU
  // bundle's: each SoC has its own profile id — the CPU text id plus
  // `-npu-<soc>`. The 270m and the 440m of one SoC carry byte-identical text
  // towers (sha256 prefix aaae57a31475 for SM8850, d6db62a3616b for SM8650,
  // 685619825c4e for QCS8275), so they share it, as the generic bundles do.
  embeddingGemma2Text270mSm8850(
    variant: _embeddingGemma2Text270mSm8850,
    displayName: 'EmbeddingGemma 2 Text (270M) · Qualcomm SM8850 NPU',
    size: '202MB',
  ),

  embeddingGemma2TextVision440mSm8850(
    variant: _embeddingGemma2TextVision440mSm8850,
    displayName: 'EmbeddingGemma 2 Text + Vision (440M) · Qualcomm SM8850 NPU',
    size: '463MB',
  ),

  // The 740M for SM8850 carries the 440M SM8850's text and vision towers
  // (the same bytes: text aaae57a31475, vision 231495aaa9a3) and the generic
  // bundle's audio encoder, so it shares their ids. Run on a Galaxy S26+
  // (SM8850, DDP): text and images on the NPU, audio on the CPU.
  embeddingGemma2TextVisionAudio740mSm8850(
    variant: _embeddingGemma2TextVisionAudio740mSm8850,
    displayName:
        'EmbeddingGemma 2 Text + Vision + Audio (740M) · Qualcomm SM8850 NPU',
    size: '559MB',
  ),

  embeddingGemma2Text270mSm8650(
    variant: _embeddingGemma2Text270mSm8650,
    displayName: 'EmbeddingGemma 2 Text (270M) · Qualcomm SM8650 NPU',
    size: '208MB',
  ),

  embeddingGemma2TextVision440mSm8650(
    variant: _embeddingGemma2TextVision440mSm8650,
    displayName: 'EmbeddingGemma 2 Text + Vision (440M) · Qualcomm SM8650 NPU',
    size: '466MB',
  ),

  embeddingGemma2Text270mQcs8275(
    variant: _embeddingGemma2Text270mQcs8275,
    displayName: 'EmbeddingGemma 2 Text (270M) · Qualcomm QCS8275 NPU',
    size: '208MB',
  ),

  embeddingGemma2TextVision440mQcs8275(
    variant: _embeddingGemma2TextVision440mQcs8275,
    displayName: 'EmbeddingGemma 2 Text + Vision (440M) · Qualcomm QCS8275 NPU',
    size: '466MB',
  ),

  // EmbeddingGemma 2 compiled for the Intel Panther Lake NPU (Google's
  // `…_Intel_PTL` bundles, same repos and revisions; stamped IntelOpenVINO /
  // PTL). They run ONLY there — `getActiveEmbedder(preferredBackend:
  // PreferredBackend.npu)` on Windows x64, with the Intel stack every Windows
  // build carries beside the executable — so the list shows them on Windows
  // only.
  // Their own profile id, the CPU text id plus `-npu-ptl`; the 270m and the
  // 440m carry byte-identical text towers (sha256 prefix 84f8711d914c; the
  // tokenizer and token-embedding sections match too), so they share it.
  embeddingGemma2Text270mPtl(
    variant: _embeddingGemma2Text270mPtl,
    displayName: 'EmbeddingGemma 2 Text (270M) · Intel Panther Lake NPU',
    size: '317MB',
  ),

  embeddingGemma2TextVision440mPtl(
    variant: _embeddingGemma2TextVision440mPtl,
    displayName:
        'EmbeddingGemma 2 Text + Vision (440M) · Intel Panther Lake NPU',
    size: '752MB',
  ),

  // EmbeddingGemma 2 compiled for the Google Tensor G6 NPU (Google's
  // `…_Google_Tensor_G6` bundles, same repos and revisions; stamped Google).
  // They run ONLY there — `getActiveEmbedder(preferredBackend:
  // PreferredBackend.npu)` on a Pixel with Tensor G6 and Android 16 or later,
  // in an app built with `google_tensor_npu: true` (this one is) — so the list
  // shows them on Android only. Run on a Pixel 11 with a debug build. Their own
  // profile id, the CPU text id plus `-npu-tensor_g6`; the 270m and the 440m
  // carry byte-identical text towers (sha256 prefix 4130ab1123ab; the
  // tokenizer and token-embedding sections match too), so they share it.
  embeddingGemma2Text270mTensorG6(
    variant: _embeddingGemma2Text270mTensorG6,
    displayName: 'EmbeddingGemma 2 Text (270M) · Google Tensor G6 NPU',
    size: '200MB',
  ),

  embeddingGemma2TextVision440mTensorG6(
    variant: _embeddingGemma2TextVision440mTensorG6,
    displayName: 'EmbeddingGemma 2 Text + Vision (440M) · Google Tensor G6 NPU',
    size: '513MB',
  ),

  // EmbeddingGemma 2 compiled for the MediaTek MT6991 (Dimensity 9400) NPU
  // (Google's `…_MediaTek_MT6991` bundle, same repo and revision; stamped
  // MediaTek / mt6991). It runs ONLY there — `getActiveEmbedder(
  // preferredBackend: PreferredBackend.npu)` on an MT6991 phone whose vendor
  // exposes NeuroPilot to apps, in an app built with `mediatek_npu: true`
  // (this one is) — so the list shows it on Android only. Not run on an
  // MT6991 yet. Its own profile id, the CPU text id plus `-npu-mt6991`.
  embeddingGemma2Text270mMt6991(
    variant: _embeddingGemma2Text270mMt6991,
    displayName: 'EmbeddingGemma 2 Text (270M) · MediaTek MT6991 NPU',
    size: '416MB',
  ),

  // Gecko-110m models (generate 768D embeddings)
  // Gecko 64 is the smallest and fastest model - ideal for short queries
  gecko64(variant: _gecko64, displayName: 'Gecko (seq=64)', size: '112MB'),

  gecko256(variant: _gecko256, displayName: 'Gecko (seq=256)', size: '114MB'),

  gecko512(variant: _gecko512, displayName: 'Gecko (seq=512)', size: '120MB');

  /// The registry build this entry installs; null for the bundled asset.
  final LiteRtEmbedderVariant Function()? _variant;

  /// The registry build this entry installs; null for the bundled asset.
  LiteRtEmbedderVariant? get catalogVariant => _variant?.call();

  final String? _url;
  final String? _tokenizerUrl;
  final String? _filename;
  final String? _tokenizerFilename;
  final int? _dimension;
  final int? _maxSeqLen;
  final String? _ragProfileId;

  @override
  String get url => catalogVariant?.model.url ?? _url!;
  @override
  String? get tokenizerUrl =>
      catalogVariant == null ? _tokenizerUrl : catalogVariant!.tokenizer?.url;
  @override
  String get filename => catalogVariant?.model.installFilename ?? _filename!;
  @override
  String? get tokenizerFilename => catalogVariant == null
      ? _tokenizerFilename
      : catalogVariant!.tokenizer?.installFilename;
  @override
  final String displayName;
  @override
  final String size;
  @override
  int get dimension => catalogVariant?.dimension ?? _dimension!;
  @override
  int get maxSeqLen => catalogVariant?.maxInputTokens ?? _maxSeqLen!;
  @override
  bool get needsAuth => catalogVariant?.model.gated ?? false;
  @override
  final ModelSourceType sourceType;

  /// Stable identity of the complete embedding space used by the RAG demo,
  /// fixed by the registry for a published build: weights, tokenizer, task
  /// prefixes, pooling and normalization. Never derived from a mutable URL,
  /// a local path or the vector dimension.
  String get ragProfileId => catalogVariant?.ragProfileId ?? _ragProfileId!;

  /// SHA-256 of the pinned model file. The EmbeddingGemma 2 integration
  /// suite checks the installed bundle against it.
  String? get sha256 => catalogVariant?.model.sha256;

  /// Whether the model embeds images (a bundle with a vision encoder).
  bool get embedsImages =>
      catalogVariant?.modalities.contains(EmbeddingModality.image) ?? false;

  /// Whether the model embeds audio (a bundle with an audio encoder; native
  /// platforms, and the web from flutter_edge_ai_litertlm 1.13.2).
  bool get embedsAudio =>
      catalogVariant?.modalities.contains(EmbeddingModality.audio) ?? false;

  /// The SoC a per-SoC bundle is compiled for, as its compiler stamped it
  /// (`SM8850`, `PTL`, `Tensor_G6`), or null for a model that runs on CPU.
  String? get npuSoc => catalogVariant?.npuTarget?.soc;

  /// Whose NPU [npuSoc] is. Decides where the bundle is listed
  /// ([listedEmbeddingModels]).
  EmbeddingNpuVendor get npuVendor =>
      switch (catalogVariant?.npuTarget?.npuVendor) {
        NpuVendor.intel => EmbeddingNpuVendor.intel,
        NpuVendor.googleTensor => EmbeddingNpuVendor.googleTensor,
        NpuVendor.mediatek => EmbeddingNpuVendor.mediatek,
        _ => EmbeddingNpuVendor.qualcomm,
      };

  /// What to pass `getActiveEmbedder(preferredBackend:)` for this model: npu
  /// for a per-SoC bundle (it runs nowhere else), null — the default, CPU —
  /// for every other.
  PreferredBackend? get embedderBackend =>
      npuSoc == null ? null : PreferredBackend.npu;

  /// The profile of an IMAGE index built with this model, or null when it
  /// embeds no images: the text id plus the vision budget the example
  /// registers (`-vis140`). Image vectors depend on that budget, text vectors
  /// do not, so text stores keep [ragProfileId].
  String? get imageRagProfileId =>
      embedsImages ? imageIndexProfileId(ragProfileId) : null;

  /// Constructor
  const EmbeddingModel({
    LiteRtEmbedderVariant Function()? variant,
    String? url,
    String? tokenizerUrl,
    String? filename,
    String? tokenizerFilename,
    required this.displayName,
    required this.size,
    int? dimension,
    int? maxSeqLen,
    String? ragProfileId,
    this.sourceType = ModelSourceType
        .network, // Default to network for backward compatibility
  }) : assert(
         variant != null ||
             (url != null &&
                 filename != null &&
                 dimension != null &&
                 maxSeqLen != null &&
                 ragProfileId != null),
         'a model without a registry build names its files and profile',
       ),
       assert(
         (tokenizerUrl == null) == (tokenizerFilename == null),
         'a tokenizer has both a URL and a file name, or neither',
       ),
       _variant = variant,
       _url = url,
       _tokenizerUrl = tokenizerUrl,
       _filename = filename,
       _tokenizerFilename = tokenizerFilename,
       _dimension = dimension,
       _maxSeqLen = maxSeqLen,
       _ragProfileId = ragProfileId;

  /// A self-contained `.litertlm` bundle: no tokenizer file, and no web
  /// engine yet.
  bool get isLiteRtLmBundle => tokenizerUrl == null;

  // BaseModel interface implementation
  @override
  String get name => toString().split('.').last;

  @override
  ModelKind get kind => ModelKind.embedding;

  @override
  String? get licenseUrl => null; // Most embedding models don't have specific license URLs
}

/// The NPU vendor of a per-SoC EmbeddingGemma 2 bundle.
enum EmbeddingNpuVendor {
  /// Runs on Qualcomm Android and Qualcomm Linux arm64.
  qualcomm,

  /// Runs on Windows x64 (Panther Lake).
  intel,

  /// Runs on Android arm64 (a Pixel with that Tensor generation).
  googleTensor,

  /// Runs on Android arm64 (a phone with that MediaTek SoC).
  mediatek,
}

/// Whether this platform can run [vendor]'s per-SoC bundles at all: Qualcomm
/// on Android and Linux (arm64), Intel on Windows (x64), Google Tensor and
/// MediaTek on Android (arm64). On such a device
/// without that NPU they are listed and refused at load, with the reason.
bool npuEmbeddersListedFor(EmbeddingNpuVendor vendor) =>
    !kIsWeb &&
    switch (vendor) {
      EmbeddingNpuVendor.qualcomm =>
        defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.linux,
      EmbeddingNpuVendor.intel =>
        defaultTargetPlatform == TargetPlatform.windows,
      EmbeddingNpuVendor.googleTensor || EmbeddingNpuVendor.mediatek =>
        defaultTargetPlatform == TargetPlatform.android,
    };

/// The catalog models this platform lists.
List<EmbeddingModel> get listedEmbeddingModels => [
  for (final model in EmbeddingModel.values)
    if (model.npuSoc == null || npuEmbeddersListedFor(model.npuVendor)) model,
];

/// The backend to load the embedder of a RAG profile with: npu when
/// [profileId] (a text id or an image id) belongs to a per-SoC bundle, else
/// null.
PreferredBackend? embedderBackendForProfile(String profileId) {
  for (final model in EmbeddingModel.values) {
    if (model.ragProfileId == profileId ||
        model.imageRagProfileId == profileId) {
      return model.embedderBackend;
    }
  }
  return null;
}
