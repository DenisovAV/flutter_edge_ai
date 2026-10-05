import 'base_model.dart';

enum EmbeddingModel implements EmbeddingModelInterface {
  // EmbeddingGemma-300M models (all generate 768D embeddings)
  // Numbers in names indicate max sequence length, not embedding dimension
  embeddingGemma1024(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq1024_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
    filename: 'embeddinggemma-300M_seq1024_mixed-precision.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'EmbeddingGemma (seq=1024)',
    size: '183MB',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 1024,
    needsAuth: true,
  ),

  embeddingGemma2048(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq2048_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
    filename: 'embeddinggemma-300M_seq2048_mixed-precision.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'EmbeddingGemma (seq=2048)',
    size: '196MB',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 2048,
    needsAuth: true,
  ),

  embeddingGemma256(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq256_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
    filename: 'embeddinggemma-300M_seq256_mixed-precision.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'EmbeddingGemma (seq=256)',
    size: '179MB',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 256,
    needsAuth: true,
  ),

  // Local model for fast testing (no auth required)
  // Files are in example/assets/models/
  // AssetSource works in both debug and production builds
  localEmbeddingGemma256(
    url: 'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite',
    tokenizerUrl: 'assets/models/sentencepiece.model',
    filename:
        'embeddinggemma-300M_seq256_mixed-precision.tflite', // Keep same as HF version for compatibility
    tokenizerFilename: 'sentencepiece.model',
    displayName: '🚀 Local EmbeddingGemma (seq=256)',
    size: '171MB (Local - No Auth)',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 256,
    needsAuth: false,
    sourceType: ModelSourceType
        .asset, // Use Flutter assets - works in debug and production
  ),

  embeddingGemma512(
    url:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq512_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
    filename: 'embeddinggemma-300M_seq512_mixed-precision.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'EmbeddingGemma (seq=512)',
    size: '179MB',
    dimension: 768, // Fixed embedding dimension for EmbeddingGemma-300M
    maxSeqLen: 512,
    needsAuth: true,
  ),

  // Gecko-110m models (generate 768D embeddings)
  // Gecko 64 is the smallest and fastest model - ideal for short queries
  gecko64(
    url:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/Gecko_64_quant.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/sentencepiece.model',
    filename: 'Gecko_64_quant.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'Gecko (seq=64)',
    size: '110MB',
    dimension: 768, // Fixed embedding dimension for Gecko-110m
    maxSeqLen: 64,
    needsAuth: false,
  ),

  gecko256(
    url:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/Gecko_256_quant.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/sentencepiece.model',
    filename:
        'Gecko_256_quant.tflite', // Fixed: match actual downloaded filename
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'Gecko (seq=256)',
    size: '114MB',
    dimension: 768, // Fixed embedding dimension for Gecko-110m
    maxSeqLen: 256,
    needsAuth: false,
  ),

  gecko512(
    url:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/Gecko_512_quant.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/sentencepiece.model',
    filename: 'Gecko_512_quant.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'Gecko (seq=512)',
    size: '116MB',
    dimension: 768, // Fixed embedding dimension for Gecko-110m
    maxSeqLen: 512,
    needsAuth: false,
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
