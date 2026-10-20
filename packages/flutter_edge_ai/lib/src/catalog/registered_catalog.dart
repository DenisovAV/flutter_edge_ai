import 'package:flutter_edge_ai/src/catalog/model_catalog.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';

/// The catalogs of [providers] that implement [ModelCatalogSource], as one:
/// what `FlutterEdgeAi.catalog` returns.
///
/// A catalog reached through two providers counts once. A model id offered by
/// several catalogs is one model whose variants are concatenated in provider
/// order, so the first registered provider's variants come first; its
/// display data comes from the first catalog that lists it.
final class RegisteredCatalog extends ModelCatalog {
  /// The catalog of [providers], in the order they were registered.
  RegisteredCatalog(Iterable<Object> providers) : models = _merge(providers);

  @override
  String get name => 'flutter_edge_ai';

  @override
  final List<CatalogModel> models;

  static List<CatalogModel> _merge(Iterable<Object> providers) {
    final catalogs = <ModelCatalog>[];
    for (final provider in providers) {
      if (provider case final ModelCatalogSource source) {
        final catalog = source.modelCatalog;
        if (!catalogs.any((c) => identical(c, catalog))) catalogs.add(catalog);
      }
    }
    final byId = <String, List<CatalogModel>>{};
    for (final catalog in catalogs) {
      for (final model in catalog.models) {
        (byId[model.id] ??= []).add(model);
      }
    }
    return List.unmodifiable([
      for (final parts in byId.values)
        parts.length == 1 ? parts.single : _MergedModel(parts),
    ]);
  }
}

/// A model several catalogs offer.
final class _MergedModel extends CatalogModel {
  _MergedModel(this._parts)
    : variants = List.unmodifiable(_variantsOf(_parts)) {
    final first = _parts.first;
    for (final other in _parts.skip(1)) {
      if (other.displayName != first.displayName ||
          other.license != first.license) {
        edgeAiLog(
          '[flutter_edge_ai] catalog: ${first.id} differs between catalogs '
          '("${first.displayName}", ${first.license} vs '
          '"${other.displayName}", ${other.license}); the first is shown.',
        );
      }
    }
  }

  final List<CatalogModel> _parts;

  static List<CatalogVariant> _variantsOf(List<CatalogModel> parts) {
    final seen = <String>{};
    return [
      for (final part in parts)
        for (final v in part.variants)
          if (seen.add(v.id)) v,
    ];
  }

  @override
  final List<CatalogVariant> variants;

  @override
  String get id => _parts.first.id;

  @override
  String get displayName => _parts.first.displayName;

  @override
  String get family => _parts.first.family;

  @override
  String get archClass => _parts.first.archClass;

  @override
  double? get parametersB => _parts.first.parametersB;

  @override
  String get license => _parts.first.license;

  @override
  String get licenseUrl => _parts.first.licenseUrl;
}
