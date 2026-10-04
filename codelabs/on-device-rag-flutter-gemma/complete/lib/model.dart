import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// Supplied at run time, never committed:
///   flutter run --dart-define=HF_TOKEN=hf_your_token
///
/// Lives here rather than in `main.dart` because both the LLM download and the
/// embedder install need it, and they are on different pages.
const hfToken = String.fromEnvironment('HF_TOKEN');

/// One model this app knows how to install.
///
/// [fileName] doubles as the model's id: `FlutterEdgeAi.isModelInstalled` takes
/// the file name the model was installed under, not a display name.
class ModelChoice {
  const ModelChoice({
    required this.label,
    required this.url,
    required this.fileName,
    required this.modelType,
    required this.sizeLabel,
    required this.requiresToken,
  });

  final String label;
  final String url;
  final String fileName;
  final ModelType modelType;
  final String sizeLabel;

  /// Hugging Face serves this repo behind a licence gate. Accept the licence
  /// once on the model page, then run with `--dart-define=HF_TOKEN=hf_...`.
  final bool requiresToken;
}

/// The models this quickstart offers.
///
/// All three are `.litertlm`, the format the LiteRT-LM engine reads on
/// Android, iOS, desktop and the web — but the browser engine
/// (`@litert-lm/core`) only runs a `.litertlm` file exported for it. [gemma3]
/// and [gemma4] are native builds: they install fine on web and then fail when
/// the engine starts. [gemma4Web] is this app's one web-exported model, and
/// `main.dart` picks it there instead. (`.task` files are MediaPipe-only — a
/// different engine package, and no desktop support.)
abstract final class Models {
  /// The plugin's namesake. `ekv4096` in the file name is the KV-cache the
  /// weights were built for, so this model can carry a 4096-token context.
  static const gemma3 = ModelChoice(
    label: 'Gemma 3 1B',
    url:
        'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/'
        'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    fileName: 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    modelType: ModelType.gemmaIt,
    sizeLabel: '0.6 GB',
    requiresToken: true,
  );

  /// No Hugging Face account? This repo is ungated. Same code path — the only
  /// thing that changes is which constant you hand to the app. It is also the
  /// largest of the three: 2.59 GB, and a phone with 6 GB of RAM or more.
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    fileName: 'gemma-4-E2B-it.litertlm',
    modelType: ModelType.gemma4,
    sizeLabel: '2.59 GB',
    requiresToken: false,
  );

  /// The web build. The browser engine (`@litert-lm/core`) runs only models
  /// exported for it — the native files above install on web and then fail
  /// when the engine starts — and Gemma 4 E2B is the smallest one published.
  static const gemma4Web = ModelChoice(
    label: 'Gemma 4 E2B (web build)',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    fileName: 'gemma-4-E2B-it-web.litertlm',
    modelType: ModelType.gemma4,
    sizeLabel: '2.0 GB',
    requiresToken: false,
  );
}

/// The embedding model this codelab indexes the recipes with.
///
/// Two files, not one, and both are required: the `.tflite` holds the weights,
/// and `sentencepiece.model` is the tokenizer that turns text into the ids
/// those weights expect. Hand over only the first and the install fails —
/// there is no tokenizer baked into the graph.
///
/// `seq256` in the file name is the **sequence length in tokens**, not the
/// embedding dimension. The vectors this model emits are 768 long regardless;
/// 256 is how much text fits into one forward pass before it is truncated.
abstract final class Embedders {
  static const embeddingGemma = EmbedderChoice(
    label: 'EmbeddingGemma 300M',
    modelUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/'
        'main/embeddinggemma-300M_seq256_mixed-precision.tflite',
    tokenizerUrl:
        'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/'
        'main/sentencepiece.model',
    sizeLabel: '0.2 GB',
    // Same licence gate as Gemma 3 above, and the same HF_TOKEN covers both.
    requiresToken: true,
  );
}

/// One embedding model this app knows how to install.
class EmbedderChoice {
  const EmbedderChoice({
    required this.label,
    required this.modelUrl,
    required this.tokenizerUrl,
    required this.sizeLabel,
    required this.requiresToken,
  });

  final String label;
  final String modelUrl;
  final String tokenizerUrl;
  final String sizeLabel;
  final bool requiresToken;
}
