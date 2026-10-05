import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart';
import 'package:flutter_gemma/core/utils/file_name_utils.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/core/services/model_repository.dart' as repo;

/// Fluent builder for STT (speech-to-text) model installation
///
/// Provides type-safe API for installing STT models (requires model + tokenizer).
/// Automatically sets the installed model as the active STT model.
///
/// The model is SELECTABLE like inference models: [ofType] is required so the
/// installed [SttModelSpec] carries an [SttModelType] (mirrors
/// [InferenceModelSpec.modelType]) — a single generic backend can then dispatch
/// to the right runtime profile instead of hardcoding one model.
///
/// Usage:
/// ```dart
/// await FlutterGemma.installStt()
///   .modelFromNetwork('https://example.com/model.tflite', token: 'hf_...')
///   .tokenizerFromNetwork('https://example.com/tokenizer.json', token: 'hf_...')
///   .ofType(SttModelType.moonshine)
///   .withModelProgress((p) => print('Model: $p%'))
///   .withTokenizerProgress((p) => print('Tokenizer: $p%'))
///   .install();
/// ```
class SttInstallationBuilder {
  ModelSource? _modelSource;
  ModelSource? _tokenizerSource;
  SttModelType? _sttModelType;
  void Function(int progress)? _onModelProgress;
  void Function(int progress)? _onTokenizerProgress;
  CancelToken? _cancelToken;

  // === Model source setters ===

  /// Set model source from network URL (HTTP/HTTPS)
  SttInstallationBuilder modelFromNetwork(String url, {String? token}) {
    _modelSource = ModelSource.network(url, authToken: token);
    return this;
  }

  /// Set model source from Flutter asset
  SttInstallationBuilder modelFromAsset(String path) {
    _modelSource = ModelSource.asset(path);
    return this;
  }

  /// Set model source from bundled native resource
  SttInstallationBuilder modelFromBundled(String resourceName) {
    _modelSource = ModelSource.bundled(resourceName);
    return this;
  }

  /// Set model source from external file path
  SttInstallationBuilder modelFromFile(String path) {
    _modelSource = ModelSource.file(path);
    return this;
  }

  // === Tokenizer source setters ===

  /// Set tokenizer source from network URL (HTTP/HTTPS).
  ///
  /// [token] optional auth token for the URL (e.g. HuggingFace).
  SttInstallationBuilder tokenizerFromNetwork(String url, {String? token}) {
    _tokenizerSource = ModelSource.network(url, authToken: token);
    return this;
  }

  /// Set tokenizer source from a Flutter asset.
  SttInstallationBuilder tokenizerFromAsset(String path) {
    _tokenizerSource = ModelSource.asset(path);
    return this;
  }

  /// Set tokenizer source from a bundled native resource.
  SttInstallationBuilder tokenizerFromBundled(String resourceName) {
    _tokenizerSource = ModelSource.bundled(resourceName);
    return this;
  }

  /// Set tokenizer source from an external file path.
  SttInstallationBuilder tokenizerFromFile(String path) {
    _tokenizerSource = ModelSource.file(path);
    return this;
  }

  // === Model family selection ===

  /// Set the STT model family ([SttModelType]) this install represents.
  ///
  /// Required — mirrors [InferenceModelSpec.modelType]. Carried on the
  /// installed [SttModelSpec] so a single generic backend can select the
  /// right [SttModelProfile] runtime pipeline instead of hardcoding one model.
  SttInstallationBuilder ofType(SttModelType sttModelType) {
    _sttModelType = sttModelType;
    return this;
  }

  // === Progress callbacks ===

  /// Add model file progress callback
  SttInstallationBuilder withModelProgress(
    void Function(int progress) onProgress,
  ) {
    _onModelProgress = onProgress;
    return this;
  }

  /// Add tokenizer file progress callback
  SttInstallationBuilder withTokenizerProgress(
    void Function(int progress) onProgress,
  ) {
    _onTokenizerProgress = onProgress;
    return this;
  }

  /// Set cancellation token for this installation
  ///
  /// The same token will be used for both model and tokenizer downloads.
  SttInstallationBuilder withCancelToken(CancelToken cancelToken) {
    _cancelToken = cancelToken;
    return this;
  }

  /// Execute the installation and automatically set as active STT model
  ///
  /// Returns [SttInstallation] with details about the installed model.
  ///
  /// Throws:
  /// - [StateError] if model or tokenizer source not configured, or [ofType]
  ///   was not called
  /// - [DownloadCancelledException] if cancelled via cancelToken
  /// - [Exception] on installation failure
  ///
  /// Note: This method is idempotent - calling install() on an already-installed
  /// model will skip download and just set it as active.
  Future<SttInstallation> install() async {
    // Check cancellation before starting
    _cancelToken?.throwIfCancelled();

    if (_modelSource == null || _tokenizerSource == null) {
      throw StateError(
        'Both model and tokenizer required. Use modelFromNetwork() and tokenizerFromNetwork().',
      );
    }

    final sttModelType = _sttModelType;
    if (sttModelType == null) {
      throw StateError(
        'ofType(SttModelType) is required. Use e.g. ofType(SttModelType.moonshine) '
        'so the STT backend knows which runtime profile to use.',
      );
    }

    final effectiveTokenizerSource = _tokenizerSource!;

    // Create spec
    final modelFile = SttModelFile.fromSource(_modelSource!);
    final spec = SttModelSpec(
      name: FileNameUtils.getBaseName(modelFile.filename),
      modelSource: _modelSource!,
      tokenizerSource: effectiveTokenizerSource,
      sttModelType: sttModelType,
      replacePolicy: ModelReplacePolicy.keep,
    );

    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // spec.files is [modelFile, tokenizerFile] in that fixed order (see
    // SttModelSpec.files) — reuse the already-namespaced identity.
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
        'ℹ️  STT model already installed: $modelFilename + $tokenizerFilename (skipping download)',
      );
    } else {
      final handlerRegistry = registry.sourceHandlerRegistry;

      if (!isModelInstalled) {
        gemmaLog('📥 Installing STT model...');
        final modelHandler = handlerRegistry.getHandler(_modelSource!);
        if (_onModelProgress != null) {
          await for (final progress in modelHandler!.installWithProgress(
            _modelSource!,
            cancelToken: _cancelToken,
            targetFilename: modelFilename,
            modelType: repo.ModelType.stt,
          )) {
            _onModelProgress!(progress);
          }
        } else {
          await modelHandler!.install(
            _modelSource!,
            cancelToken: _cancelToken,
            targetFilename: modelFilename,
            modelType: repo.ModelType.stt,
          );
        }
      } else {
        gemmaLog('ℹ️  STT model file already installed: $modelFilename');
      }

      if (!isTokenizerInstalled) {
        gemmaLog('📥 Installing STT tokenizer...');
        final tokenizerHandler = handlerRegistry.getHandler(
          effectiveTokenizerSource,
        );
        if (_onTokenizerProgress != null) {
          await for (final progress in tokenizerHandler!.installWithProgress(
            effectiveTokenizerSource,
            cancelToken: _cancelToken,
            targetFilename: tokenizerFilename,
            modelType: repo.ModelType.stt,
          )) {
            _onTokenizerProgress!(progress);
          }
        } else {
          await tokenizerHandler!.install(
            effectiveTokenizerSource,
            cancelToken: _cancelToken,
            targetFilename: tokenizerFilename,
            modelType: repo.ModelType.stt,
          );
        }
      } else {
        gemmaLog(
          'ℹ️  STT tokenizer file already installed: $tokenizerFilename',
        );
      }
    }

    // AUTO-SET as active STT model (even if already installed)
    final manager = FlutterGemmaPlugin.instance.modelManager;
    manager.setActiveModel(spec);

    gemmaLog('✅ STT model installed and set as active: ${spec.name}');

    return SttInstallation(spec: spec);
  }
}

/// Result of STT model installation
class SttInstallation {
  final SttModelSpec spec;

  SttInstallation({required this.spec});

  /// Model ID (filename without extension)
  String get modelId => spec.name;
}
