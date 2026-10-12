import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/model_management/install_rule.dart';
import 'package:flutter_edge_ai/core/model_management/model_activation.dart';
import 'package:flutter_edge_ai/core/utils/file_name_utils.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;

/// Fluent builder for embedding model installation
///
/// Provides type-safe API for installing embedding models (requires model + tokenizer).
/// Automatically sets the installed model as the active embedding model.
///
/// Usage:
/// ```dart
/// await FlutterEdgeAi.installEmbedder()
///   .modelFromNetwork('https://example.com/model.tflite', token: 'hf_...')
///   .tokenizerFromNetwork('https://example.com/tokenizer.model', token: 'hf_...')
///   .withModelProgress((p) => print('Model: $p%'))
///   .withTokenizerProgress((p) => print('Tokenizer: $p%'))
///   .install();
/// ```
class EmbeddingInstallationBuilder {
  ModelSource? _modelSource;
  ModelSource? _tokenizerSource;
  String? _modelFilename;
  String? _tokenizerFilename;
  // 0.15.2: per-platform tokenizer source dropped — same `.model` (or
  // `.json`) works on every native platform via dart_sentencepiece_tokenizer.
  void Function(int progress)? _onModelProgress;
  void Function(int progress)? _onTokenizerProgress;
  CancelToken? _cancelToken;

  // === Model source setters ===

  /// Set model source from network URL (HTTP/HTTPS).
  ///
  /// [filename] pins the installed/cache identity instead of deriving it from
  /// the URL basename. Prefer a revision-qualified basename for mutable hosts.
  EmbeddingInstallationBuilder modelFromNetwork(
    String url, {
    String? token,
    String? filename,
  }) {
    _modelSource = ModelSource.network(url, authToken: token);
    _modelFilename = _validateFilename(filename);
    return this;
  }

  /// Set model source from Flutter asset
  EmbeddingInstallationBuilder modelFromAsset(String path, {String? filename}) {
    _modelSource = ModelSource.asset(path);
    _modelFilename = _validateFilename(filename);
    return this;
  }

  /// Set model source from bundled native resource
  EmbeddingInstallationBuilder modelFromBundled(
    String resourceName, {
    String? filename,
  }) {
    _modelSource = ModelSource.bundled(resourceName);
    _modelFilename = _validateFilename(filename);
    return this;
  }

  /// Set model source from external file path
  EmbeddingInstallationBuilder modelFromFile(String path, {String? filename}) {
    _modelSource = ModelSource.file(path);
    _modelFilename = _validateFilename(filename);
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
  /// [filename] pins the installed/cache identity; it must already be unique
  /// to the owning embedding profile because explicit names bypass automatic
  /// tokenizer namespacing.
  EmbeddingInstallationBuilder tokenizerFromNetwork(
    String url, {
    String? token,
    String? filename,
  }) {
    _tokenizerSource = ModelSource.network(url, authToken: token);
    _tokenizerFilename = _validateFilename(filename);
    return this;
  }

  /// Set tokenizer source from a Flutter asset.
  EmbeddingInstallationBuilder tokenizerFromAsset(
    String path, {
    String? filename,
  }) {
    _tokenizerSource = ModelSource.asset(path);
    _tokenizerFilename = _validateFilename(filename);
    return this;
  }

  /// Set tokenizer source from a bundled native resource.
  EmbeddingInstallationBuilder tokenizerFromBundled(
    String resourceName, {
    String? filename,
  }) {
    _tokenizerSource = ModelSource.bundled(resourceName);
    _tokenizerFilename = _validateFilename(filename);
    return this;
  }

  /// Set tokenizer source from an external file path.
  EmbeddingInstallationBuilder tokenizerFromFile(
    String path, {
    String? filename,
  }) {
    _tokenizerSource = ModelSource.file(path);
    _tokenizerFilename = _validateFilename(filename);
    return this;
  }

  static String? _validateFilename(String? filename) {
    if (filename == null) return null;
    return FileNameUtils.validatePortableFileNameSegment(filename);
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
  /// final future = FlutterEdgeAi.installEmbedder()
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
  /// Note: This method is idempotent - a file already installed from the same
  /// source is skipped and the spec is just (re-)set as active. One installed
  /// from another source is installed again: a download from another URL —
  /// compared without its query and token, so a version told apart only by
  /// the query is not —, or a file the app picked from another path. On
  /// Android, iOS and desktop core's earlier copy of it is deleted once the
  /// new file is active (or at the next start), never a file the app
  /// installed with `fromFile`; a download that would land on such a file
  /// throws a [ModelStorageException] instead.
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
    final modelFile = _modelFilename == null
        ? EmbeddingModelFile.fromSource(_modelSource!)
        : EmbeddingModelFile(source: _modelSource!, filename: _modelFilename!);
    final spec = EmbeddingModelSpec(
      name: FileNameUtils.getBaseName(modelFile.filename),
      modelSource: _modelSource!,
      tokenizerSource: effectiveTokenizerSource,
      modelFilename: _modelFilename,
      tokenizerFilename: _tokenizerFilename,
      replacePolicy: ModelReplacePolicy.keep,
    );

    // The model, then its tokenizer, each by its own record (see
    // install_rule.dart).
    final release = await installPlanned(
      await planInstall(spec.files),
      modelType: repo.ModelType.embedding,
      cancelToken: _cancelToken,
      progress: [_onModelProgress, _onTokenizerProgress],
    );

    // AUTO-SET as active embedding model (even if already installed)
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    await activateInstalledModel(manager, spec);
    await release.run(manager, spec);

    edgeAiLog('✅ Embedding model installed and set as active: ${spec.name}');

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
