import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/model_management/model_activation.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/utils/file_name_utils.dart';
import 'package:flutter_edge_ai/src/model_management/install_rule.dart';
import 'package:flutter_edge_ai/src/utils/file_names.dart'
    show isLiteRtLmFilename;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;

/// Said once per isolate when an embedder is installed before any embedding
/// backend is registered (see [EmbeddingInstallationBuilder.install]).
bool _noBackendNoticed = false;

/// Fluent builder for embedding model installation
///
/// Installs a model plus its tokenizer (`.tflite`, `.onnx`, …), or a single
/// `.litertlm` bundle, which carries its own tokenizer. Automatically sets
/// the installed model as the active embedding model.
///
/// Usage:
/// ```dart
/// await FlutterEdgeAi.installEmbedder()
///   .modelFromNetwork('https://example.com/model.tflite', token: 'hf_...')
///   .tokenizerFromNetwork('https://example.com/tokenizer.model', token: 'hf_...')
///   .withModelProgress((p) => print('Model: $p%'))
///   .withTokenizerProgress((p) => print('Tokenizer: $p%'))
///   .install();
///
/// // A .litertlm embedder installs alone:
/// await FlutterEdgeAi.installEmbedder()
///   .modelFromNetwork('https://example.com/embedder.litertlm')
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
  /// Throws, before anything is downloaded:
  /// - [DownloadCancelledException] if the cancel token is already cancelled
  /// - [StateError] if no model source is set, or no tokenizer source for a
  ///   model that needs one (anything but a `.litertlm` bundle)
  /// - [ArgumentError] if a tokenizer is set for a `.litertlm` bundle, which
  ///   carries its own
  /// - [UnsupportedError] if embedding backends are registered and none of
  ///   them can run the model on this platform — so an embedder that cannot
  ///   run here is refused before a download of hundreds of megabytes. With no
  ///   backend registered yet the install goes ahead (the app may register
  ///   one later) and says so once in the debug log.
  ///
  /// and later [DownloadCancelledException] if cancelled via the cancel token,
  /// or an [Exception] on installation failure.
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

    final modelSource = _modelSource;
    if (modelSource == null) {
      throw StateError(
        'A model source is required. Use modelFromNetwork() (or '
        'modelFromAsset(), modelFromBundled(), modelFromFile()).',
      );
    }
    final modelFile = _modelFilename == null
        ? EmbeddingModelFile.fromSource(modelSource)
        : EmbeddingModelFile(source: modelSource, filename: _modelFilename!);
    if (!isLiteRtLmFilename(modelFile.filename) && _tokenizerSource == null) {
      throw StateError(
        'Both model and tokenizer required. Use modelFromNetwork() and tokenizerFromNetwork().',
      );
    }

    // Throws ArgumentError for a .litertlm bundle given a tokenizer.
    final spec = EmbeddingModelSpec(
      name: FileNameUtils.getBaseName(modelFile.filename),
      modelSource: modelSource,
      tokenizerSource: _tokenizerSource,
      modelFilename: _modelFilename,
      tokenizerFilename: _tokenizerFilename,
      replacePolicy: ModelReplacePolicy.keep,
    );
    _requireABackendThatCanRun(spec);

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

  /// The install pre-check (R5 §5.3, D13): when embedding backends are
  /// registered, one of them must be able to run [spec] here, or nothing is
  /// downloaded. With none registered yet the install proceeds — the app may
  /// register one later — and says so once.
  static void _requireABackendThatCanRun(EmbeddingModelSpec spec) {
    final backends = EmbeddingRegistry.instance;
    final filename = spec.files.first.filename;
    if (!backends.hasAny) {
      if (!_noBackendNoticed) {
        _noBackendNoticed = true;
        edgeAiLog(
          'ℹ️  No embedding backend is registered yet, so whether one can run '
          '$filename is not checked before it is installed. Pass one in '
          'FlutterEdgeAi.initialize(embeddingBackends: ...).',
        );
      }
      return;
    }
    if (backends.findFor(spec) != null) return;
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
    throw UnsupportedError(
      'No registered embedding backend can run $filename on $platform. '
      'Registered: '
      '${backends.registered.map((b) => b.name).join(', ')}. Nothing was '
      'downloaded. Register a backend that runs this model (e.g. '
      'flutter_edge_ai_litertlm for .tflite and .litertlm, '
      'flutter_edge_ai_onnx for .onnx), or install a model one of these '
      'runs.',
    );
  }
}

/// Result of embedding model installation
class EmbeddingInstallation {
  final EmbeddingModelSpec spec;

  EmbeddingInstallation({required this.spec});

  /// Model ID (filename without extension)
  String get modelId => spec.name;
}
