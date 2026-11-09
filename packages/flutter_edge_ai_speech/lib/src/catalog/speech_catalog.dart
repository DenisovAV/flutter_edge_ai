// The speech models this package runs, from the project's model registry
// (model_registry/ in the repository): every file pinned to a Hugging Face
// commit and checked against its bytes. The data is generated into
// generated/speech_catalog.g.dart; this file holds the types and the rule for
// where a variant runs.

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmNpuTarget;

import 'speech_catalog_host_web.dart'
    if (dart.library.ffi) 'speech_catalog_host_io.dart'
    as host;

part 'generated/speech_catalog.g.dart';

/// Replaces [kIsWeb] for the runtime [CatalogVariant.backendsHere] answers
/// for. Tests only.
@visibleForTesting
bool? debugSpeechCatalogOnWeb;

/// Replaces the host's `Abi.current()` for the runtime
/// [CatalogVariant.backendsHere] answers. Tests only.
@visibleForTesting
String? debugSpeechCatalogAbi;

/// The hosts flutter_edge_ai_litertlm's native archive, which this package
/// runs on, is published for — that package's `lib/src/native_hosts.dart`
/// (`liteRtLmNativeAbis`); a test keeps the two equal.
const _nativeAbis = {
  'android_arm64',
  'ios_arm64',
  'macos_arm64',
  'linux_x64',
  'linux_arm64',
  'windows_x64',
};

/// This package runs speech natively, on the CPU or the GPU it is asked for:
/// not on the web, not on a host the native archive is not published for,
/// and not a file compiled for an NPU, whose dispatch it does not load.
Set<PreferredBackend> _backendsHere({required bool compiledForNpu}) {
  if (debugSpeechCatalogOnWeb ?? kIsWeb) return const {};
  final abi = debugSpeechCatalogAbi ?? host.speechCatalogHostAbi;
  if (!_nativeAbis.contains(abi)) return const {};
  if (compiledForNpu) return const {};
  return const {PreferredBackend.cpu, PreferredBackend.gpu};
}

/// A catalog of this package's models.
final class LiteRtSpeechCatalog extends ModelCatalog {
  const LiteRtSpeechCatalog._(this.name, this.models);

  @override
  final String name;

  @override
  final List<CatalogModel> models;
}

/// A speech-to-text model this package runs.
final class LiteRtSttModel extends CatalogModel {
  const LiteRtSttModel._({
    required this.id,
    required this.displayName,
    required this.family,
    required this.license,
    required this.licenseUrl,
    required this.variants,
  });

  @override
  final String id;

  @override
  final String displayName;

  @override
  final String family;

  @override
  String get archClass => 'speech-recognition';

  @override
  final String license;

  @override
  final String licenseUrl;

  @override
  final List<LiteRtSttVariant> variants;

  @override
  LiteRtSttVariant? variantFor({PreferredBackend? backend, NpuTarget? npu}) =>
      super.variantFor(backend: backend, npu: npu) as LiteRtSttVariant?;
}

/// One `.tflite` file of a [LiteRtSttModel], with its tokenizer.
final class LiteRtSttVariant extends SttVariant {
  const LiteRtSttVariant._({
    required this.id,
    required this.modelId,
    required this.type,
    required this.model,
    required this.tokenizer,
    this.npuTarget,
    Set<PreferredBackend> withheld = const {},
  }) : _withheld = withheld;

  /// Backends the registry withholds this variant from (all of them for a
  /// withheld variant, which stays in the catalog, deprecated).
  final Set<PreferredBackend> _withheld;

  @override
  final String id;

  @override
  final String modelId;

  @override
  String get catalogName => 'flutter_edge_ai_speech';

  @override
  final SttModelType type;

  @override
  final ModelArtifact model;

  @override
  final ModelArtifact tokenizer;

  /// The NPU the file is compiled for, as its compiler stamped it.
  @override
  final LiteRtLmNpuTarget? npuTarget;

  @override
  Set<PreferredBackend> get backendsHere =>
      _backendsHere(compiledForNpu: npuTarget != null).difference(_withheld);
}

/// A text-to-speech model this package runs.
final class LiteRtTtsModel extends CatalogModel {
  const LiteRtTtsModel._({
    required this.id,
    required this.displayName,
    required this.family,
    required this.license,
    required this.licenseUrl,
    required this.variants,
  });

  @override
  final String id;

  @override
  final String displayName;

  @override
  final String family;

  @override
  String get archClass => 'speech-synthesis';

  @override
  final String license;

  @override
  final String licenseUrl;

  @override
  final List<LiteRtTtsVariant> variants;

  @override
  LiteRtTtsVariant? variantFor({PreferredBackend? backend, NpuTarget? npu}) =>
      super.variantFor(backend: backend, npu: npu) as LiteRtTtsVariant?;
}

/// The files of a [LiteRtTtsModel], installed together from [baseUrl].
final class LiteRtTtsVariant extends TtsVariant {
  const LiteRtTtsVariant._({
    required this.id,
    required this.modelId,
    required this.type,
    required this.baseUrl,
    required this.files,
    Set<PreferredBackend> withheld = const {},
  }) : _withheld = withheld;

  /// Backends the registry withholds this variant from (see
  /// [LiteRtSttVariant]).
  final Set<PreferredBackend> _withheld;

  @override
  final String id;

  @override
  final String modelId;

  @override
  String get catalogName => 'flutter_edge_ai_speech';

  @override
  final TtsModelType type;

  @override
  final String baseUrl;

  /// Every file of the bundle, in the order of `TtsModelType.manifest`.
  @override
  final List<ModelArtifact> files;

  @override
  Set<PreferredBackend> get backendsHere =>
      _backendsHere(compiledForNpu: false).difference(_withheld);
}
