// One option a decider can choose, and the import of Jev Choice questions.

import 'dart:convert' show jsonEncode;

import 'package:meta/meta.dart' show experimental, immutable;

import '../embedding/embedding_input.dart';

/// One option a decider can choose: an intent, an action, a screen, a tool, a
/// label, a route.
///
/// An embedding decider represents the option by the centroid of its inputs:
/// the [description] (when given) and every one of [examples], all embedded
/// with `TaskType.classification`. A description alone is zero-shot; a few
/// example requests per option (5–30 measured) are what make it accurate.
@experimental
@immutable
final class DeciderOption {
  /// Throws [ArgumentError] when [id] is empty or [description] is empty
  /// (leave it out instead).
  ///
  /// [examples] and [metadata] are copied. [metadata] is never embedded; it is
  /// carried for the app (a tool declaration, a route) and stored in the
  /// decider's artifact, so it must be JSON-encodable to export the decider.
  DeciderOption(
    this.id, {
    this.description,
    List<EmbeddingInput> examples = const [],
    Map<String, Object?>? metadata,
  }) : examples = List.unmodifiable(examples),
       metadata = metadata == null ? null : Map.unmodifiable(metadata) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (description != null && description!.isEmpty) {
      throw ArgumentError.value(
        description,
        'description',
        'must not be empty; leave it out instead',
      );
    }
  }

  /// Stable, unique within one decider. The answer's `choice`.
  final String id;

  /// What the option means, in words. Embedded as one more input of the
  /// option.
  final String? description;

  /// Requests that mean this option. Unmodifiable.
  final List<EmbeddingInput> examples;

  /// App data carried with the option and never embedded. Unmodifiable.
  final Map<String, Object?>? metadata;

  /// The options of a Jev Choice question (TypeSafe AI's wire format): one
  /// option per `criteria` entry, its key the id.
  ///
  /// [question] is one question object of a Jev request, e.g.
  /// `{"type": "choice", "instructions": "...", "criteria": {"returns":
  /// "Exchanges, wrong or damaged items", "billing": null}}`. A string
  /// criterion becomes the [description]; an object or array is
  /// JSON-encoded into it; `null` or an empty string uses the key itself as
  /// the description, as Jev reads the option name. `instructions` is not
  /// part of an option and is not used by an embedding decider.
  ///
  /// Choice questions only: throws [ArgumentError] for any other `type`
  /// (`noul`, `score`), and for a missing or empty `criteria` map.
  static List<DeciderOption> fromJevChoice(Map<String, Object?> question) {
    final type = question['type'];
    if (type != 'choice') {
      throw ArgumentError.value(
        type,
        'question.type',
        'only Jev Choice questions ("choice") become decider options',
      );
    }
    final criteria = question['criteria'];
    if (criteria is! Map || criteria.isEmpty) {
      throw ArgumentError.value(
        criteria,
        'question.criteria',
        'a Choice question needs a non-empty criteria map',
      );
    }
    return [
      for (final MapEntry(:key, :value) in criteria.entries)
        DeciderOption(
          '$key',
          description: switch (value) {
            null => '$key',
            final String text when text.isNotEmpty => text,
            final String _ => '$key',
            _ => jsonEncode(value),
          },
        ),
    ];
  }

  @override
  String toString() =>
      'DeciderOption($id, '
      '${description == null ? '' : 'description, '}'
      '${examples.length} examples)';
}
