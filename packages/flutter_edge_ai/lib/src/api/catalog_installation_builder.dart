import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/api/install_verification.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show InferenceModelFile;

/// Installs a [CatalogVariant] through the installer of its kind, from
/// `FlutterEdgeAi.installFromCatalog`.
///
/// The model type, file type, file names and profile come from the variant,
/// so none of them can be passed wrong. After the download, and before the
/// model becomes active, every file's size is compared with the catalog's
/// (not on the web, where the browser stores the files).
///
/// The catalog pins each file to a revision. A model installed earlier from
/// a `/resolve/main/` URL is therefore a different source, and its first
/// install from the catalog downloads the file again.
///
/// A LoRA is not installed through the catalog: install it with
/// `FlutterEdgeAi.installModel(…).withLoraFromNetwork(…)`.
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
  int? _lastPercent;
  CancelToken? _cancelToken;
  bool? _foreground;

  /// The Hugging Face token for a gated repository; without it, the token
  /// passed to `FlutterEdgeAi.initialize` is used for huggingface.co.
  CatalogInstallationBuilder withToken(String token) {
    _token = token;
    return this;
  }

  /// Progress of the whole install, 0 to 100, weighted by file size. A
  /// successful install ends with 100, also when files were already
  /// installed and not downloaded.
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

  void _progress(int percent) {
    _lastPercent = percent;
    _onProgress?.call(percent);
  }

  /// Installs the variant and makes it the active model of its kind.
  ///
  /// With [activate] false an [InferenceVariant] is installed without
  /// becoming the active model, for `FlutterEdgeAi.openModel`; the other
  /// kinds have one active model each and throw [ArgumentError] for it.
  ///
  /// Throws [UnsupportedError], before anything is downloaded, for a variant
  /// whose [CatalogVariant.backendsHere] is empty (its package does not run
  /// it in this runtime: an NPU build on a device without that vendor's
  /// dispatch, a web bundle off the web) and for a variant with no file (a
  /// model the operating system provides); [CatalogInstallException] when an
  /// installed file's size is not the catalog's, and whatever the installer
  /// of the variant's kind throws.
  Future<CatalogInstallation> install({bool activate = true}) async {
    final variant = _variant;
    if (variant.backendsHere.isEmpty) {
      throw UnsupportedError(
        '${variant.id} does not run here: ${variant.catalogName} runs it on '
        'no backend in this runtime. Pick another variant, for example with '
        'CatalogModel.variantFor',
      );
    }
    if (!activate && variant is! InferenceVariant) {
      throw ArgumentError.value(
        activate,
        'activate',
        '${variant.id} is not an LLM; only an LLM installs without becoming '
            'the active model',
      );
    }
    var checked = false;
    Future<void> check(ModelSpec spec) async {
      await _checkSizes(spec);
      checked = true;
    }

    final ModelSpec spec = switch (variant) {
      InferenceVariant() => await _inference(variant, activate, check),
      EmbedderVariant() => await _embedder(variant, check),
      SttVariant() => await _stt(variant, check),
      TtsVariant() => await _tts(variant, check),
    };
    // An LLM installed with activate false is never made active, so its
    // builder runs no check before activation.
    if (!checked) await _checkSizes(spec);
    if (_onProgress != null && _lastPercent != 100) _progress(100);
    return CatalogInstallation._(variant: variant, spec: spec);
  }

  Future<ModelSpec> _inference(
    InferenceVariant v,
    bool activate,
    _Check check,
  ) async {
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
    verifyBeforeActivation[builder] = check;
    if (_onProgress != null) builder = builder.withProgress(_progress);
    if (_cancelToken case final cancelToken?) {
      builder = builder.withCancelToken(cancelToken);
    }
    return (await builder.install(activate: activate)).spec;
  }

  Future<ModelSpec> _embedder(EmbedderVariant v, _Check check) async {
    final progress = _WeightedProgress(
      _onProgress == null ? null : _progress,
      v.files,
    );
    var builder = FlutterEdgeAi.installEmbedder()
        .modelFromNetwork(
          v.model.url,
          token: _token,
          filename: v.model.installFilename,
        )
        .withModelProgress(progress.reporterFor(v.model));
    verifyBeforeActivation[builder] = check;
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

  Future<ModelSpec> _stt(SttVariant v, _Check check) async {
    final progress = _WeightedProgress(
      _onProgress == null ? null : _progress,
      v.files,
    );
    var builder = FlutterEdgeAi.installStt()
        .modelFromNetwork(v.model.url, token: _token)
        .tokenizerFromNetwork(v.tokenizer.url, token: _token)
        .ofType(v.type)
        .withModelProgress(progress.reporterFor(v.model))
        .withTokenizerProgress(progress.reporterFor(v.tokenizer));
    verifyBeforeActivation[builder] = check;
    if (_cancelToken case final cancelToken?) {
      builder = builder.withCancelToken(cancelToken);
    }
    return (await builder.install()).spec;
  }

  Future<ModelSpec> _tts(TtsVariant v, _Check check) async {
    var builder = FlutterEdgeAi.installTts()
        .fromNetwork(v.baseUrl, token: _token)
        .ofType(v.type);
    verifyBeforeActivation[builder] = check;
    if (_onProgress != null) {
      // The TTS installer's public progress counts finished files; ask it
      // for each file's own progress and weight that by the catalog's sizes.
      final progress = _WeightedProgress(_progress, v.files);
      fileProgressFor[builder] = (filename, percent) {
        final artifact = _artifactNamed(v, filename);
        progress.reporterFor(artifact)(percent);
      };
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
      if (path == null) {
        throw CatalogInstallException(
          '${_variant.id}: core has no path for ${artifact.installFilename}, '
          'so its size cannot be checked',
        );
      }
      final size = await fileSystem.getFileSize(path);
      if (size != artifact.sizeBytes) {
        throw CatalogInstallException(
          '${_variant.id}: ${artifact.installFilename} is $size bytes, the '
          'catalog says ${artifact.sizeBytes} (${artifact.url}). The file '
          'stays installed but was not made active; uninstall it and '
          'install again.',
          artifact: artifact,
        );
      }
    }
  }
}

typedef _Check = Future<void> Function(ModelSpec spec);

/// The artifact of [v] that core installs as [filename]: the catalog's
/// install name, under the model's prefix for a speech bundle.
ModelArtifact _artifactNamed(CatalogVariant v, String filename) {
  for (final artifact in v.files) {
    if (filename == artifact.installFilename ||
        filename.endsWith('__${artifact.installFilename}')) {
      return artifact;
    }
  }
  throw CatalogInstallException(
    '${v.id}: the install writes $filename, which the catalog does not list',
  );
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
