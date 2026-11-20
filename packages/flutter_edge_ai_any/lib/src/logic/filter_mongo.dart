// rag's Filter as an any-store (Mongo-style) query over the normalised
// `f.<field key>` values of a row, with the semantics of
// flutter_edge_ai_sqlite's FilterToVec0 (the cross-backend parity table):
//
//   * a condition on an undeclared key is ignored, in every bucket;
//   * a FieldRange on a non-number field is ignored;
//   * an unbounded FieldRange on a number field is true of every document;
//   * a value that cannot inhabit the field's type, an empty set and a
//     non-finite bound match nothing;
//   * a document without the field never satisfies a condition, so `must`
//     excludes it and `mustNot` keeps it;
//   * bool fields accept true/false and the numbers 0/1; number fields
//     compare by value (50 == 50.0).
//
// The write half is [normaliseFields]: only a present, coercible value is
// stored, so "absent" is a missing path, which no comparison matches and
// $nor therefore keeps. No sentinel values, unlike vec0.
import 'dart:convert';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import 'formats.dart';

/// The field key (`<f>`) of a declared field.
String fieldKeyOf(FilterField f) => fieldLeafKey(f.name, f.type.name);

/// The value a field of [type] stores for [value], or null when it has
/// none (the field is then absent from the row).
Object? coerceField(Object? value, FilterFieldType type) => switch (type) {
  FilterFieldType.string => value is String ? value : null,
  FilterFieldType.number =>
    value is num && value.isFinite ? value.toDouble() : null,
  FilterFieldType.bool =>
    value is bool
        ? value
        : (value is num && (value == 0 || value == 1) ? value == 1 : null),
};

/// A row's `f` object: every declared field [metadata] carries a coercible
/// value for, keyed by its field key.
Map<String, Object?> normaliseFields(String? metadata, FilterSchema schema) =>
    normaliseFieldsCounted(metadata, schema).f;

/// [normaliseFields], and how many values it dropped: a declared field
/// present with a value of another type, or metadata that is not a JSON
/// object (counted once). A dropped value never matches a filter.
({Map<String, Object?> f, int dropped}) normaliseFieldsCounted(
  String? metadata,
  FilterSchema schema,
) {
  if (schema.isEmpty || metadata == null || metadata.isEmpty) {
    return (f: const {}, dropped: 0);
  }
  Object? decoded;
  try {
    decoded = jsonDecode(metadata);
  } on FormatException {
    return (f: const {}, dropped: 1);
  }
  if (decoded is! Map) return (f: const {}, dropped: 1);
  final out = <String, Object?>{};
  var dropped = 0;
  for (final field in schema.fields) {
    final raw = decoded[field.name];
    final v = coerceField(raw, field.type);
    if (v != null) {
      out[fieldKeyOf(field)] = v;
    } else if (raw != null) {
      dropped++;
    }
  }
  return (f: out, dropped: dropped);
}

/// The translated filter: null [query] with [matchesNothing] false means
/// "no constraint".
typedef MongoFilter = ({Map<String, Object?>? query, bool matchesNothing});

const MongoFilter _none = (query: null, matchesNothing: false);
const MongoFilter _nothing = (query: null, matchesNothing: true);

/// One condition's meaning: ignored, always true, always false, or a query.
sealed class _Cond {
  const _Cond();
}

final class _Ignored extends _Cond {
  const _Ignored();
}

final class _True extends _Cond {
  const _True();
}

final class _False extends _Cond {
  const _False();
}

final class _Query extends _Cond {
  const _Query(this.query);
  final Map<String, Object?> query;
}

_Cond _condition(Condition c, FilterSchema schema) {
  final field = schema.fieldFor(c.key);
  if (field == null) return const _Ignored();
  final path = 'f.${fieldKeyOf(field)}';
  switch (c) {
    case FieldEquals(:final value):
      final v = coerceField(value, field.type);
      if (v == null) return const _False();
      return _Query({
        path: {r'$eq': v},
      });
    case FieldRange(:final gte, :final lte):
      if (field.type != FilterFieldType.number) return const _Ignored();
      if ((gte != null && !gte.isFinite) || (lte != null && !lte.isFinite)) {
        return const _False();
      }
      if (gte == null && lte == null) return const _True();
      return _Query({
        path: {r'$gte': ?gte, r'$lte': ?lte},
      });
    case FieldMatchAny(:final values):
      final set = <Object>[];
      for (final value in values) {
        final v = coerceField(value, field.type);
        if (v != null && !set.contains(v)) set.add(v);
      }
      if (set.isEmpty) return const _False();
      return _Query({
        path: {r'$in': set},
      });
  }
}

/// Translates [filter] against [schema].
MongoFilter translateFilter(Filter? filter, FilterSchema schema) {
  if (filter == null || filter.isEmpty) return _none;
  final parts = <Map<String, Object?>>[];

  for (final c in filter.must ?? const <Condition>[]) {
    switch (_condition(c, schema)) {
      case _Ignored() || _True():
        break;
      case _False():
        return _nothing;
      case _Query(:final query):
        parts.add(query);
    }
  }

  final should = <Map<String, Object?>>[];
  var shouldEvaluated = false;
  var shouldTrue = false;
  for (final c in filter.should ?? const <Condition>[]) {
    switch (_condition(c, schema)) {
      case _Ignored():
        break;
      case _True():
        shouldEvaluated = true;
        shouldTrue = true;
      case _False():
        shouldEvaluated = true;
      case _Query(:final query):
        shouldEvaluated = true;
        should.add(query);
    }
  }
  if (shouldEvaluated && !shouldTrue) {
    if (should.isEmpty) return _nothing;
    parts.add(should.length == 1 ? should.single : {r'$or': should});
  }

  final not = <Map<String, Object?>>[];
  for (final c in filter.mustNot ?? const <Condition>[]) {
    switch (_condition(c, schema)) {
      case _Ignored() || _False():
        break;
      case _True():
        return _nothing;
      case _Query(:final query):
        not.add(query);
    }
  }
  if (not.isNotEmpty) parts.add({r'$nor': not});

  if (parts.isEmpty) return _none;
  return (
    query: parts.length == 1 ? parts.single : {r'$and': parts},
    matchesNothing: false,
  );
}
