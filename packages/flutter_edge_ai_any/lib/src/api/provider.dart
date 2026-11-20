part of 'any_sync.dart';

/// The flutter_edge_ai_rag provider of any-sync locations
/// (`VectorStoreSpec.location` = [AnySyncLocation.value]).
///
/// ```dart
/// final rag = FlutterEdgeAiRag(providers: [AnyVectorStoreProvider(account)]);
/// final index = await rag.open(
///   spec: VectorStoreSpec(
///     providerId: AnyVectorStoreProvider.providerId,
///     location: AnySyncLocation(spaceId: space.id, indexName: 'notes').value,
///   ),
///   embedder: embedder,
/// );
/// ```
@experimental
final class AnyVectorStoreProvider implements VectorStoreProvider {
  AnyVectorStoreProvider(this._account, {this.priority = 0});

  static const providerId = 'any';

  final AnySyncAccount _account;

  @override
  final int priority;

  @override
  String get id => providerId;

  @override
  String get name => 'any-sync';

  /// The provider id only; the location is parsed in [createStore]. False on
  /// the web.
  @override
  bool canHandle(VectorStoreSpec spec) =>
      spec.providerId == providerId && _account._native.supported;

  /// Throws [ArgumentError] for a location that is not the canonical
  /// `any:<spaceId>/<indexName>`, and for `allowLegacyProfileAdoption`: an
  /// any-sync location has no legacy vectors to adopt.
  @override
  Future<VectorStoreRepository> createStore(VectorStoreSpec spec) async {
    if (!canHandle(spec)) {
      throw UnsupportedError(
        'AnyVectorStoreProvider cannot handle providerId "${spec.providerId}" '
        'here.',
      );
    }
    final AnySyncLocation location;
    try {
      location = AnySyncLocation.parse(spec.location);
    } on FormatException catch (e) {
      throw ArgumentError.value(spec.location, 'location', e.message);
    }
    if (spec.allowLegacyProfileAdoption) {
      throw ArgumentError.value(
        true,
        'allowLegacyProfileAdoption',
        'an any-sync location has no legacy vectors',
      );
    }
    return _AnyVectorStore(
      _account,
      location,
      enableText: spec.enableTextSearch,
    );
  }
}
