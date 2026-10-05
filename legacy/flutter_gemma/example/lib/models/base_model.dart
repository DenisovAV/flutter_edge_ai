import 'package:flutter_gemma/core/domain/platform_types.dart';
import 'package:flutter_gemma/core/model.dart';

import '../translation/prompt_strategy.dart';

/// Type of model source for download/installation
enum ModelSourceType {
  /// Download from HTTP/HTTPS URL
  network,

  /// Load from Flutter assets (in assets/ folder)
  asset,

  /// Load from bundled native resources
  bundled,
}

/// Task category used to dispatch a downloaded model to the right
/// post-install screen and to gate kind-specific UI fields.
enum ModelKind { inference, embedding, translation }

/// Base interface for all model types (inference, embedding, translation)
abstract class BaseModel {
  /// Unique identifier for the model
  String get name;

  /// Display name shown in UI
  String get displayName;

  /// File size (e.g., "300MB", "1.2GB")
  String get size;

  /// Main model download URL
  String get url;

  /// Model filename for local storage
  String get filename;

  /// License/info URL (optional)
  String? get licenseUrl;

  /// Whether model requires HuggingFace authentication
  bool get needsAuth;

  /// What category this model is — used by `HomeScreen` for task-first
  /// routing and by `UniversalDownloadScreen` to dispatch to the right
  /// follow-up screen after install.
  ModelKind get kind;
}

/// Interface for inference models
abstract class InferenceModelInterface extends BaseModel {
  /// Preferred backend (CPU/GPU)
  PreferredBackend get preferredBackend;

  /// Model type for MediaPipe
  ModelType get modelType;

  /// Whether model is stored locally (in assets)
  bool get localModel;

  /// Generation parameters
  double get temperature;
  int get topK;
  double get topP;

  /// Capabilities
  bool get supportImage;
  bool get supportsFunctionCalls;
  bool get supportsThinking;

  /// Token limits
  int get maxTokens;
  int? get maxNumImages;
}

/// Interface for embedding models
abstract class EmbeddingModelInterface extends BaseModel {
  /// Tokenizer download URL
  String get tokenizerUrl;

  /// Tokenizer filename for local storage
  String get tokenizerFilename;

  /// Embedding vector dimension (e.g., 768)
  /// This is the fixed output size of the embedding model
  int get dimension;

  /// Maximum sequence length (context window) in tokens
  /// This determines how long input text can be before truncation
  int get maxSeqLen;

  /// Type of source for model and tokenizer files
  /// Determines which installation method to use (network, asset, bundled)
  ModelSourceType get sourceType;
}

/// Interface for translation models (TranslateGemma and any future
/// single-shot translator).
///
/// Translation in this example doesn't introduce a new plugin API — under
/// the hood we still go through `InferenceModel.createSession()` from
/// `flutter_gemma`. The discriminator is the prompt format and the language
/// list, both carried by `promptStrategy`.
abstract class TranslateModelInterface extends BaseModel {
  /// Preferred backend (CPU/GPU)
  PreferredBackend get preferredBackend;

  /// Model type for the LiteRT-LM SDK chat template parser.
  /// TranslateGemma is a Gemma-3 fine-tune so it uses `ModelType.gemmaIt`.
  ModelType get modelType;

  /// Token limit for a single translation pass. TranslateGemma ships with
  /// 1024 prefill + 1024 decode; this is the upper bound for input + output.
  int get maxTokens;

  /// Prompt format + supported-language map for this particular translator
  /// bundle. Different bundles (community `.litertlm`, Google `-web.task`,
  /// future NLLB/MADLAD) have completely different shapes, so each
  /// TranslateModel binds its own const strategy here.
  TranslationPromptStrategy get promptStrategy;
}
