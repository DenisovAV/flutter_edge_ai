import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_edge_ai/core/api/tts_asset_listing.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/model_management/model_activation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;

/// Fluent builder for TTS (text-to-speech) model installation.
///
/// The model is a bundle of files (see [TtsModelType.manifest]) installed from
/// one base — [fromNetwork], [fromAsset], [fromFile] or [fromBundled] (the
/// last one called wins) — plus [ofType]. Automatically sets the installed
/// model as the active TTS model. TTS does not run on web, so [install] throws
/// [UnsupportedError] there.
///
/// Usage:
/// ```dart
/// await FlutterEdgeAi.installTts()
///   .fromNetwork('https://example.com/matcha/', token: 'hf_...')
///   .ofType(TtsModelType.matcha)
///   .withProgress((p) => print('$p%'))
///   .install();
/// ```
class TtsInstallationBuilder {
  TtsBundleBase? _base;
  TtsModelType? _ttsModelType;
  String? _name;
  void Function(int overallPercent)? _onProgress;
  CancelToken? _cancelToken;

  /// Base URL the bundle files live under (each manifest filename is
  /// appended to it to derive the per-file network source).
  TtsInstallationBuilder fromNetwork(String baseUrl, {String? token}) {
    _base = TtsNetworkBase(baseUrl, token: token);
    return this;
  }

  /// Flutter asset directory holding the bundle, laid out like the model's
  /// Hugging Face repo: qwen3 keeps its `tables/` and `voices/` subdirectories,
  /// and Inflect's four reused Matcha G2P files sit next to its own two.
  ///
  /// Flutter does not include asset subdirectories recursively, so declare
  /// each one in the app's `pubspec.yaml`. Each file is copied into app
  /// storage on install, so the bundle takes space twice. On desktop the copy
  /// loads each file into memory first.
  TtsInstallationBuilder fromAsset(String directory) {
    _base = TtsAssetBase(directory);
    return this;
  }

  /// Absolute directory on disk holding the bundle, laid out as for
  /// [fromAsset]. The files are used where they are, not copied, so the app
  /// must be allowed to read them — and uninstalling the model deletes them.
  TtsInstallationBuilder fromFile(String directory) {
    _base = TtsFileBase(directory);
    return this;
  }

  /// Native bundled resources, one per manifest file, each named
  /// `<type>__<file>` — e.g. `matcha__config.json` — because a bundled
  /// resource name is flat. Android reads them from `assets/models/` in the
  /// APK and copies each into app storage once; iOS reads them in place from
  /// the app bundle. Android and iOS only.
  TtsInstallationBuilder fromBundled() {
    _base = const TtsBundledBase();
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
  /// - [UnsupportedError] on web, and for [fromBundled] off Android/iOS
  /// - [StateError] if the base source or [ofType] was not configured
  /// - [Exception] naming every missing file, if a local bundle is incomplete
  /// - [DownloadCancelledException] if cancelled via cancelToken
  /// - [Exception] on installation failure
  ///
  /// Note: This method is idempotent - a bundle file already installed from
  /// the same place is skipped and the spec is just (re-)set as active. A file
  /// installed from somewhere else is installed again from the new base.
  Future<TtsInstallation> install() async {
    if (kIsWeb) {
      throw UnsupportedError(
        'On-device TTS is not supported on web, so a TTS model cannot be '
        'installed there.',
      );
    }
    _cancelToken?.throwIfCancelled();

    final base = _base;
    if (base == null) {
      throw StateError(
        'Base source required. Use fromNetwork, fromAsset, fromFile or '
        'fromBundled.',
      );
    }
    final ttsModelType = _ttsModelType;
    if (ttsModelType == null) {
      throw StateError(
        'ofType(TtsModelType) is required, e.g. ofType(TtsModelType.matcha).',
      );
    }
    if (base is TtsBundledBase &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      throw UnsupportedError(
        'fromBundled() is available on Android and iOS only; use fromAsset or '
        'fromFile on ${defaultTargetPlatform.name}.',
      );
    }

    final spec = TtsModelSpec.fromManifest(
      name: _name ?? ttsModelType.name,
      ttsModelType: ttsModelType,
      sourceFor: (fn) => ttsModelType.sourceFor(fn, base),
    );

    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;
    final handlerRegistry = registry.sourceHandlerRegistry;
    final protectedFiles = registry.protectedFilesRegistry;

    await _requireLocalFiles(base, spec.files);

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
    final fs = registry.fileSystemService;
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final records = [
      for (final file in files) await repository.loadModel(file.filename),
    ];
    bool installedHere(int i) =>
        records[i]?.source.encode() == files[i].source.encode();

    // Files are replaced one by one, so a switch that fails halfway would
    // leave the active voice made of two bundles, and a restart would restore
    // that mix. Take the voice of this type out of service first; it is
    // activated again only once the whole bundle is in place, and a retry of
    // install() finishes the job.
    final active = manager.activeTtsModel;
    if (active is TtsModelSpec &&
        active.ttsModelType == ttsModelType &&
        !List.generate(files.length, installedHere).every((same) => same)) {
      await manager.clearActiveTtsIdentity();
    }

    var done = 0;
    for (var i = 0; i < files.length; i++) {
      _cancelToken?.throwIfCancelled();
      final file = files[i];
      final installed = records[i];

      // Skip only a file installed from this same place. One installed from
      // elsewhere (another directory, or a file used in place before a switch
      // to a download) is installed again, or the spec would point at a copy
      // that was never made. encode() leaves out auth tokens, so a new token
      // alone does not re-download.
      if (installedHere(i)) {
        edgeAiLog('ℹ️  TTS bundle file already installed: ${file.filename}');
      } else {
        edgeAiLog('📥 Installing TTS bundle file: ${file.filename}...');
        await handlerRegistry
            .getHandler(file.source)!
            .install(
              file.source,
              cancelToken: _cancelToken,
              targetFilename: file.filename,
              modelType: repo.ModelType.tts,
            );
        // Only now that the new copy is in place: a file used in place stays
        // registered under this name, so drop that, letting reads and uninstall
        // reach the copy and never the user's own file (left where it is).
        if (file.source is! FileSource &&
            await protectedFiles.getExternalPath(file.filename) != null) {
          await protectedFiles.unregisterExternalPath(file.filename);
          await protectedFiles.unprotect(file.filename);
        }
        // A copy the app made earlier (download, asset or Android bundled
        // copy) is dead weight once the file is read from somewhere else, and
        // orphan cleanup does not reclaim .npy/.gz members, so delete it.
        if (installed != null && installed.source is! FileSource) {
          final managed = await fs.getWriteTargetPath(file.filename);
          final now = switch (file.source) {
            FileSource(:final path) => path,
            BundledSource(:final resourceName) =>
              await fs.getBundledResourcePath(resourceName),
            _ => managed,
          };
          if (now != managed && await fs.fileExists(managed)) {
            await fs.deleteFile(managed);
          }
        }
      }
      done++;
      _onProgress?.call(((done / files.length) * 100).round());
    }

    // AUTO-SET as active TTS model (even if already installed).
    await activateInstalledModel(manager, spec);

    edgeAiLog('✅ TTS model installed and set as active: ${spec.name}');

    return TtsInstallation(spec: spec);
  }

  /// Fails before any file is recorded when a local bundle is incomplete,
  /// naming every missing file rather than the first one the install loop
  /// would stop at, so a failed install never leaves the active voice half
  /// replaced.
  Future<void> _requireLocalFiles(
    TtsBundleBase base,
    List<ModelFile> files,
  ) async {
    final fs = ServiceRegistry.instance.fileSystemService;
    final List<String> missing;
    switch (base) {
      case TtsFileBase():
        missing = [
          for (final file in files)
            if (file.source case FileSource(:final path))
              if (!await fs.fileExists(path)) path,
        ];
      case TtsAssetBase():
        final assets = await listAppAssets();
        missing = [
          for (final file in files)
            if (file.source case AssetSource(:final normalizedPath))
              if (!assets.contains(normalizedPath)) normalizedPath,
        ];
      case TtsBundledBase():
        // A bundled resource is only found by resolving it; on Android that
        // is the copy out of the APK, which the install then reuses.
        missing = [];
        for (final file in files) {
          if (file.source case BundledSource(:final resourceName)) {
            try {
              await fs.getBundledResourcePath(resourceName);
            } on Exception catch (e) {
              missing.add(
                '$resourceName (${e is PlatformException ? e.message : e})',
              );
            }
          }
        }
      case TtsNetworkBase():
        return;
    }
    if (missing.isEmpty) return;
    throw Exception(
      'TTS bundle is incomplete: ${missing.length} of ${files.length} files '
      'not found:\n  ${missing.join('\n  ')}',
    );
  }
}

/// Result of TTS model installation.
class TtsInstallation {
  final TtsModelSpec spec;

  TtsInstallation({required this.spec});

  /// Model ID (bundle name).
  String get modelId => spec.name;
}
