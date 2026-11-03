import 'dart:convert';

import 'package:flutter_edge_ai/src/interface.dart' show TurnEnd;

import 'response_format.dart';
import 'structured_output.dart';

/// What a structured turn that ended with [end] and produced [text] fails
/// with, or null when [text] is a value of [format].
///
/// Any end but [TurnEnd.endOfSequence] is incomplete, even when [text]
/// parses. A complete turn is trimmed, decoded with `jsonDecode` (which must
/// consume the whole text) and checked against the dialect's keywords; no
/// fence or prose is unwrapped.
StructuredOutputException? structuredReplyFailure(
  JsonSchemaResponseFormat format,
  String text,
  TurnEnd end,
) {
  if (end != TurnEnd.endOfSequence) {
    return IncompleteStructuredOutputException(
      'The turn ended before the reply was complete (${end.name}).',
      end: end,
      partialText: text,
    );
  }
  final Object? value;
  try {
    value = jsonDecode(text.trim());
  } on FormatException catch (e) {
    return NonConformingStructuredOutputException(
      'The reply is not one JSON value: ${e.message}. The engine accepted a '
      'format it did not enforce.',
      text: text,
    );
  }
  final violation = _violation(format.schema, value, '');
  if (violation == null) return null;
  return NonConformingStructuredOutputException(
    'The reply violates the schema: ${violation.problem}. The engine '
    'accepted a format it did not enforce.',
    text: text,
    schemaPath: violation.schemaPath,
  );
}

typedef _Violation = ({String schemaPath, String problem});

_Violation? _violation(
  Map<String, Object?> schema,
  Object? value,
  String path,
) {
  _Violation at(String keyword, String problem) =>
      (schemaPath: '$path/$keyword', problem: problem);

  final type = schema['type'];
  if (type is String && !_hasType(value, type)) {
    return at('type', 'expected $type, got ${jsonKindOf(value)}');
  }

  if (schema.containsKey('const') && !jsonValuesEqual(schema['const'], value)) {
    return at('const', 'not the constant value');
  }
  final allowed = schema['enum'];
  if (allowed is List && !allowed.any((e) => jsonValuesEqual(e, value))) {
    return at('enum', 'not one of the enumerated values');
  }

  switch (value) {
    case Map():
      final properties = schema['properties'];
      final declared = properties is Map<String, Object?>
          ? properties
          : const <String, Object?>{};
      final required = schema['required'];
      if (required is List) {
        for (final name in required) {
          if (!value.containsKey(name)) {
            return at('required', 'missing required property "$name"');
          }
        }
      }
      if (schema['additionalProperties'] == false) {
        for (final key in value.keys) {
          if (!declared.containsKey(key)) {
            return at(
              'additionalProperties',
              'property "$key" is not declared',
            );
          }
        }
      }
      for (final entry in declared.entries) {
        if (!value.containsKey(entry.key)) continue;
        final found = _violation(
          entry.value as Map<String, Object?>,
          value[entry.key],
          '$path/properties/${jsonPointerToken(entry.key)}',
        );
        if (found != null) return found;
      }
    case List():
      final min = schema['minItems'];
      if (min is num && value.length < min) {
        return at('minItems', '${value.length} items, fewer than $min');
      }
      final max = schema['maxItems'];
      if (max is num && value.length > max) {
        return at('maxItems', '${value.length} items, more than $max');
      }
      final items = schema['items'];
      if (items is Map<String, Object?>) {
        for (final item in value) {
          final found = _violation(items, item, '$path/items');
          if (found != null) return found;
        }
      }
    case String():
      final length = value.runes.length;
      final min = schema['minLength'];
      if (min is num && length < min) {
        return at('minLength', '$length code points, fewer than $min');
      }
      final max = schema['maxLength'];
      if (max is num && length > max) {
        return at('maxLength', '$length code points, more than $max');
      }
    case num():
      final min = schema['minimum'];
      if (min is num && value < min) {
        return at('minimum', '$value is below $min');
      }
      final max = schema['maximum'];
      if (max is num && value > max) {
        return at('maximum', '$value is above $max');
      }
  }
  return null;
}

bool _hasType(Object? value, String type) => switch (type) {
  'object' => value is Map,
  'array' => value is List,
  'string' => value is String,
  'integer' => isJsonInteger(value),
  'number' => value is num,
  'boolean' => value is bool,
  'null' => value == null,
  _ => false,
};
