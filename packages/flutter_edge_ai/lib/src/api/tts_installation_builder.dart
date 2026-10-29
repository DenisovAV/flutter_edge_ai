import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_edge_ai/src/api/bundle_progress.dart';
import 'package:flutter_edge_ai/src/api/install_expectations.dart';
import 'package:flutter_edge_ai/src/api/tts_asset_listing.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/model_management/model_activation.dart';
import 'package:flutter_edge_ai/src/model_management/install_rule.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;

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

  /// Sizes known before the install (by each file's plain manifest name):
  /// used for progress without a HEAD request, and checked before the
  /// voice becomes active.
  Map<String, int>? _knownSizes;

  /// The catalog variant this builder installs ([fromCatalog]).
  TtsVariant? _catalogVariant;

  /// Install a model registry build: its pinned base URL, type and the size
  /// of every file. The sizes are checked before the voice becomes active,
  /// and [withProgress] weights by them without asking the network.
  ///
  /// [install] throws, before anything downloads, [UnsupportedError] for a
  /// variant whose `backendsHere` is empty, and [ArgumentError] when the
  /// variant's files are not the type's bundle.
  TtsInstallationBuilder fromCatalog(TtsVariant variant, {String? token}) {
    fromNetwork(variant.baseUrl, token: token);
    _catalogVariant = variant;
    _knownSizes = {
      for (final file in variant.files) file.installFilename: file.sizeBytes,
    };
    return ofType(variant.type);
  }

  /// Base URL the bundle files live under (each manifest filename is
  /// appended to it to derive the per-file network source).
  TtsInstallationBuilder fromNetwork(String baseUrl, {String? token}) {
    _base = TtsNetworkBase(baseUrl, token: token);
    _knownSizes = null;
    _catalogVariant = null;
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
    _knownSizes = null;
    _catalogVariant = null;
    return this;
  }

  /// Absolute directory on disk holding the bundle, laid out as for
  /// [fromAsset]. The files are used where they are, not copied, so the app
  /// must be allowed to read them; uninstalling the model leaves them there.
  TtsInstallationBuilder fromFile(String directory) {
    _base = TtsFileBase(directory);
    _knownSizes = null;
    _catalogVariant = null;
    return this;
  }

  /// Native bundled resources, one per manifest file, each named
  /// `<type>__<file>` — e.g. `matcha__config.json` — because a bundled
  /// resource name is flat. Android reads them from `assets/models/` in the
  /// APK and copies each into app storage once; iOS reads them in place from
  /// the app bundle. Android and iOS only.
  TtsInstallationBuilder fromBundled() {
    _base = const TtsBundledBase();
    _knownSizes = null;
    _catalogVariant = null;
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

  /// Progress of the whole bundle, 0 to 100, by bytes across its files.
  ///
  /// Before the first download the size of each file is read: a network file
  /// with one HEAD request (all at once, with the download's token), a file
  /// already installed or passed with [fromFile] from disk. Files installed
  /// already count from the start. An asset or bundled file has no size
  /// before its copy; when a size is unknown, every file counts the same, and
  /// each file's own progress still moves continuously. Values only rise, and
  /// a successful install ends with 100.
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
  /// installed from somewhere else is installed again from the new base, and
  /// core's earlier copy of it is deleted once the new bundle is active (or
  /// at the next start).
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

    if (_catalogVariant case final variant?) {
      checkCatalogVariant(variant);
      // The bundle's files come from the type; each must be one the catalog
      // lists, checked before the installer takes the active voice out of
      // service.
      final listed = {for (final f in variant.files) f.installFilename};
      final missing = [
        for (final name in ttsModelType.manifest)
          if (!listed.contains(name)) name,
      ];
      if (missing.isNotEmpty) {
        throw ArgumentError.value(
          variant,
          'variant',
          '${variant.id} does not list ${missing.join(', ')}, which a '
              '${ttsModelType.name} bundle installs',
        );
      }
    }

    final spec = TtsModelSpec.fromManifest(
      name: _name ?? ttsModelType.name,
      ttsModelType: ttsModelType,
      sourceFor: (fn) => ttsModelType.sourceFor(fn, base),
    );

    await _requireLocalFiles(base, spec.files);

    // A catalog variant's files are checked by size, so each must be the one
    // this install downloads: the URL the variant lists for the name.
    if (_catalogVariant case final variant?) {
      final urls = {for (final f in variant.files) f.installFilename: f.url};
      final elsewhere = [
        for (final file in spec.files)
          if (file.source case NetworkSource(
            :final url,
          ) when urls[file.prefsKey] != url)
            file.filename,
      ];
      if (elsewhere.isNotEmpty) {
        throw ArgumentError.value(
          variant,
          'variant',
          '${variant.id} lists other URLs than this install downloads for '
              '${elsewhere.join(', ')}',
        );
      }
    }

    // NOTE: install-time legacy-file adoption (renaming an on-disk
    // pre-1.5.1-namespacing plain file onto the namespaced identity) was
    // removed here — a bundle basename can be unique within the TTS catalog
    // yet still collide with a plain file left behind by an STT/embedding
    // install (e.g. Qwen3's `tokenizer.json`), and adoption has no way to
    // verify the on-disk file actually belongs to this model (no size/hash
    // check available). A manifest file that is not already installed is
    // downloaded fresh (never adopted from a legacy plain file);
    // already-installed files are still skipped (see install_rule.dart). The
    // safe migration path for genuinely-legacy TTS installs is restore-time,
    // in MobileModelManager._migrateLegacyCompanionForRestore.
    final files = spec.files;
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final steps = await planInstall(files);
    final sizes = _knownSizes;
    final expected = {
      if (sizes != null)
        for (final file in spec.files)
          if (sizes[file.prefsKey] case final size?)
            file.filename: FileExpectation(size: size),
    };
    // Read before the install takes the voice of this type out of service.
    final activeBefore = manager.activeTtsModel;
    refuseReplacingActive(steps, expected, activeBefore);
    final progress = await startBundleProgress(
      _onProgress,
      steps,
      known: _knownSizes,
      cancelToken: _cancelToken,
      bundle: spec.name,
    );
    final release = await installPlanned(
      steps,
      modelType: repo.ModelType.tts,
      cancelToken: _cancelToken,
      progress: [
        if (progress != null)
          for (var i = 0; i < files.length; i++)
            (percent) => progress.report(i, percent),
      ],
      // Files are replaced one by one, so a switch that fails halfway would
      // leave the active voice made of two bundles, and a restart would
      // restore that mix. Take the voice of this type out of service first;
      // it is activated again only once the whole bundle is in place, and a
      // retry of install() finishes the job.
      beforeInstalling: () async {
        final active = manager.activeTtsModel;
        if (active is TtsModelSpec && active.ttsModelType == ttsModelType) {
          await manager.clearActiveTtsIdentity();
        }
      },
      onFileDone: (i) => progress?.report(i, 100),
    );

    // AUTO-SET as active TTS model (even if already installed).
    _cancelToken?.throwIfCancelled();
    await verifyInstalledFiles(
      spec,
      expected,
      steps: steps,
      active: activeBefore,
      cancelToken: _cancelToken,
    );
    _cancelToken?.throwIfCancelled();
    await activateInstalledModel(manager, spec);
    await release.run(manager, spec);
    progress?.complete();

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
