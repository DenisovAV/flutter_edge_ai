import 'dart:convert';

import '../image_search/photo_store.dart' show assetPhotoReference;
import 'multimodal_rag_item.dart';
import 'multimodal_rag_seed.dart';

/// The knowledge base's items — the samples, then what the user added — and
/// which of them are in the index of each embedding space.
///
/// Saved as JSON: the user's items whole (the samples ship with the app), and
/// what embedding each item cost per embedding space ([indexedIn], keyed by
/// the text profile id), so a model switch never shows another space's items
/// as indexed.
final class MultimodalRagLibrary {
  MultimodalRagLibrary._(this._items, this._indexed);

  /// The samples alone.
  factory MultimodalRagLibrary.seeded() =>
      MultimodalRagLibrary._(_seedItems(), {});

  /// The samples plus what [json] saved. A corrupt save is reported, not
  /// dropped: [FormatException].
  factory MultimodalRagLibrary.decode(String? json) {
    final library = MultimodalRagLibrary.seeded();
    if (json == null || json.isEmpty) return library;
    final saved = jsonDecode(json);
    if (saved is! Map<String, Object?>) {
      throw const FormatException(
        'the saved knowledge library is not an object',
      );
    }
    for (final json in (saved['items'] as List?) ?? const []) {
      library._items.add(
        MultimodalRagItem.fromJson((json as Map).cast<String, Object?>()),
      );
    }
    final indexed = (saved['indexed'] as Map?) ?? const {};
    for (final MapEntry(key: space, value: costs) in indexed.entries) {
      library._indexed[space as String] = {
        for (final MapEntry(key: id, value: us) in (costs as Map).entries)
          id as String: Duration(microseconds: us as int),
      };
    }
    return library;
  }

  final List<MultimodalRagItem> _items;
  final Map<String, Map<String, Duration>> _indexed;

  List<MultimodalRagItem> get items => List.unmodifiable(_items);

  MultimodalRagItem? byId(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// What embedding each item cost in [space], for the items in its index.
  Map<String, Duration> indexedIn(String space) =>
      Map.unmodifiable(_indexed[space] ?? const {});

  void add(MultimodalRagItem item) {
    if (byId(item.id) != null) {
      throw StateError('the library already holds ${item.id}');
    }
    _items.add(item);
  }

  void markIndexed(String space, String id, Duration embed) =>
      (_indexed[space] ??= {})[id] = embed;

  /// Forgets what is indexed in [space] — of [kind] only, when given.
  void forgetIndexed(String space, {MultimodalRagKind? kind}) {
    final costs = _indexed[space];
    if (costs == null) return;
    if (kind == null) {
      costs.clear();
    } else {
      costs.removeWhere((id, _) => byId(id)?.kind == kind);
    }
  }

  String encode() => jsonEncode({
    'version': 2,
    'items': [
      for (final item in _items)
        if (!item.seeded) item.toJson(),
    ],
    'indexed': {
      for (final MapEntry(key: space, value: costs) in _indexed.entries)
        space: {
          for (final MapEntry(key: id, value: embed) in costs.entries)
            id: embed.inMicroseconds,
        },
    },
  });
}

List<MultimodalRagItem> _seedItems() => [
  for (final note in kSeedNotes)
    NoteItem(id: note.id, title: note.title, body: note.body, seeded: true),
  for (final photo in kSeedPhotos)
    PhotoItem(
      id: photo.id,
      title: photo.title,
      reference: assetPhotoReference(photo.asset),
      seeded: true,
    ),
  for (final memo in kSeedMemos)
    MemoItem(
      id: memo.id,
      title: memo.title,
      // The same `asset:` reference format as a photo's.
      reference: assetPhotoReference(memo.asset),
      duration: memo.duration,
      seeded: true,
    ),
];
