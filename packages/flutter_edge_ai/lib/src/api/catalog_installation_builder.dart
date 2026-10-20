import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show InferenceModelFile;

/// Installs a [CatalogVariant] through the installer of its kind, from
/// `FlutterEdgeAi.installFromCatalog`.
///
/// The model type, file type, file names and profile come from the variant,
/// so none of them can be passed wrong. After the download every file's size
/// is compared with the catalog's (not on the web, where the browser stores
/// the files).
///
/// ```dart
/// final variant = FlutterEdgeAi.catalog
///     .byId('gemma-4-e2b-it')!
///     .variantFor(backend: PreferredBackend.gpu)! as InferenceVariant;
/// final installation = await FlutterEdgeAi.installFromCatalog(variant)
///     .withProgress((p) => print('$p%'))
///     .install();
/// final model = await FlutterEdgeAi.getActiveModel(
///   defaults: variant.runtimeDefaults,
/// );
/// ```
final class CatalogInstallationBuilder {
  /// A builder for [variant].
  CatalogInstallationBuilder(this._variant);

  final CatalogVariant _variant;
  String? _token;
  void Function(int percent)? _onProgress;
  CancelToken? _cancelToken;
  bool? _foreground;

  /// The Hugging Face token for a gated repository; without it, the token
  /// passed to `FlutterEdgeAi.initialize` is used for huggingface.co.
  CatalogInstallationBuilder withToken(String token) {
    _token = token;
    return this;
  }

  /// Progress of the whole install, 0 to 100, weighted by file size.
  CatalogInstallationBuilder withProgress(
    void Function(int percent) onProgress,
  ) {
    _onProgress = onProgress;
    return this;
  }

  /// Cancels the install.
  CatalogInstallationBuilder withCancelToken(CancelToken cancelToken) {
    _cancelToken = cancelToken;
    return this;
  }

  /// Android: download an LLM in a foreground service, as
  /// `InferenceInstallationBuilder.fromNetwork(foreground:)` does. Ignored for
  /// the other kinds.
  CatalogInstallationBuilder withForeground(bool foreground) {
    _foreground = foreground;
    return this;
  }

  /// Installs the variant and makes it the active model of its kind.
  ///
  /// With [activate] false an [InferenceVariant] is installed without
  /// becoming the active model, for `FlutterEdgeAi.openModel`; the other
  /// kinds have one active model each and throw [ArgumentError] for it.
  ///
  /// Throws [UnsupportedError] for a variant with no file (a model the
  /// operating system provides), [CatalogInstallException] when an installed
  /// file's size is not the catalog's, and whatever the installer of the
  /// variant's kind throws.
  Future<CatalogInstallation> install({bool activate = true}) async {
    final variant = _variant;
    if (!activate && variant is! InferenceVariant) {
      throw ArgumentError.value(
        activate,
        'activate',
        '${variant.id} is not an LLM; only an LLM installs without becoming '
            'the active model',
      );
    }
    final ModelSpec spec = switch (variant) {
      InferenceVariant() => await _inference(variant, activate),
      EmbedderVariant() => await _embedder(variant),
      SttVariant() => await _stt(variant),
      TtsVariant() => await _tts(variant),
    };
    await _checkSizes(spec);
    return CatalogInstallation._(variant: variant, spec: spec);
  }

  Future<ModelSpec> _inference(InferenceVariant v, bool activate) async {
    final file = v.file;
    if (file == null) {
      throw UnsupportedError(
        '${v.id} is provided by the operating system; there is nothing to '
        'install',
      );
    }
    // Core keys an LLM by its URL's file name, so the catalog's install name
    // has to be that name.
    final urlName = InferenceModelFile.fromSource(
      ModelSource.network(file.url),
    ).filename;
    if (urlName != file.installFilename) {
      throw ArgumentError.value(
        v,
        'variant',
        '${v.id} installs as "${file.installFilename}", but an LLM is '
            'installed under its URL\'s file name "$urlName"',
      );
    }
    var builder = FlutterEdgeAi.installModel(
      modelType: v.modelType,
      fileType: v.fileType,
    ).fromNetwork(file.url, token: _token, foreground: _foreground);
    if (_onProgress case final onProgress?) {
      builder = builder.withProgress(onProgress);
    }
    if (_cancelToken case final cancelToken?) {
      builder = builder.withCancelToken(cancelToken);
    }
    return (await builder.install(activate: activate)).spec;
  }

  Future<ModelSpec> _embedder(EmbedderVariant v) async {
    final progress = _WeightedProgress(_onProgress, v.files);
    var builder = FlutterEdgeAi.installEmbedder()
        .modelFromNetwork(
          v.model.url,
          token: _token,
          filename: v.model.installFilename,
        )
        .withModelProgress(progress.reporterFor(v.model));
    if (v.tokenizer case final tokenizer?) {
      builder = builder
          .tokenizerFromNetwork(
            tokenizer.url,
            token: _token,
            filename: tokenizer.installFilename,
          )
          .withTokenizerProgress(progress.reporterFor(tokenizer));
    }
    if (_cancelToken case final cancelToken?) {
      builder = builder.withCancelToken(cancelToken);
    }
    return (await builder.install()).spec;
  }

  Future<ModelSpec> _stt(SttVariant v) async {
    final progress = _WeightedProgress(_onProgress, v.files);
    var builder = FlutterEdgeAi.installStt()
        .modelFromNetwork(v.model.url, token: _token)
        .tokenizerFromNetwork(v.tokenizer.url, token: _token)
        .ofType(v.type)
        .withModelProgress(progress.reporterFor(v.model))
        .withTokenizerProgress(progress.reporterFor(v.tokenizer));
    if (_cancelToken case final cancelToken?) {
      builder = builder.withCancelToken(cancelToken);
    }
    return (await builder.install()).spec;
  }

  Future<ModelSpec> _tts(TtsVariant v) async {
    var builder = FlutterEdgeAi.installTts()
        .fromNetwork(v.baseUrl, token: _token)
        .ofType(v.type);
    if (_onProgress case final onProgress?) {
      builder = builder.withProgress(onProgress);
    }
    if (_cancelToken case final cancelToken?) {
      builder = builder.withCancelToken(cancelToken);
    }
    return (await builder.install()).spec;
  }

  /// Every file of the variant against the file the install wrote. A speech
  /// file is stored under its model's prefix, `<model>__<name>`.
  Future<void> _checkSizes(ModelSpec spec) async {
    if (kIsWeb) return;
    final paths = await FlutterEdgeAiPlugin.instance.modelManager
        .getModelFilePaths(spec);
    if (paths == null) {
      throw CatalogInstallException(
        '${_variant.id}: the install finished, but core reports it not '
        'installed',
      );
    }
    final fileSystem = ServiceRegistry.instance.fileSystemService;
    for (final artifact in _variant.files) {
      final installed = spec.files.where(
        (f) =>
            f.filename == artifact.installFilename ||
            f.filename.endsWith('__${artifact.installFilename}'),
      );
      if (installed.isEmpty) {
        throw CatalogInstallException(
          '${_variant.id}: the catalog lists ${artifact.installFilename}, '
          'which the install did not write',
          artifact: artifact,
        );
      }
      final path = paths[installed.first.prefsKey];
      if (path == null) continue;
      final size = await fileSystem.getFileSize(path);
      if (size != artifact.sizeBytes) {
        throw CatalogInstallException(
          '${_variant.id}: ${artifact.installFilename} is $size bytes, the '
          'catalog says ${artifact.sizeBytes} (${artifact.url}). The file '
          'stays installed; uninstall it and install again.',
          artifact: artifact,
        );
      }
    }
  }
}

/// One progress value for several files, each weighted by its size.
final class _WeightedProgress {
  _WeightedProgress(this._onProgress, List<ModelArtifact> files)
    : _total = files.fold(0, (sum, a) => sum + a.sizeBytes);

  final void Function(int percent)? _onProgress;
  final int _total;
  final _done = <ModelArtifact, int>{};

  void Function(int percent) reporterFor(ModelArtifact artifact) => (percent) {
    final onProgress = _onProgress;
    if (onProgress == null || _total == 0) return;
    _done[artifact] = artifact.sizeBytes * percent ~/ 100;
    final done = _done.values.fold(0, (sum, bytes) => sum + bytes);
    onProgress((done * 100 / _total).round().clamp(0, 100));
  };
}

/// The result of `FlutterEdgeAi.installFromCatalog(…).install()`.
final class CatalogInstallation {
  const CatalogInstallation._({required this.variant, required this.spec});

  /// The variant that was installed.
  final CatalogVariant variant;

  /// What core installed. For an [InferenceVariant] an [InferenceModelSpec],
  /// which `FlutterEdgeAi.openModel` takes.
  final ModelSpec spec;

  @override
  String toString() => 'CatalogInstallation(${variant.id})';
}

/// A catalog install wrote something other than what the catalog lists.
final class CatalogInstallException implements Exception {
  /// An exception with [message], about [artifact] when there is one.
  const CatalogInstallException(this.message, {this.artifact});

  /// What went wrong.
  final String message;

  /// The file it is about.
  final ModelArtifact? artifact;

  @override
  String toString() => 'CatalogInstallException: $message';
}
