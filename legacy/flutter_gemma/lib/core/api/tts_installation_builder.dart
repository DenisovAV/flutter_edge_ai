import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/core/services/model_repository.dart' as repo;

/// Fluent builder for TTS (text-to-speech) model installation.
///
/// The model is a bundle of files (see [TtsModelType.manifest]) fetched from
/// one base source; install requires [fromNetwork] + [ofType]. Automatically
/// sets the installed model as the active TTS model.
///
/// Usage:
/// ```dart
/// await FlutterGemma.installTts()
///   .fromNetwork('https://example.com/matcha/', token: 'hf_...')
///   .ofType(TtsModelType.matcha)
///   .withProgress((p) => print('$p%'))
///   .install();
/// ```
class TtsInstallationBuilder {
  String? _baseUrl;
  String? _token;
  TtsModelType? _ttsModelType;
  String? _name;
  void Function(int overallPercent)? _onProgress;
  CancelToken? _cancelToken;

  /// Base URL the bundle files live under (each manifest filename is
  /// appended to it to derive the per-file network source).
  TtsInstallationBuilder fromNetwork(String baseUrl, {String? token}) {
    _baseUrl = baseUrl;
    _token = token;
    return this;
  }

  /// Set the TTS model family ([TtsModelType]) this install represents.
  ///
  /// Required — determines the manifest of files fetched from the base
  /// source, and carried on the installed [TtsModelSpec] so a single
  /// generic backend can select the right runtime profile.
  TtsInstallationBuilder ofType(TtsModelType ttsModelType) {
    _ttsModelType = ttsModelType;
    return this;
  }

  /// Override the installed spec's name. Defaults to [ttsModelType]'s name.
  TtsInstallationBuilder named(String name) {
    _name = name;
    return this;
  }

  /// Overall bundle install progress (0-100), across all manifest files.
  TtsInstallationBuilder withProgress(void Function(int overallPercent) cb) {
    _onProgress = cb;
    return this;
  }

  /// Set cancellation token for this installation.
  TtsInstallationBuilder withCancelToken(CancelToken cancelToken) {
    _cancelToken = cancelToken;
    return this;
  }

  /// Execute the installation and automatically set as active TTS model.
  ///
  /// Returns [TtsInstallation] with details about the installed model.
  ///
  /// Throws:
  /// - [StateError] if the base source or [ofType] was not configured
  /// - [DownloadCancelledException] if cancelled via cancelToken
  /// - [Exception] on installation failure
  ///
  /// Note: This method is idempotent - already-installed bundle files are
  /// skipped and the spec is just (re-)set as active.
  Future<TtsInstallation> install() async {
    _cancelToken?.throwIfCancelled();

    final baseUrl = _baseUrl;
    if (baseUrl == null) {
      throw StateError('Base source required. Use fromNetwork(baseUrl).');
    }
    final ttsModelType = _ttsModelType;
    if (ttsModelType == null) {
      throw StateError(
        'ofType(TtsModelType) is required, e.g. ofType(TtsModelType.matcha).',
      );
    }

    // Most bundle members are fetched from `baseUrl/<plain filename>`, but a
    // few (e.g. qwen3's embedding tables + demo voice) live under a
    // subdirectory on the origin server even though their INSTALLED
    // identity is the plain basename — see
    // `TtsModelTypeManifest.fetchLocationFor`'s doc for why that split is
    // safe. An absolute location (a cross-repo full URL, e.g. Inflect's
    // reused Matcha G2P files) is fetched as-is, not appended to [base].
    String joinUrl(String base, String fn) =>
        switch (ttsModelType.fetchLocationFor(fn)) {
          TtsAbsoluteUrl(:final url) => url,
          TtsRelativeSuffix(:final suffix) =>
            base.endsWith('/') ? '$base$suffix' : '$base/$suffix',
        };

    final spec = TtsModelSpec.fromManifest(
      name: _name ?? ttsModelType.name,
      ttsModelType: ttsModelType,
      sourceFor: (fn) =>
          ModelSource.network(joinUrl(baseUrl, fn), authToken: _token),
    );

    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;
    final handlerRegistry = registry.sourceHandlerRegistry;

    // NOTE: install-time legacy-file adoption (renaming an on-disk
    // pre-1.5.1-namespacing plain file onto the namespaced identity) was
    // removed here — a bundle basename can be unique within the TTS catalog
    // yet still collide with a plain file left behind by an STT/embedding
    // install (e.g. Qwen3's `tokenizer.json`), and adoption has no way to
    // verify the on-disk file actually belongs to this model (no size/hash
    // check available). A manifest file that is not already installed is
    // downloaded fresh (never adopted from a legacy plain file);
    // already-installed files are still skipped by the loop below. The safe
    // migration path for genuinely-legacy TTS installs is restore-time, in
    // MobileModelManager._migrateLegacyCompanionForRestore.
    final files = spec.files;
    var done = 0;
    for (var i = 0; i < files.length; i++) {
      _cancelToken?.throwIfCancelled();
      final file = files[i];

      if (await repository.isInstalled(file.filename)) {
        gemmaLog('ℹ️  TTS bundle file already installed: ${file.filename}');
      } else {
        gemmaLog('📥 Installing TTS bundle file: ${file.filename}...');
        final handler = handlerRegistry.getHandler(file.source);
        await handler!.install(
          file.source,
          cancelToken: _cancelToken,
          targetFilename: file.filename,
          modelType: repo.ModelType.tts,
        );
      }
      done++;
      _onProgress?.call(((done / files.length) * 100).round());
    }

    // AUTO-SET as active TTS model (even if already installed).
    final manager = FlutterGemmaPlugin.instance.modelManager;
    manager.setActiveModel(spec);

    gemmaLog('✅ TTS model installed and set as active: ${spec.name}');

    return TtsInstallation(spec: spec);
  }
}

/// Result of TTS model installation.
class TtsInstallation {
  final TtsModelSpec spec;

  TtsInstallation({required this.spec});

  /// Model ID (bundle name).
  String get modelId => spec.name;
}
