import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart'
    show EmbeddingModality;

/// The three kinds of things the knowledge base holds, one RAG index each.
enum MultimodalRagKind {
  note(EmbeddingModality.text, 'Note', 'Notes'),
  photo(EmbeddingModality.image, 'Photo', 'Photos'),
  memo(EmbeddingModality.audio, 'Voice memo', 'Voice memos');

  const MultimodalRagKind(this.modality, this.label, this.plural);

  /// What its index stores: one modality per location.
  final EmbeddingModality modality;
  final String label;
  final String plural;
}

/// One thing in the knowledge base. Immutable; the library replaces an item
/// to change it.
sealed class MultimodalRagItem {
  const MultimodalRagItem({
    required this.id,
    required this.title,
    required this.seeded,
  });

  /// Its id in the library and in its index.
  final String id;
  final String title;

  /// A sample that ships with the app (not saved: it is always there).
  final bool seeded;

  MultimodalRagKind get kind;

  Map<String, Object?> toJson();

  /// Reads what [toJson] wrote; throws [FormatException] for anything else.
  static MultimodalRagItem fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    if (id is! String || title is! String) {
      throw FormatException('a knowledge item without an id or a title', json);
    }
    return switch (json['kind']) {
      'note' => NoteItem(
        id: id,
        title: title,
        body: json['body'] as String? ?? '',
      ),
      'photo' => PhotoItem(id: id, title: title, reference: _reference(json)),
      'memo' => MemoItem(
        id: id,
        title: title,
        reference: _reference(json),
        duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
      ),
      final kind => throw FormatException('unknown knowledge kind', kind),
    };
  }

  static String _reference(Map<String, Object?> json) => switch (json['ref']) {
    final String reference => reference,
    _ => throw FormatException('a media item without a reference', json),
  };
}

/// A markdown note. Its text is what the text index embeds.
final class NoteItem extends MultimodalRagItem {
  const NoteItem({
    required super.id,
    required super.title,
    required this.body,
    super.seeded = false,
  });

  final String body;

  /// What the model reads: the title, then the body.
  String get document => '$title\n$body';

  @override
  MultimodalRagKind get kind => MultimodalRagKind.note;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'note',
    'id': id,
    'title': title,
    'body': body,
  };
}

/// A photo. The image index embeds its pixels; [reference] points at the
/// original (an `asset:` key or a file the app kept).
final class PhotoItem extends MultimodalRagItem {
  const PhotoItem({
    required super.id,
    required super.title,
    required this.reference,
    super.seeded = false,
  });

  final String reference;

  @override
  MultimodalRagKind get kind => MultimodalRagKind.photo;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'photo',
    'id': id,
    'title': title,
    'ref': reference,
  };
}

/// A voice memo. The audio index embeds the sound itself — there is no
/// transcript: a memo is found by what is said in it, and a language model
/// that hears audio is given the recording.
final class MemoItem extends MultimodalRagItem {
  const MemoItem({
    required super.id,
    required super.title,
    required this.reference,
    required this.duration,
    super.seeded = false,
  });

  final String reference;
  final Duration duration;

  @override
  MultimodalRagKind get kind => MultimodalRagKind.memo;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'memo',
    'id': id,
    'title': title,
    'ref': reference,
    'durationMs': duration.inMilliseconds,
  };
}
