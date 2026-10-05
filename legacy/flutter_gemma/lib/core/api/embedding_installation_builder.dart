import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart';
import 'package:flutter_gemma/core/utils/file_name_utils.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/core/services/model_repository.dart' as repo;

/// Fluent builder for embedding model installation
///
/// Provides type-safe API for installing embedding models (requires model + tokenizer).
/// Automatically sets the installed model as the active embedding model.
///
/// Usage:
/// ```dart
/// await FlutterGemma.installEmbedder()
///   .modelFromNetwork('https://example.com/model.tflite', token: 'hf_...')
///   .tokenizerFromNetwork('https://example.com/tokenizer.model', token: 'hf_...')
///   .withModelProgress((p) => print('Model: $p%'))
///   .withTokenizerProgress((p) => print('Tokenizer: $p%'))
///   .install();
/// ```
class EmbeddingInstallationBuilder {
  ModelSource? _modelSource;
  ModelSource? _tokenizerSource;
  // 0.15.2: per-platform tokenizer source dropped — same `.model` (or
  // `.json`) works on every native platform via dart_sentencepiece_tokenizer.
  void Function(int progress)? _onModelProgress;
  void Function(int progress)? _onTokenizerProgress;
  CancelToken? _cancelToken;

  // === Model source setters ===

  /// Set model source from network URL (HTTP/HTTPS)
  EmbeddingInstallationBuilder modelFromNetwork(String url, {String? token}) {
    _modelSource = ModelSource.network(url, authToken: token);
    return this;
  }

  /// Set model source from Flutter asset
  EmbeddingInstallationBuilder modelFromAsset(String path) {
    _modelSource = ModelSource.asset(path);
    return this;
  }

  /// Set model source from bundled native resource
  EmbeddingInstallationBuilder modelFromBundled(String resourceName) {
    _modelSource = ModelSource.bundled(resourceName);
    return this;
  }

  /// Set model source from external file path
  EmbeddingInstallationBuilder modelFromFile(String path) {
    _modelSource = ModelSource.file(path);
    return this;
  }

  // === Tokenizer source setters ===
  //
  // 0.15.2: tokenizer is the same `.model` (or exported `.json`) on every
  // native platform — `dart_sentencepiece_tokenizer` loads both directly,
  // so the per-platform `iosPath`/`iosToken` parameters previously needed
  // for iOS are gone.

  /// Set tokenizer source from network URL (HTTP/HTTPS).
  ///
  /// [token] optional auth token for the URL (e.g. HuggingFace).
  EmbeddingInstallationBuilder tokenizerFromNetwork(
    String url, {
    String? token,
  }) {
    _tokenizerSource = ModelSource.network(url, authToken: token);
    return this;
  }

  /// Set tokenizer source from a Flutter asset.
  EmbeddingInstallationBuilder tokenizerFromAsset(String path) {
    _tokenizerSource = ModelSource.asset(path);
    return this;
  }

  /// Set tokenizer source from a bundled native resource.
  EmbeddingInstallationBuilder tokenizerFromBundled(String resourceName) {
    _tokenizerSource = ModelSource.bundled(resourceName);
    return this;
  }

  /// Set tokenizer source from an external file path.
  EmbeddingInstallationBuilder tokenizerFromFile(String path) {
    _tokenizerSource = ModelSource.file(path);
    return this;
  }

  // === Progress callbacks ===

  /// Add model file progress callback
  EmbeddingInstallationBuilder withModelProgress(
    void Function(int progress) onProgress,
  ) {
    _onModelProgress = onProgress;
    return this;
  }

  /// Add tokenizer file progress callback
  EmbeddingInstallationBuilder withTokenizerProgress(
    void Function(int progress) onProgress,
  ) {
    _onTokenizerProgress = onProgress;
    return this;
  }

  /// Set cancellation token for this installation
  ///
  /// The same token will be used for both model and tokenizer downloads.
  ///
  /// Example:
  /// ```dart
  /// final cancelToken = CancelToken();
  ///
  /// final future = FlutterGemma.installEmbedder()
  ///   .modelFromNetwork(modelUrl)
  ///   .tokenizerFromNetwork(tokenizerUrl)
  ///   .withCancelToken(cancelToken)
  ///   .install();
  ///
  /// // Cancel from elsewhere
  /// cancelToken.cancel('User cancelled');
  /// ```
  EmbeddingInstallationBuilder withCancelToken(CancelToken cancelToken) {
    _cancelToken = cancelToken;
    return this;
  }

  /// Execute the installation and automatically set as active embedding model
  ///
  /// Returns [EmbeddingInstallation] with details about installed model.
  ///
  /// Throws:
  /// - [StateError] if model or tokenizer source not configured
  /// - [DownloadCancelledException] if cancelled via cancelToken
  /// - [Exception] on installation failure
  ///
  /// Note: This method is idempotent - calling install() on an already-installed
  /// model will skip download and just set it as active.
  Future<EmbeddingInstallation> install() async {
    // Check cancellation before starting
    _cancelToken?.throwIfCancelled();

    if (_modelSource == null || _tokenizerSource == null) {
      throw StateError(
        'Both model and tokenizer required. Use modelFromNetwork() and tokenizerFromNetwork().',
      );
    }

    final effectiveTokenizerSource = _tokenizerSource!;

    // Create spec
    final modelFile = EmbeddingModelFile.fromSource(_modelSource!);
    final spec = EmbeddingModelSpec(
      name: FileNameUtils.getBaseName(modelFile.filename),
      modelSource: _modelSource!,
      tokenizerSource: effectiveTokenizerSource,
      replacePolicy: ModelReplacePolicy.keep,
    );

    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // spec.files is [modelFile, tokenizerFile] in that fixed order (see
    // EmbeddingModelSpec.files) — reuse the already-namespaced identity.
    final files = spec.files;
    final modelFilename = files[0].filename;
    final tokenizerFilename = files[1].filename;

    // Check if both model and tokenizer are already installed
    final isModelInstalled = await repository.isInstalled(modelFilename);
    final isTokenizerInstalled = await repository.isInstalled(
      tokenizerFilename,
    );

    if (isModelInstalled && isTokenizerInstalled) {
      gemmaLog(
        'ℹ️  Embedding model already installed: $modelFilename + $tokenizerFilename (skipping download)',
      );
    } else {
      final handlerRegistry = registry.sourceHandlerRegistry;

      // Install model file if not already installed
      if (!isModelInstalled) {
        gemmaLog('📥 Installing embedding model...');
        final modelHandler = handlerRegistry.getHandler(_modelSource!);
        if (_onModelProgress != null) {
          await for (final progress in modelHandler!.installWithProgress(
            _modelSource!,
            cancelToken: _cancelToken,
            targetFilename: modelFilename,
            modelType: repo.ModelType.embedding,
          )) {
            _onModelProgress!(progress);
          }
        } else {
          await modelHandler!.install(
            _modelSource!,
            cancelToken: _cancelToken,
            targetFilename: modelFilename,
            modelType: repo.ModelType.embedding,
          );
        }
      } else {
        gemmaLog('ℹ️  Embedding model file already installed: $modelFilename');
      }

      // Install tokenizer file if not already installed
      if (!isTokenizerInstalled) {
        gemmaLog('📥 Installing tokenizer...');
        final tokenizerHandler = handlerRegistry.getHandler(
          effectiveTokenizerSource,
        );
        if (_onTokenizerProgress != null) {
          await for (final progress in tokenizerHandler!.installWithProgress(
            effectiveTokenizerSource,
            cancelToken: _cancelToken,
            targetFilename: tokenizerFilename,
            modelType: repo.ModelType.embedding,
          )) {
            _onTokenizerProgress!(progress);
          }
        } else {
          await tokenizerHandler!.install(
            effectiveTokenizerSource,
            cancelToken: _cancelToken,
            targetFilename: tokenizerFilename,
            modelType: repo.ModelType.embedding,
          );
        }
      } else {
        gemmaLog('ℹ️  Tokenizer file already installed: $tokenizerFilename');
      }
    }

    // AUTO-SET as active embedding model (even if already installed)
    final manager = FlutterGemmaPlugin.instance.modelManager;
    manager.setActiveModel(spec);

    gemmaLog('✅ Embedding model installed and set as active: ${spec.name}');

    return EmbeddingInstallation(spec: spec);
  }
}

/// Result of embedding model installation
class EmbeddingInstallation {
  final EmbeddingModelSpec spec;

  EmbeddingInstallation({required this.spec});

  /// Model ID (filename without extension)
  String get modelId => spec.name;
}
