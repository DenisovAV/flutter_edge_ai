// Embedding models for RAG functionality

/// Enum for available embedding models, following the same pattern as Model enum
enum EmbeddingModel {
  // EmbeddingGemma models
  embeddingGemma300M(
    url:
        'https://huggingface.co/google/embeddinggemma-300m/resolve/main/model.tflite',
    tokenizerUrl:
        'https://huggingface.co/google/embeddinggemma-300m/resolve/main/sentencepiece.model',
    filename: 'embeddinggemma-300m.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'EmbeddingGemma 300M',
    size: '300MB',
    dimension: 768,
    needsAuth: true,
  ),

  embeddingGemma300M8bit(
    url:
        'https://huggingface.co/google/embeddinggemma-300m-8bit/resolve/main/model.tflite',
    tokenizerUrl:
        'https://huggingface.co/google/embeddinggemma-300m-8bit/resolve/main/sentencepiece.model',
    filename: 'embeddinggemma-300m-8bit.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'EmbeddingGemma 300M (8-bit)',
    size: '150MB',
    dimension: 768,
    needsAuth: true,
  ),

  embeddingGemma300M4bit(
    url:
        'https://huggingface.co/google/embeddinggemma-300m-4bit/resolve/main/model.tflite',
    tokenizerUrl:
        'https://huggingface.co/google/embeddinggemma-300m-4bit/resolve/main/sentencepiece.model',
    filename: 'embeddinggemma-300m-4bit.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'EmbeddingGemma 300M (4-bit)',
    size: '75MB',
    dimension: 768,
    needsAuth: true,
  ),

  embeddingGemma300M2bit(
    url:
        'https://huggingface.co/google/embeddinggemma-300m-2bit/resolve/main/model.tflite',
    tokenizerUrl:
        'https://huggingface.co/google/embeddinggemma-300m-2bit/resolve/main/sentencepiece.model',
    filename: 'embeddinggemma-300m-2bit.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'EmbeddingGemma 300M (2-bit)',
    size: '38MB',
    dimension: 768,
    needsAuth: true,
  ),

  gecko110M(
    url:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/gecko.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/sentencepiece.model',
    filename: 'gecko-110m.tflite',
    tokenizerFilename: 'sentencepiece.model',
    displayName: 'Gecko 110M English',
    size: '110MB',
    dimension: 768,
    needsAuth: true,
  );

  /// Enum fields
  final String url;
  final String tokenizerUrl;
  final String filename;
  final String tokenizerFilename;
  final String displayName;
  final String size;
  final int dimension;
  final bool needsAuth;

  /// Constructor
  const EmbeddingModel({
    required this.url,
    required this.tokenizerUrl,
    required this.filename,
    required this.tokenizerFilename,
    required this.displayName,
    required this.size,
    required this.dimension,
    required this.needsAuth,
  });
}
