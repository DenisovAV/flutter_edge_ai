import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';

/// Serializes [Filter] DSL into the JSON envelope consumed by
/// `QdrantEdgeClient.search`'s `_filterFromJson` adapter, which rebuilds it
/// into the official `qdrant_edge` SDK's typed `Filter`.
///
/// Output shape mirrors the qdrant `Filter` REST schema:
///
/// ```json
/// {
///   "must":     [{"key": "...", "match": {"value": ...}}, ...],
///   "should":   [...],
///   "must_not": [...]
/// }
/// ```
///
/// Each bucket is omitted entirely (not set to an empty array) when it
/// contains no conditions — matches the way the qdrant Rust deserializer
/// distinguishes "no constraint" from "match nothing".
///
/// Returns `null` for an [Filter.isEmpty] input, signalling to the caller
/// to use the no-filter codepath (`QdrantEdgeClient.search` with a null
/// `filterJson`) instead of passing an empty `{}` string.
class FilterCodec {
  const FilterCodec._();

  /// Throws [ArgumentError] when [name] cannot be a qdrant payload key.
  ///
  /// qdrant keys are free-form UTF-8, so there is exactly one rule: `.` is a
  /// nested-payload-path separator, which would make `doc.type` mean "field
  /// `type` inside `doc`" here and a flat column on vec0 — one declaration
  /// denoting two different things.
  ///
  /// Lives here, not in core: it is a fact about qdrant. Note the asymmetry is
  /// real — this store accepts names vec0 refuses, so a schema that works here
  /// may be rejected by `FilterToVec0.validateFieldName`. The portable set is
  /// vec0's, and core's FilterField dartdoc says so.
  static void validateFieldName(String name) {
    if (name.contains('.')) {
      throw ArgumentError.value(
        name,
        'FilterField.name',
        'qdrant reads "." as a nested payload-path separator, so this name '
            'would denote a different field here than on other stores',
      );
    }
  }

  /// Encodes [filter] to a compact JSON string. Returns null for empty filters
  /// AND for filters that, after dropping conditions on fields not declared in
  /// [schema], have nothing left (callers should then skip the filter-aware FFI
  /// entry point and run an unfiltered search).
  ///
  /// Conditions whose key is not in [schema] are SKIPPED — they were never
  /// promoted to a top-level payload key (see [QdrantVectorStore.addDocument]),
  /// so matching on them would silently narrow to zero. Skipping makes an
  /// undeclared key a no-op (same hits as `filter: null`), honoring the
  /// `VectorStoreRepository` contract and matching the sqlite-vec store.
  static String? encode(Filter? filter, FilterSchema schema) {
    if (filter == null || filter.isEmpty) return null;

    final map = <String, Object>{};
    var impossible = false;

    // A `must` bucket: everything must hold. A condition matching everything
    // adds nothing; one matching nothing sinks the whole filter.
    final must = <Map<String, Object>>[];
    for (final c in _declared(filter.must, schema)) {
      switch (_encodeCondition(c, schema)) {
        case _Ignored():
          break;
        case _MatchesAll():
          break;
        case _MatchesNone():
          impossible = true;
        case _Clause(:final json):
          must.add(json);
      }
    }
    if (must.isNotEmpty) map['must'] = must;

    // A `should` bucket: at least one must hold. This is where dropping a
    // no-op silently NARROWED the result — a condition that matches everything
    // makes the whole disjunction true, so the bucket must disappear, not lose
    // one arm. And if every arm matches nothing, the bucket is unsatisfiable.
    final shouldConditions = _declared(filter.should, schema);
    if (shouldConditions.isNotEmpty) {
      final should = <Map<String, Object>>[];
      var alwaysTrue = false;
      // Whether any arm was actually EVALUATED. An ignored arm is skipped as
      // if never written, so a bucket left empty because every arm was ignored
      // is a bucket that was never there — no constraint. A bucket left empty
      // because every arm matched nothing is an empty disjunction, which is
      // unsatisfiable. Without this flag both look like `should.isEmpty`, and
      // the ignored case wrongly sank the whole filter: `should:
      // [FieldRange(key: 'lang')]` over a string field returned zero rows
      // while the identical condition in `must` correctly returned everything.
      var sawEvaluated = false;
      for (final c in shouldConditions) {
        switch (_encodeCondition(c, schema)) {
          case _Ignored():
            break;
          case _MatchesAll():
            alwaysTrue = true;
            sawEvaluated = true;
          case _MatchesNone():
            sawEvaluated = true;
          case _Clause(:final json):
            sawEvaluated = true;
            should.add(json);
        }
      }
      if (!alwaysTrue) {
        if (should.isEmpty) {
          if (sawEvaluated) impossible = true;
        } else {
          map['should'] = should;
        }
      }
    }

    // A `must_not` bucket: qdrant's check is all(|c| !check(c)), so the two
    // degenerate cases swap places relative to `must`. Excluding something no
    // point matches excludes nothing; excluding something EVERY point matches
    // leaves nothing.
    final mustNot = <Map<String, Object>>[];
    for (final c in _declared(filter.mustNot, schema)) {
      switch (_encodeCondition(c, schema)) {
        case _Ignored():
          break;
        case _MatchesAll():
          impossible = true;
        case _MatchesNone():
          break;
        case _Clause(:final json):
          mustNot.add(json);
      }
    }
    if (mustNot.isNotEmpty) map['must_not'] = mustNot;

    if (impossible) {
      // An empty interval: `Range::check_range` is inclusive at both ends, so
      // `1 <= v <= 0` holds for no number, and a non-numeric payload fails the
      // range check outright. Encoded on a key we actually saw, so the shape
      // stays a well-formed condition rather than a special token.
      // A key from the SCHEMA, not from the filter. _anyKey read
      // `bucket.first.key`, which is often the condition that was dropped as
      // undeclared — and Condition.key is unvalidated, while a declared name
      // is constrained to FilterField.namePattern by construction. qdrant
      // parses this field as a JsonPath during deserialization, so a key with
      // a space or an unbalanced bracket fails to parse, the FFI call returns
      // non-zero, and searchSimilar THROWS — reopening the never-throws hole
      // this PR closed for non-finite numbers, through a different door.
      //
      // `impossible` can only be set from inside a loop over declared
      // conditions, so the schema is guaranteed non-empty here.
      final key = schema.fields.first.name;
      return jsonEncode({
        'must': [
          {
            'key': key,
            'range': {'gte': 1, 'lte': 0},
          },
        ],
      });
    }
    if (map.isEmpty) return null; // every condition was undeclared → no-op
    return jsonEncode(map);
  }

  static Iterable<Condition> _declared(
    List<Condition>? conditions,
    FilterSchema schema,
  ) => (conditions ?? const <Condition>[]).where(
    (c) => schema.fieldFor(c.key) != null,
  );

  static _Contribution _encodeCondition(Condition c, FilterSchema schema) {
    final field = schema.fieldFor(c.key)!;
    switch (c) {
      case FieldEquals(:final key, :final value):
        // A NUMBER is compared by value, not by JSON spelling — `4` and `4.0`
        // are the same number, and a store must not disagree with its sibling
        // about that. qdrant's `match` cannot express it: ValueVariants is an
        // untagged String | Integer | Bool with no float arm (types.rs), so a
        // double `value` fails deserialization outright, and an integer is
        // compared with `as_i64()`, which returns None for a payload of `4.0`
        // and quietly matches nothing. A degenerate range says the same thing
        // in a form qdrant compares numerically.
        // The bool check comes FIRST, and the order is load-bearing. With the
        // numeric branch ahead of it, `FieldEquals('archived', 1)` on a
        // bool-typed field took the degenerate-range path and never reached
        // _boolSpellings — so a document storing `true` was missed while one
        // storing `1` matched, and sqlite (which folds both to the integer 1)
        // returned both. FieldMatchAny already checks bool first, so the same
        // predicate written as a one-element set answered differently from
        // FieldEquals on the SAME backend.
        return _equality(field, key, value);

      case FieldMatchAny(:final key, :final values):
        // Same trap as FieldEquals above, and it was left here when that one
        // was fixed. AnyVariants is Strings(IndexSet<String>) |
        // Integers(IndexSet<i64>) — no float arm — and the checker compares
        // with `stored.as_i64()`. So `[2020]` misses a `2020.0` payload, and a
        // Dart double in the list fails deserialization outright, throwing out
        // of searchSimilar and breaking the never-throws guarantee.
        //
        // A nested `should` of degenerate ranges says "is one of" in a form
        // qdrant compares numerically. Condition::Filter(Filter) is a legal
        // member of the untagged enum, so this nests.
        // A string field with only string members is the one shape `match.any`
        // expresses exactly, and it is the common case — keep the compact form.
        if (field.type == FilterFieldType.string &&
            values.every((v) => v is String)) {
          // "is one of nothing" matches nothing — the same reading the sqlite
          // arm gives an empty set, and the reason its negation is a no-op.
          if (values.isEmpty) return const _MatchesNone();
          return _Clause({
            'key': key,
            'match': {'any': values},
          });
        }

        // Otherwise expand, so each member goes through the SAME per-type gate
        // as FieldEquals. Members that cannot inhabit the declared type are
        // dropped rather than encoded: nothing storable in that column can
        // equal them.
        final arms = <Map<String, Object>>[];
        for (final v in values) {
          switch (_equality(field, key, v)) {
            case _Clause(:final json):
              // A member whose own encoding is already a disjunction — a bool,
              // which has two legal JSON spellings — is SPLICED, not nested.
              // "is one of {x}" and "equals x" are the same predicate, so they
              // must produce the same JSON; nesting made them differ in shape
              // while agreeing in meaning, which is the sort of near-miss that
              // later reads as a real difference.
              final inner = json.length == 1 ? json['should'] : null;
              if (inner is List) {
                arms.addAll(inner.cast<Map<String, Object>>());
              } else {
                arms.add(json);
              }
            case _:
              break;
          }
        }
        if (arms.isEmpty) return const _MatchesNone();
        return _Clause({'should': arms});

      case FieldRange(:final key, :final gte, :final lte):
        // A range only means something over a numeric column. On a string or
        // bool field it is ignored — skipped in every bucket — which is what
        // the sqlite arm does and what core documents. Encoding it here made
        // the same filter answer oppositely on the two backends.
        if (field.type != FilterFieldType.number) return const _Ignored();
        // A range with neither bound constrains nothing, so it matches
        // everything — the same reading the SQLite arm applies. Emitting an
        // empty `range: {}` instead turns it into an existence test there,
        // which EXCLUDES every document whose value is not numeric: the same
        // filter then returns opposite sets on the two backends.
        if (gte == null && lte == null) return const _MatchesAll();
        // A non-finite bound cannot be satisfied by any JSON number, and
        // jsonEncode refuses to write it at all.
        if (!_isFinite(gte) || !_isFinite(lte)) return const _MatchesNone();
        final range = <String, Object>{};
        if (gte != null) range['gte'] = gte;
        if (lte != null) range['lte'] = lte;
        return _Clause({'key': key, 'range': range});
    }
  }

  /// One value compared against one DECLARED field, dispatching on the
  /// field's type rather than on the value's runtime type.
  ///
  /// That difference is the whole point. This used to branch on `value is num`
  /// / `value is bool`, and the write path stores the payload verbatim — so a
  /// value that cannot inhabit the declared type was still emitted as a real
  /// predicate, and could match a stored value that also did not fit. The
  /// sqlite arm gates BOTH directions through coerceForColumn, so it erased
  /// such a value on write and rendered the condition always-false on read.
  /// One filter, two answers:
  ///
  ///   schema `price: number`, document `{"price": "10"}`,
  ///   filter `FieldEquals('price', '10')`  ->  sqlite [], qdrant [d1]
  ///   schema `lang: string`, document `{"lang": 5}`,
  ///   filter `FieldEquals('lang', 5)`      ->  sqlite [], qdrant [d1]
  ///
  /// Gating on the declared type here fixes both, and fixes them for shards
  /// ALREADY WRITTEN — a write-side coercion could not, and would have made a
  /// single shard answer differently for old and new points.
  static _Contribution _equality(FilterField field, String key, Object? value) {
    switch (field.type) {
      case FilterFieldType.bool:
        // Only a real bool, or exactly 0/1 — the same values coerceForColumn
        // accepts on the sqlite side. `value == 1` alone was not that test: it
        // is false for 2, for 0.5, for -1, so every one of those became the
        // boolean FALSE and matched documents storing `false` or `0`, while
        // sqlite rendered the condition always-false and matched nothing.
        // A non-bool-ish value cannot inhabit this column, so nothing equals it.
        final asBool = switch (value) {
          bool b => b,
          num n when n == 0 || n == 1 => n == 1,
          _ => null,
        };
        if (asBool == null) return const _MatchesNone();
        return _Clause({'should': _boolSpellings(key, asBool)});

      case FilterFieldType.number:
        // Not a number in this column: nothing storable can equal it.
        if (value is! num) return const _MatchesNone();
        if (!_isFinite(value)) return const _MatchesNone();
        return _Clause({
          'key': key,
          'range': {'gte': value, 'lte': value},
        });

      case FilterFieldType.string:
        if (value is! String) return const _MatchesNone();
        return _Clause({
          'key': key,
          'match': {'value': value},
        });
    }
  }

  /// Both JSON spellings of a boolean, as a disjunction.
  ///
  /// qdrant stores the payload value verbatim, so `{"archived": true}` is
  /// Bool(true) and `{"archived": 1}` is Integer(1) — two variants of an
  /// untagged enum, and `match: {value: true}` matches only the first. The
  /// sqlite store folds both to the integer 1 in a BOOLEAN column, so the same
  /// filter over the same documents answered differently per backend.
  ///
  /// Accepting both spellings here is the query-side half of that fix, and it
  /// needs no migration of shards already written. Takes a real [bool]:
  /// deciding whether a value can BE a boolean belongs with the other per-type
  /// gates in [_equality], not buried in a formatter.
  static List<Map<String, Object>> _boolSpellings(String key, bool value) => [
    {
      'key': key,
      'match': {'value': value},
    },
    {
      'key': key,
      'range': {'gte': value ? 1 : 0, 'lte': value ? 1 : 0},
    },
  ];

  /// True for a value that is either absent or a number JSON can represent.
  ///
  /// NaN and ±Infinity have no JSON literal, so no stored payload holds one and
  /// no comparison against one can be satisfied. They also make `jsonEncode`
  /// throw (measured: JsonUnsupportedObjectError), which is how they used to
  /// leave `searchSimilar` — breaking the contract that a filter never throws.
  static bool _isFinite(num? value) =>
      value == null || value is! double || value.isFinite;
}

/// What one condition contributes to its bucket.
///
/// A single nullable clause used to stand for both "constrains nothing" and
/// "can never match". Those are opposites in a `should` bucket — dropping the
/// first narrows the result, when it should have made the whole disjunction
/// true — and they swap places again under `must_not`. Naming them apart is
/// what lets the bucket assembler treat each correctly.
sealed class _Contribution {
  const _Contribution();
}

class _MatchesAll extends _Contribution {
  const _MatchesAll();
}

/// Skipped as if never written — a contract choice, not a truth value.
///
/// Core's Condition dartdoc names three degenerate cases and this codec
/// implemented two, so a FieldRange on a declared string/bool field took the
/// _MatchesAll path: `mustNot: [FieldRange(key: 'tag')]` over a string field
/// returned every document on sqlite (which ignores it) and none on qdrant.
/// An ignored condition contributes nothing to ANY bucket, which is exactly
/// what neither of the other two variants means.
class _Ignored extends _Contribution {
  const _Ignored();
}

class _MatchesNone extends _Contribution {
  const _MatchesNone();
}

class _Clause extends _Contribution {
  const _Clause(this.json);
  final Map<String, Object> json;
}
