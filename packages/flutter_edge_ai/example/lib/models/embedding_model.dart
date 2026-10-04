import 'base_model.dart';

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
  final String tokenizerUrl;
  @override
  final String filename;
  @override
  final String tokenizerFilename;
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

  /// Constructor
  const EmbeddingModel({
    required this.url,
    required this.tokenizerUrl,
    required this.filename,
    required this.tokenizerFilename,
    required this.displayName,
    required this.size,
    required this.dimension,
    required this.maxSeqLen,
    required this.needsAuth,
    required this.ragProfileId,
    this.sourceType = ModelSourceType
        .network, // Default to network for backward compatibility
  });

  // BaseModel interface implementation
  @override
  String get name => toString().split('.').last;

  @override
  ModelKind get kind => ModelKind.embedding;

  @override
  String? get licenseUrl => null; // Most embedding models don't have specific license URLs
}
