import 'package:flutter_edge_ai/src/catalog/model_artifact.dart';
import 'package:flutter_edge_ai/src/catalog/npu_target.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show SttModelType, TtsModelType;
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver.dart'
    show ModelRuntimeDefaults;

/// A model in a catalog: what to show and how to group it. What to install
/// is on its [variants].
///
/// Engines extend this with their own final classes; an app reads them from
/// `FlutterEdgeAi.catalog` or from an engine package's catalog.
abstract base class CatalogModel {
  /// For subclasses.
  const CatalogModel();

  /// Shared by every package that offers this model: `gemma-4-e2b-it`.
  String get id;

  /// The name to show.
  String get displayName;

  /// The model family, for grouping: `gemma4`, `qwen3`.
  String get family;

  /// The kind of architecture: `dense`, `matformer-ple`, `vision-language`,
  /// `encoder`.
  String get archClass;

  /// Parameters in billions, when known.
  double? get parametersB => null;

  /// The license, as its SPDX-like id: `apache-2.0`, `gemma`.
  String get license;

  /// Where the license text is.
  String get licenseUrl;

  /// The installable variants, in the order the catalog prefers them.
  List<CatalogVariant> get variants;

  /// The variant to install for this runtime, or null when none can run here.
  ///
  /// Only variants whose [CatalogVariant.backendsHere] is not empty are
  /// considered, and with [backend] only those that run on it. A variant
  /// compiled for an NPU is chosen only for its SoC: pass [npu] (the package
  /// does not read the device's SoC), or ask for [PreferredBackend.npu] when
  /// one SoC remains. Otherwise the first variant that is not compiled for an
  /// NPU wins, in catalog order.
  ///
  /// Throws [ArgumentError] when [backend] is [PreferredBackend.npu], [npu]
  /// is null, and variants for several SoCs remain.
  CatalogVariant? variantFor({PreferredBackend? backend, NpuTarget? npu}) {
    var pool = [
      for (final v in variants)
        if (v.backendsHere.isNotEmpty &&
            (backend == null || v.backendsHere.contains(backend)))
          v,
    ];
    if (npu != null) {
      for (final v in pool) {
        if (v.npuTarget?.sameSoc(npu) ?? false) return v;
      }
      if (backend == PreferredBackend.npu) return null;
    } else if (backend == PreferredBackend.npu) {
      final socs = {
        for (final v in pool)
          if (v.npuTarget case final t?) (t.npuVendor, t.socModel),
      };
      if (socs.length > 1) {
        throw ArgumentError.value(
          npu,
          'npu',
          '$id has NPU builds for ${socs.map((s) => s.$2).join(', ')}; pass '
              'the device SoC',
        );
      }
      return pool.firstOrNull;
    }
    pool = [
      for (final v in pool)
        if (v.npuTarget == null) v,
    ];
    return pool.firstOrNull;
  }

  @override
  String toString() => '$runtimeType($id, ${variants.length} variants)';
}

/// One installable form of a [CatalogModel]: its files and where they run.
/// One subclass per installer, so a variant reaches only the installer that
/// can take it.
sealed class CatalogVariant {
  const CatalogVariant();

  /// Unique across catalogs: `<model id>/<slug>`, e.g.
  /// `gemma-4-e2b-it/npu-sm8750`.
  String get id;

  /// The [CatalogModel.id] this variant belongs to.
  String get modelId;

  /// The package whose catalog lists this variant:
  /// `flutter_edge_ai_litertlm`.
  String get catalogName;

  /// Every file an install downloads.
  List<ModelArtifact> get files;

  /// The NPU the variant is compiled for; null for one that is not.
  NpuTarget? get npuTarget => null;

  /// The backends this version of the variant's package runs it on, in this
  /// runtime. Empty when the package does not run it here: an NPU build on a
  /// device the package has no dispatch for, a web bundle off the web.
  /// Whether a run on a given device works is the model registry's record,
  /// on the website, not this.
  Set<PreferredBackend> get backendsHere;

  @override
  String toString() => '$runtimeType($id)';
}

/// A model `FlutterEdgeAi.installModel` installs: an LLM.
abstract base class InferenceVariant extends CatalogVariant {
  /// For subclasses.
  const InferenceVariant();

  /// The model type the installer is given.
  ModelType get modelType;

  /// The file type the installer is given.
  ModelFileType get fileType;

  /// The model file; null for a model the operating system provides
  /// ([ModelFileType.builtIn]).
  ModelArtifact? get file;

  /// What to open the model with: pass it as `defaults:` to
  /// `FlutterEdgeAi.openModel` or `getActiveModel`.
  ModelRuntimeDefaults get runtimeDefaults;

  /// The KV-cache length the file is compiled for, which bounds `maxTokens`
  /// on an NPU build; null when the context is free.
  /// [runtimeDefaults] carries the value the variant was run with.
  int? get requiredMaxTokens => null;

  /// Whether the variant takes images.
  bool get supportsImage => false;

  /// Whether the variant takes audio.
  bool get supportsAudio => false;

  /// Whether the variant does native function calling.
  bool get supportsFunctionCalls => false;

  /// Whether the variant has a thinking mode.
  bool get supportsThinking => false;

  @override
  List<ModelArtifact> get files => [?file];
}

/// A model `FlutterEdgeAi.installEmbedder` installs.
abstract base class EmbedderVariant extends CatalogVariant {
  /// For subclasses.
  const EmbedderVariant();

  /// The model file.
  ModelArtifact get model;

  /// The tokenizer file; null for a bundle that carries its own.
  ModelArtifact? get tokenizer;

  /// The profile a RAG index built with this variant is bound to. Fixed for
  /// the variant: vectors from another profile are not comparable.
  String get ragProfileId;

  /// The profile for image embeddings; null when the variant embeds no
  /// images.
  String? get imageRagProfileId => null;

  /// The vector dimension.
  int get dimension;

  /// The longest input in tokens.
  int get maxInputTokens;

  /// What the variant embeds.
  Set<EmbeddingModality> get modalities;

  /// The backend to open it on: [PreferredBackend.npu] for a build compiled
  /// for an NPU, null otherwise.
  PreferredBackend? get preferredBackend => null;

  @override
  List<ModelArtifact> get files => [model, ?tokenizer];
}

/// A model `FlutterEdgeAi.installStt` installs.
abstract base class SttVariant extends CatalogVariant {
  /// For subclasses.
  const SttVariant();

  /// The speech-to-text family.
  SttModelType get type;

  /// The model file.
  ModelArtifact get model;

  /// The tokenizer file.
  ModelArtifact get tokenizer;

  @override
  List<ModelArtifact> get files => [model, tokenizer];
}

/// A model `FlutterEdgeAi.installTts` installs: a bundle of files under one
/// base URL.
abstract base class TtsVariant extends CatalogVariant {
  /// For subclasses.
  const TtsVariant();

  /// The text-to-speech family; it decides which files the bundle holds.
  TtsModelType get type;

  /// The pinned URL the bundle's files are fetched under.
  String get baseUrl;
}

/// A list of models, as one package or `FlutterEdgeAi.catalog` offers them.
abstract base class ModelCatalog {
  /// For subclasses.
  const ModelCatalog();

  /// Who offers it: a package name, or `flutter_edge_ai` for the catalog of
  /// every registered package.
  String get name;

  /// The models, in the catalog's order.
  List<CatalogModel> get models;

  /// The model with [id], or null.
  CatalogModel? byId(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The variant with [id] (`<model id>/<slug>`), or null.
  CatalogVariant? variantById(String id) {
    final slash = id.indexOf('/');
    if (slash < 0) return null;
    for (final v in byId(id.substring(0, slash))?.variants ?? const []) {
      if (v.id == id) return v;
    }
    return null;
  }
}

/// A provider that ships a catalog of the models it runs. An engine or
/// backend passed to `FlutterEdgeAi.initialize` that implements this adds its
/// catalog to `FlutterEdgeAi.catalog`.
///
/// One getter, kept that way: a new capability is a new interface, so adding
/// it never breaks an implementer.
abstract interface class ModelCatalogSource {
  /// The models this provider runs.
  ModelCatalog get modelCatalog;
}
