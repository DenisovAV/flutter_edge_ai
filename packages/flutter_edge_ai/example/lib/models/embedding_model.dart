import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show PreferredBackend;

import 'base_model.dart';

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
    url:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/29888fcee3216acadc7e844906e5fe0d79a61875/embeddinggemma-300M_seq1024_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/29888fcee3216acadc7e844906e5fe0d79a61875/sentencepiece.model',
    filename:
        'embeddinggemma-300M_seq1024_mixed-precision__rev-29888fcee321.tflite',
    tokenizerFilename:
        'embeddinggemma-300m-seq1024__sentencepiece__rev-29888fcee321.model',
    displayName: 'EmbeddingGemma (seq=1024)',
    size: '183MB',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 1024,
    needsAuth: true,
    ragProfileId:
        'embeddinggemma-300m-seq1024-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1',
  ),

  embeddingGemma2048(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/29888fcee3216acadc7e844906e5fe0d79a61875/embeddinggemma-300M_seq2048_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/29888fcee3216acadc7e844906e5fe0d79a61875/sentencepiece.model',
    filename:
        'embeddinggemma-300M_seq2048_mixed-precision__rev-29888fcee321.tflite',
    tokenizerFilename:
        'embeddinggemma-300m-seq2048__sentencepiece__rev-29888fcee321.model',
    displayName: 'EmbeddingGemma (seq=2048)',
    size: '196MB',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 2048,
    needsAuth: true,
    ragProfileId:
        'embeddinggemma-300m-seq2048-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1',
  ),

  embeddingGemma256(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/29888fcee3216acadc7e844906e5fe0d79a61875/embeddinggemma-300M_seq256_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/29888fcee3216acadc7e844906e5fe0d79a61875/sentencepiece.model',
    filename:
        'embeddinggemma-300M_seq256_mixed-precision__rev-29888fcee321.tflite',
    tokenizerFilename:
        'embeddinggemma-300m-seq256__sentencepiece__rev-29888fcee321.model',
    displayName: 'EmbeddingGemma (seq=256)',
    size: '179MB',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 256,
    needsAuth: true,
    ragProfileId:
        'embeddinggemma-300m-seq256-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1',
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
    needsAuth: false,
    sourceType: ModelSourceType
        .asset, // Use Flutter assets - works in debug and production
    // Kept separate from the hosted seq=256 profile until the checked-in asset
    // is proven byte-identical to that immutable Hugging Face revision.
    ragProfileId:
        'embeddinggemma-300m-seq256-mp-example-asset-v1-retrieval-prefix-meanpool-l2-v1',
  ),

  embeddingGemma512(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/29888fcee3216acadc7e844906e5fe0d79a61875/embeddinggemma-300M_seq512_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/29888fcee3216acadc7e844906e5fe0d79a61875/sentencepiece.model',
    filename:
        'embeddinggemma-300M_seq512_mixed-precision__rev-29888fcee321.tflite',
    tokenizerFilename:
        'embeddinggemma-300m-seq512__sentencepiece__rev-29888fcee321.model',
    displayName: 'EmbeddingGemma (seq=512)',
    size: '179MB',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 512,
    needsAuth: true,
    ragProfileId:
        'embeddinggemma-300m-seq512-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1',
  ),

  // EmbeddingGemma 2 text (270M): ONE self-contained `.litertlm` bundle that
  // carries its own tokenizer, so there is no tokenizer file. Ungated.
  // Android, iOS, macOS, Linux, Windows (CPU), and the web (WebGPU, since
  // flutter_edge_ai_litertlm 1.13.1; no CPU path there). Input cap 1024 tokens
  // (prefix, BOS and EOS included) — keep RAG chunks at 512 or below.
  embeddingGemma2Text270m(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m.litertlm',
    filename: 'embeddinggemma-2-text-270m__rev-9be6e8b90982.litertlm',
    displayName: 'EmbeddingGemma 2 Text (270M)',
    size: '165MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb',
    // Keyed by the text-encoder weights section (sha256 prefix 4410a540ce75):
    // byte-identical in the 270m, 440m and 740m generic bundles, which give
    // identical text vectors, so one id serves all three. Never shared with
    // EmbeddingGemma 1 or an ONNX export of EG2.
    ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1',
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
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m.litertlm',
    filename: 'embeddinggemma-2-text-vision-440m__rev-e301f74d5551.litertlm',
    displayName: 'EmbeddingGemma 2 Text + Vision (440M)',
    size: '388MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0',
    // Text vectors are identical to the 270M's, so text stores share its id.
    // An image index uses imageRagProfileId.
    ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1',
    embedsImages: true,
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
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-740m-litert-lm/resolve/24d962e906c7d332c6428e71c9676855024569e2/embeddinggemma-2-740m.litertlm',
    filename: 'embeddinggemma-2-740m__rev-24d962e906c7.litertlm',
    displayName: 'EmbeddingGemma 2 Text + Vision + Audio (740M)',
    size: '485MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: 'e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c',
    ragProfileId: 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1',
    embedsImages: true,
    embedsAudio: true,
  ),

  // EmbeddingGemma 2 compiled for one Qualcomm NPU (Google's per-SoC
  // bundles, same repos and revisions as above). They run ONLY on that SoC's
  // NPU — `getActiveEmbedder(preferredBackend: PreferredBackend.npu)` on
  // Qualcomm Android or Qualcomm Linux arm64, in an app built with
  // `qualcomm_npu: true` (this one is) — and are refused everywhere else, so
  // the list shows them on Android and Linux only. SM8850 (Snapdragon 8 Elite
  // Gen 5), SM8650 (Snapdragon 8 Gen 3) and QCS8275 (VENTUNO Q) are the ones
  // verified; Google also publishes SM8550, SM8750, Tensor G5/G6 and MediaTek
  // MT6991/MT6993 builds, and Intel PTL (below). Their vectors are not the CPU
  // bundle's: each SoC has its own profile id — the CPU text id plus
  // `-npu-<soc>`. The 270m and the 440m of one SoC carry byte-identical text
  // towers (sha256 prefix aaae57a31475 for SM8850, d6db62a3616b for SM8650,
  // 685619825c4e for QCS8275), so they share it, as the generic bundles do.
  embeddingGemma2Text270mSm8850(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m_Qualcomm_SM8850.litertlm',
    filename:
        'embeddinggemma-2-text-270m_Qualcomm_SM8850__rev-9be6e8b90982.litertlm',
    displayName: 'EmbeddingGemma 2 Text (270M) · Qualcomm SM8850 NPU',
    size: '202MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '72992b649c812ae9e30ffa9ad88fc662e649f7b643500d28051fbd457ad0d22a',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850',
    npuSoc: 'SM8850',
  ),

  embeddingGemma2TextVision440mSm8850(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m_Qualcomm_SM8850.litertlm',
    filename:
        'embeddinggemma-2-text-vision-440m_Qualcomm_SM8850__rev-e301f74d5551.litertlm',
    displayName: 'EmbeddingGemma 2 Text + Vision (440M) · Qualcomm SM8850 NPU',
    size: '463MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '661369235aa9fc23cf04a213d4e445c4634073832279f5a261ed22650a8ebc5b',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850',
    embedsImages: true,
    npuSoc: 'SM8850',
  ),

  // The 740M for SM8850 carries the 440M SM8850's text and vision towers
  // (the same bytes: text aaae57a31475, vision 231495aaa9a3) and the generic
  // bundle's audio encoder, so it shares their ids. Run on a Galaxy S26+
  // (SM8850, DDP): text and images on the NPU, audio on the CPU.
  embeddingGemma2TextVisionAudio740mSm8850(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-740m-litert-lm/resolve/24d962e906c7d332c6428e71c9676855024569e2/embeddinggemma-2-740m_Qualcomm_SM8850.litertlm',
    filename:
        'embeddinggemma-2-740m_Qualcomm_SM8850__rev-24d962e906c7.litertlm',
    displayName:
        'EmbeddingGemma 2 Text + Vision + Audio (740M) · Qualcomm SM8850 NPU',
    size: '559MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '19f6e8db6aa74b116d1c558c862ee131f60ce093576d3c8dd1898f656ca8080b',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8850',
    embedsImages: true,
    embedsAudio: true,
    npuSoc: 'SM8850',
  ),

  embeddingGemma2Text270mSm8650(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m_Qualcomm_SM8650.litertlm',
    filename:
        'embeddinggemma-2-text-270m_Qualcomm_SM8650__rev-9be6e8b90982.litertlm',
    displayName: 'EmbeddingGemma 2 Text (270M) · Qualcomm SM8650 NPU',
    size: '208MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '7dabcb17eed982d6de4435aaf29cc56147a627f6ab20a1e37aadd7af5399457b',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8650',
    npuSoc: 'SM8650',
  ),

  embeddingGemma2TextVision440mSm8650(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m_Qualcomm_SM8650.litertlm',
    filename:
        'embeddinggemma-2-text-vision-440m_Qualcomm_SM8650__rev-e301f74d5551.litertlm',
    displayName: 'EmbeddingGemma 2 Text + Vision (440M) · Qualcomm SM8650 NPU',
    size: '466MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: 'ec7d2ee513830337343567409f32fea4a3e4f8f7b94facd0a20f3d3523cd7480',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-sm8650',
    embedsImages: true,
    npuSoc: 'SM8650',
  ),

  embeddingGemma2Text270mQcs8275(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m_Qualcomm_QCS8275.litertlm',
    filename:
        'embeddinggemma-2-text-270m_Qualcomm_QCS8275__rev-9be6e8b90982.litertlm',
    displayName: 'EmbeddingGemma 2 Text (270M) · Qualcomm QCS8275 NPU',
    size: '208MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '128c32151613a5bbf8b5695b2d9ae271057338febbf06e3aeebf29e1353cb51d',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-qcs8275',
    npuSoc: 'QCS8275',
  ),

  embeddingGemma2TextVision440mQcs8275(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m_Qualcomm_QCS8275.litertlm',
    filename:
        'embeddinggemma-2-text-vision-440m_Qualcomm_QCS8275__rev-e301f74d5551.litertlm',
    displayName: 'EmbeddingGemma 2 Text + Vision (440M) · Qualcomm QCS8275 NPU',
    size: '466MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: 'ce8ccce80a12f6bc9acfe664b76c3cc46a698f0da81ae857f706b06b9a4c7d38',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-qcs8275',
    embedsImages: true,
    npuSoc: 'QCS8275',
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
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m_Intel_PTL.litertlm',
    filename: 'embeddinggemma-2-text-270m_Intel_PTL__rev-9be6e8b90982.litertlm',
    displayName: 'EmbeddingGemma 2 Text (270M) · Intel Panther Lake NPU',
    size: '317MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '048e219d702d23cf19cb9a75e7595e61e320bc61a3919e0cbf1a30dfb5cc64f4',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-ptl',
    npuSoc: 'PTL',
    npuVendor: EmbeddingNpuVendor.intel,
  ),

  embeddingGemma2TextVision440mPtl(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m_Intel_PTL.litertlm',
    filename:
        'embeddinggemma-2-text-vision-440m_Intel_PTL__rev-e301f74d5551.litertlm',
    displayName:
        'EmbeddingGemma 2 Text + Vision (440M) · Intel Panther Lake NPU',
    size: '752MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '7f4c104b30ea6185516439aef534b84d9e7066366112506d5d8843e350fd08c9',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-ptl',
    embedsImages: true,
    npuSoc: 'PTL',
    npuVendor: EmbeddingNpuVendor.intel,
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
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m_Google_Tensor_G6.litertlm',
    filename:
        'embeddinggemma-2-text-270m_Google_Tensor_G6__rev-9be6e8b90982.litertlm',
    displayName: 'EmbeddingGemma 2 Text (270M) · Google Tensor G6 NPU',
    size: '200MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '4cd282395a7b611ec8dec95160cd31a1f471a7b1cde1fc71717aa539c2a29883',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g6',
    npuSoc: 'Tensor_G6',
    npuVendor: EmbeddingNpuVendor.googleTensor,
  ),

  embeddingGemma2TextVision440mTensorG6(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m_Google_Tensor_G6.litertlm',
    filename:
        'embeddinggemma-2-text-vision-440m_Google_Tensor_G6__rev-e301f74d5551.litertlm',
    displayName: 'EmbeddingGemma 2 Text + Vision (440M) · Google Tensor G6 NPU',
    size: '513MB',
    dimension: 768,
    maxSeqLen: 1024,
    needsAuth: false,
    sha256: '40e98aeed9ef08abfd91d5d309f64f4fa06195c513931e917bcf5ea41a910668',
    ragProfileId:
        'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1-npu-tensor_g6',
    embedsImages: true,
    npuSoc: 'Tensor_G6',
    npuVendor: EmbeddingNpuVendor.googleTensor,
  ),

  // Gecko-110m models (generate 768D embeddings)
  // Gecko 64 is the smallest and fastest model - ideal for short queries
  gecko64(
    url:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2/Gecko_64_quant.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2/sentencepiece.model',
    filename: 'Gecko_64_quant__rev-61a0d0c2cdc9.tflite',
    tokenizerFilename:
        'gecko-110m-en-seq64__sentencepiece__rev-61a0d0c2cdc9.model',
    displayName: 'Gecko (seq=64)',
    size: '110MB',
    dimension: 768, // Fixed embedding dimension for Gecko-110m
    maxSeqLen: 64,
    needsAuth: false,
    ragProfileId:
        'gecko-110m-en-seq64-quant-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  ),

  gecko256(
    url:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2/Gecko_256_quant.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2/sentencepiece.model',
    filename: 'Gecko_256_quant__rev-61a0d0c2cdc9.tflite',
    tokenizerFilename:
        'gecko-110m-en-seq256__sentencepiece__rev-61a0d0c2cdc9.model',
    displayName: 'Gecko (seq=256)',
    size: '114MB',
    dimension: 768, // Fixed embedding dimension for Gecko-110m
    maxSeqLen: 256,
    needsAuth: false,
    ragProfileId:
        'gecko-110m-en-seq256-quant-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  ),

  gecko512(
    url:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2/Gecko_512_quant.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/61a0d0c2cdc9b4f2c1727e63acb7ad86e68508c2/sentencepiece.model',
    filename: 'Gecko_512_quant__rev-61a0d0c2cdc9.tflite',
    tokenizerFilename:
        'gecko-110m-en-seq512__sentencepiece__rev-61a0d0c2cdc9.model',
    displayName: 'Gecko (seq=512)',
    size: '116MB',
    dimension: 768, // Fixed embedding dimension for Gecko-110m
    maxSeqLen: 512,
    needsAuth: false,
    ragProfileId:
        'gecko-110m-en-seq512-quant-rev-61a0d0c2cdc9-retrieval-prefix-meanpool-l2-v1',
  );

  /// Enum fields
  @override
  final String url;
  @override
  final String? tokenizerUrl;
  @override
  final String filename;
  @override
  final String? tokenizerFilename;
  @override
  final String displayName;
  @override
  final String size;
  @override
  final int dimension;
  @override
  final int maxSeqLen;
  @override
  final bool needsAuth;
  @override
  final ModelSourceType sourceType;

  /// Stable identity of the complete embedding space used by the RAG demo.
  ///
  /// Bump this whenever weights, tokenizer, task prefixes, pooling, or
  /// normalization change. It must never be derived from a mutable URL, local
  /// path, or vector dimension.
  final String ragProfileId;

  /// SHA-256 of the pinned model file, where the catalog records one. The
  /// EmbeddingGemma 2 integration suite checks the installed bundle against
  /// it.
  final String? sha256;

  /// Whether the model embeds images (a bundle with a vision encoder).
  final bool embedsImages;

  /// Whether the model embeds audio (a bundle with an audio encoder; native
  /// platforms, and the web from flutter_edge_ai_litertlm 1.13.2).
  final bool embedsAudio;

  /// The SoC a per-SoC EmbeddingGemma 2 bundle is compiled for, as its file
  /// name spells it (`SM8850`, `PTL`), or null for a model that runs on CPU.
  final String? npuSoc;

  /// Whose NPU [npuSoc] is: Qualcomm (the default for a per-SoC bundle) or
  /// Intel. Decides where the bundle is listed ([listedEmbeddingModels]).
  final EmbeddingNpuVendor npuVendor;

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
    required this.url,
    this.tokenizerUrl,
    required this.filename,
    this.tokenizerFilename,
    required this.displayName,
    required this.size,
    required this.dimension,
    required this.maxSeqLen,
    required this.needsAuth,
    required this.ragProfileId,
    this.sha256,
    this.embedsImages = false,
    this.embedsAudio = false,
    this.npuSoc,
    this.npuVendor = EmbeddingNpuVendor.qualcomm,
    this.sourceType = ModelSourceType
        .network, // Default to network for backward compatibility
  }) : assert(
         (tokenizerUrl == null) == (tokenizerFilename == null),
         'a tokenizer has both a URL and a file name, or neither',
       );

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
}

/// Whether this platform can run [vendor]'s per-SoC bundles at all: Qualcomm
/// on Android and Linux (arm64), Intel on Windows (x64), Google Tensor on
/// Android (arm64). On such a device
/// without that NPU they are listed and refused at load, with the reason.
bool npuEmbeddersListedFor(EmbeddingNpuVendor vendor) =>
    !kIsWeb &&
    switch (vendor) {
      EmbeddingNpuVendor.qualcomm =>
        defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.linux,
      EmbeddingNpuVendor.intel =>
        defaultTargetPlatform == TargetPlatform.windows,
      EmbeddingNpuVendor.googleTensor =>
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
