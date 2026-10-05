import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_rag_qdrant/src/filter_codec.dart';

Map<String, dynamic> _decode(String? json) {
  expect(json, isNotNull);
  return jsonDecode(json!) as Map<String, dynamic>;
}

/// Schema declaring every field the tests filter on. Conditions on a field NOT
/// in the schema are skipped (no-op), so all happy-path tests declare theirs.
final _schema = FilterSchema(
  fields: [
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'tag', type: FilterFieldType.string),
    FilterField(name: 'price', type: FilterFieldType.number),
    FilterField(name: 'archived', type: FilterFieldType.bool),
    // Not 'k': that is a reserved vec0 hidden column (FilterField
    // .reservedNames). qdrant accepts it, which is precisely why the name
    // has to be rejected in core -- one schema must not work on one backend
    // and fail on the other.
    FilterField(name: 'rank', type: FilterFieldType.number),
  ],
);

void main() {
  _crossBackendParityTests();

  group('degenerate conditions keep their bucket\'s meaning', () {
    // A single nullable clause used to mean both "constrains nothing" and
    // "can never match". Those are opposites in a `should` bucket, and they
    // swap places again under `must_not`, so each bucket needs its own answer.

    test('a no-op condition in should does not NARROW the disjunction', () {
      // An unbounded range constrains nothing, so `A OR <nothing> ` is true of
      // everything and the whole bucket must disappear. Dropping just that arm
      // left `should: [A]`, which is strictly narrower than no filter at all —
      // the condition that was supposed to be ignored changed the answer.
      final out = FilterCodec.encode(
        const Filter(
          should: [
            FieldEquals(key: 'lang', value: 'en'),
            FieldRange(key: 'price'),
          ],
        ),
        _schema,
      );
      expect(out, isNull, reason: 'no bucket survives, so no filter is sent');
    });

    test('a no-op condition in mustNot excludes EVERYTHING', () {
      // must_not is all(|c| !check(c)): excluding a condition every point
      // satisfies leaves no point. Treating it as a no-op returned the
      // unfiltered top-k instead.
      final out = _decode(
        FilterCodec.encode(
          const Filter(mustNot: [FieldRange(key: 'price')]),
          _schema,
        ),
      );
      final must = out['must'] as List;
      expect(must, hasLength(1));
      expect((must.first as Map)['range'], {'gte': 1, 'lte': 0});
    });

    test(
      'a should bucket whose every arm matches nothing is unsatisfiable',
      () {
        final out = _decode(
          FilterCodec.encode(
            const Filter(
              should: [FieldMatchAny(key: 'tag', values: [])],
            ),
            _schema,
          ),
        );
        expect((out['must'] as List).first['range'], {'gte': 1, 'lte': 0});
      },
    );

    test('a match-none condition in mustNot excludes nothing', () {
      // The mirror image: excluding what no point matches is no constraint.
      expect(
        FilterCodec.encode(
          const Filter(
            mustNot: [FieldMatchAny(key: 'tag', values: [])],
          ),
          _schema,
        ),
        isNull,
      );
    });
  });

  group('a range on a non-numeric field is ignored, not always-true', () {
    // Core names three degenerate cases; this codec implemented two, so an
    // ignored condition took the matches-everything path. Those differ in
    // exactly the buckets this algebra exists for.
    test('mustNot: an ignored range excludes nothing', () {
      // Was: _MatchesAll -> "excluding what everything satisfies" -> the whole
      // filter unsatisfiable. sqlite returned every document for this filter.
      expect(
        FilterCodec.encode(
          const Filter(mustNot: [FieldRange(key: 'lang')]),
          _schema,
        ),
        isNull,
        reason: 'ignored in every bucket, so no filter is sent',
      );
    });

    test('should: an ignored range does not make the bucket always-true', () {
      final out = _decode(
        FilterCodec.encode(
          const Filter(
            should: [
              FieldRange(key: 'lang'),
              FieldEquals(key: 'lang', value: 'en'),
            ],
          ),
          _schema,
        ),
      );
      final should = out['should'] as List;
      expect(should, hasLength(1));
      expect((should.first as Map)['match'], {'value': 'en'});
    });

    test('must: a bounded range on a string field is ignored', () {
      expect(
        FilterCodec.encode(
          const Filter(must: [FieldRange(key: 'lang', gte: 1)]),
          _schema,
        ),
        isNull,
      );
    });
  });

  group('a value that cannot inhabit the declared type matches nothing', () {
    // The codec branched on the VALUE's runtime type while the write path
    // stores the payload verbatim, so an off-type value still became a real
    // predicate and could match an equally off-type stored value. sqlite gates
    // both directions through coerceForColumn, so it answered []. One filter,
    // two answers — the class this PR exists to remove.
    test('a String against a number field', () {
      expect(
        FilterCodec.encode(
          const Filter(
            must: [FieldEquals(key: 'price', value: '10')],
          ),
          _schema,
        ),
        isNotNull,
      );
      final out = _decode(
        FilterCodec.encode(
          const Filter(
            must: [FieldEquals(key: 'price', value: '10')],
          ),
          _schema,
        ),
      );
      expect(
        (out['must'] as List).first['range'],
        {'gte': 1, 'lte': 0},
        reason: 'unsatisfiable, not a literal string match',
      );
    });

    test('a num against a string field', () {
      final out = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldEquals(key: 'lang', value: 5)]),
          _schema,
        ),
      );
      expect((out['must'] as List).first['range'], {'gte': 1, 'lte': 0});
    });

    test('off-type members of a match-any set are dropped, not matched', () {
      final out = _decode(
        FilterCodec.encode(
          const Filter(
            must: [
              FieldMatchAny(key: 'price', values: ['10', 20]),
            ],
          ),
          _schema,
        ),
      );
      final arms = (out['must'] as List).first['should'] as List;
      expect(arms, hasLength(1), reason: "'10' cannot be a number here");
      expect(arms.first['range'], {'gte': 20, 'lte': 20});
    });

    test('a string set on a string field keeps the compact match.any', () {
      // The common case must not pay for the gate above.
      final out = _decode(
        FilterCodec.encode(
          const Filter(
            must: [
              FieldMatchAny(key: 'tag', values: ['a', 'b']),
            ],
          ),
          _schema,
        ),
      );
      expect((out['must'] as List).first['match'], {
        'any': ['a', 'b'],
      });
    });
  });

  group('a bool field accepts only what coerceForColumn accepts', () {
    // `value == 1` is not the test for "can this be a boolean": it is false
    // for 2, for 0.5, for -1, so each of those became the boolean FALSE and
    // matched documents storing `false` or `0`. sqlite accepts only 0 and 1
    // and rendered the condition always-false, so the same filter returned
    // different rows per backend.
    for (final v in [2, 0.5, -1, 7]) {
      test('$v is not a boolean, so it matches nothing', () {
        final out = _decode(
          FilterCodec.encode(
            Filter(
              must: [FieldEquals(key: 'archived', value: v)],
            ),
            _schema,
          ),
        );
        expect((out['must'] as List).first['range'], {'gte': 1, 'lte': 0});
      });
    }

    test('a non-bool-ish string on a bool field matches nothing', () {
      final out = _decode(
        FilterCodec.encode(
          const Filter(
            must: [FieldEquals(key: 'archived', value: 'yes')],
          ),
          _schema,
        ),
      );
      expect((out['must'] as List).first['range'], {'gte': 1, 'lte': 0});
    });

    test('0 and 1 still work, in both spellings', () {
      for (final v in [0, 1, true, false]) {
        final out = _decode(
          FilterCodec.encode(
            Filter(
              must: [FieldEquals(key: 'archived', value: v)],
            ),
            _schema,
          ),
        );
        final arms = (out['must'] as List).first['should'] as List;
        expect(arms, hasLength(2), reason: '$v must keep both spellings');
      }
    });

    test('a bool member of a set does not become a nested disjunction', () {
      // "is one of {x}" and "equals x" are the same predicate and must produce
      // the same JSON — the arms are spliced, not nested.
      final eq = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldEquals(key: 'archived', value: true)]),
          _schema,
        ),
      );
      final any = _decode(
        FilterCodec.encode(
          const Filter(
            must: [
              FieldMatchAny(key: 'archived', values: [true]),
            ],
          ),
          _schema,
        ),
      );
      expect(eq['must'], any['must']);
    });

    test('a non-scalar member of a set is dropped, not emitted', () {
      // AnyVariants is Strings|Integers. A bool in the list used to reach
      // match.any, and qdrant's Filter is deny_unknown_fields, so the WHOLE
      // filter failed to deserialize and searchSimilar threw.
      final out = _decode(
        FilterCodec.encode(
          const Filter(
            must: [
              FieldMatchAny(key: 'lang', values: ['a', true]),
            ],
          ),
          _schema,
        ),
      );
      final arms = (out['must'] as List).first['should'] as List;
      expect(arms, hasLength(1));
      expect(arms.first['match'], {'value': 'a'});
    });
  });

  group('an all-ignored bucket is absent, not empty', () {
    // "Ignored" and "matches nothing" both leave a bucket with no arms, and
    // the code told them apart by asking whether any arm was DECLARED — which
    // an ignored one is. So a should bucket holding only ignored arms was read
    // as an empty disjunction and sank the whole filter.

    test('a should bucket of only ignored arms constrains nothing', () {
      // The contrast that makes it plainly wrong: the identical condition in
      // `must` correctly yields no filter at all.
      expect(
        FilterCodec.encode(
          const Filter(should: [FieldRange(key: 'lang', gte: 1)]),
          _schema,
        ),
        isNull,
      );
      expect(
        FilterCodec.encode(
          const Filter(must: [FieldRange(key: 'lang', gte: 1)]),
          _schema,
        ),
        isNull,
      );
    });

    test('a should bucket of only match-nothing arms IS unsatisfiable', () {
      // The other half of the distinction — this one must still sink it.
      final out = _decode(
        FilterCodec.encode(
          const Filter(
            should: [FieldMatchAny(key: 'tag', values: [])],
          ),
          _schema,
        ),
      );
      expect((out['must'] as List).first['range'], {'gte': 1, 'lte': 0});
    });

    test('the unsatisfiable sentinel uses a DECLARED key', () {
      // It used to take the first key off the raw filter — often the one just
      // dropped as undeclared, and Condition.key is unvalidated. qdrant parses
      // that field as a JsonPath, so a key with a space fails to deserialize
      // and searchSimilar throws, reopening the never-throws hole.
      final out = _decode(
        FilterCodec.encode(
          const Filter(
            must: [
              FieldEquals(key: 'not a key!', value: 'x'),
              FieldMatchAny(key: 'tag', values: []),
            ],
          ),
          _schema,
        ),
      );
      final key = (out['must'] as List).first['key'] as String;
      expect(key, isNotEmpty);
      expect(
        RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(key),
        isTrue,
        reason: 'must be a schema-declared name, not user text',
      );
    });
  });

  group('a bool field answers the same however the predicate is spelled', () {
    // FieldEquals checked `value is num` before the field type, so a numeric
    // value on a bool field took the degenerate-range path and never reached
    // _boolSpellings. FieldMatchAny checked the type first. The same predicate,
    // written two ways, answered differently on the SAME backend.
    test('FieldEquals(1) on a bool field accepts true and 1', () {
      final out = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldEquals(key: 'archived', value: 1)]),
          _schema,
        ),
      );
      final arms = (out['must'] as List).first['should'] as List;
      expect(arms.first['match'], {'value': true});
      expect(arms.last['range'], {'gte': 1, 'lte': 1});
    });

    test('FieldEquals(1) and FieldMatchAny([1]) agree', () {
      final eq = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldEquals(key: 'archived', value: 1)]),
          _schema,
        ),
      );
      final any = _decode(
        FilterCodec.encode(
          const Filter(
            must: [
              FieldMatchAny(key: 'archived', values: [1]),
            ],
          ),
          _schema,
        ),
      );
      expect(eq['must'], any['must']);
    });
  });

  group('non-finite numbers match nothing instead of throwing', () {
    // jsonEncode refuses NaN and ±Infinity outright (measured:
    // JsonUnsupportedObjectError), so these used to throw out of
    // searchSimilar and break the contract that a filter never throws.
    // No JSON payload can hold one, so the honest answer is "matches nothing".
    for (final v in [double.nan, double.infinity, double.negativeInfinity]) {
      test('FieldEquals($v) is unsatisfiable, not an exception', () {
        final out = _decode(
          FilterCodec.encode(
            Filter(
              must: [FieldEquals(key: 'price', value: v)],
            ),
            _schema,
          ),
        );
        expect((out['must'] as List).first['range'], {'gte': 1, 'lte': 0});
      });
    }

    test('a non-finite member of match-any is dropped, the rest survive', () {
      final out = _decode(
        FilterCodec.encode(
          Filter(
            must: [
              FieldMatchAny(key: 'price', values: [4, double.nan, 9]),
            ],
          ),
          _schema,
        ),
      );
      final arms = (out['must'] as List).first['should'] as List;
      expect(arms, hasLength(2), reason: 'NaN adds nothing to a disjunction');
      expect(arms.first['range'], {'gte': 4, 'lte': 4});
      expect(arms.last['range'], {'gte': 9, 'lte': 9});
    });

    test('FieldRange asserts a non-finite bound in debug', () {
      // FieldRange carries an assert the other two conditions do not — an
      // early warning at the call site, not a different semantic. Asserts
      // vanish in release, so the codec above still has to answer correctly
      // there; this pins the dev-time half so the two do not drift apart.
      expect(
        () => FieldRange(key: 'price', gte: double.nan),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('a bool field matches both JSON spellings', () {
    // qdrant keeps the payload value verbatim, so {"archived": 1} is
    // Integer(1) and {"archived": true} is Bool(true) — different variants of
    // an untagged enum. The sqlite store folds both into the integer 1, so the
    // same filter over the same documents answered differently per backend.
    test('FieldEquals(true) accepts true and 1', () {
      final out = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldEquals(key: 'archived', value: true)]),
          _schema,
        ),
      );
      final arms = (out['must'] as List).first['should'] as List;
      expect(arms.first['match'], {'value': true});
      expect(arms.last['range'], {'gte': 1, 'lte': 1});
    });

    test('FieldEquals(false) accepts false and 0', () {
      final out = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldEquals(key: 'archived', value: false)]),
          _schema,
        ),
      );
      final arms = (out['must'] as List).first['should'] as List;
      expect(arms.first['match'], {'value': false});
      expect(arms.last['range'], {'gte': 0, 'lte': 0});
    });
  });

  group('FilterCodec.encode', () {
    test('null filter → null output', () {
      expect(FilterCodec.encode(null, _schema), isNull);
    });

    test('empty filter → null output (skips the FFI filter branch)', () {
      expect(FilterCodec.encode(const Filter(), _schema), isNull);
    });

    test('undeclared key → null output (no-op, same hits as filter:null)', () {
      // Mirrors the sqlite-vec store: a condition on a field not in the schema
      // is skipped rather than narrowing the search to zero.
      expect(
        FilterCodec.encode(
          const Filter(
            must: [FieldEquals(key: 'not_declared', value: 'x')],
          ),
          _schema,
        ),
        isNull,
      );
    });

    test('declared + undeclared in one bucket → only declared survives', () {
      final json = _decode(
        FilterCodec.encode(
          const Filter(
            must: [
              FieldEquals(key: 'lang', value: 'en'),
              FieldEquals(key: 'not_declared', value: 'x'),
            ],
          ),
          _schema,
        ),
      );
      expect(json['must'], hasLength(1));
      expect(json['must'][0]['key'], 'lang');
    });

    test('FieldEquals encodes to match.value', () {
      final json = _decode(
        FilterCodec.encode(
          const Filter(
            must: [FieldEquals(key: 'lang', value: 'en')],
          ),
          _schema,
        ),
      );
      expect(json, {
        'must': [
          {
            'key': 'lang',
            'match': {'value': 'en'},
          },
        ],
      });
    });

    test('FieldMatchAny encodes to match.any', () {
      final json = _decode(
        FilterCodec.encode(
          const Filter(
            should: [
              FieldMatchAny(key: 'tag', values: ['a', 'b', 'c']),
            ],
          ),
          _schema,
        ),
      );
      expect(json, {
        'should': [
          {
            'key': 'tag',
            'match': {
              'any': ['a', 'b', 'c'],
            },
          },
        ],
      });
    });

    test('FieldRange encodes to range with optional gte/lte', () {
      final both = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldRange(key: 'price', gte: 10.0, lte: 100.0)]),
          _schema,
        ),
      );
      expect(both['must'][0]['range'], {'gte': 10.0, 'lte': 100.0});

      final gteOnly = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldRange(key: 'price', gte: 10.0)]),
          _schema,
        ),
      );
      expect(gteOnly['must'][0]['range'], {'gte': 10.0});
      expect(gteOnly['must'][0]['range'].containsKey('lte'), isFalse);

      final lteOnly = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldRange(key: 'price', lte: 100.0)]),
          _schema,
        ),
      );
      expect(lteOnly['must'][0]['range'], {'lte': 100.0});
      expect(lteOnly['must'][0]['range'].containsKey('gte'), isFalse);
    });

    test('mustNot serializes to snake_case must_not (qdrant wire format)', () {
      final json = _decode(
        FilterCodec.encode(
          const Filter(mustNot: [FieldEquals(key: 'archived', value: true)]),
          _schema,
        ),
      );
      expect(json.keys, contains('must_not'));
      expect(json.keys, isNot(contains('mustNot')));
    });

    test('combined must + mustNot serializes all buckets', () {
      final json = _decode(
        FilterCodec.encode(
          const Filter(
            must: [
              FieldEquals(key: 'lang', value: 'en'),
              FieldRange(key: 'price', gte: 50.0),
            ],
            mustNot: [FieldEquals(key: 'archived', value: true)],
          ),
          _schema,
        ),
      );
      expect(json['must'], hasLength(2));
      expect(json['must_not'], hasLength(1));
      expect(
        json.containsKey('should'),
        isFalse,
        reason: 'empty buckets are omitted, not serialized as []',
      );
    });

    test('empty buckets are omitted from output', () {
      final json = _decode(
        FilterCodec.encode(
          const Filter(
            must: [FieldEquals(key: 'rank', value: 1)],
            should: [],
          ),
          _schema,
        ),
      );
      expect(json.keys, equals({'must'}));
    });
  });
}

/// One filter, both encodings, same meaning.
///
/// Findings 3, 4 and 8 of the RAG audit were all the same shape: SQLite and
/// qdrant answered the SAME filter differently, and nothing compared them. The
/// canonical semantics now live in the core dartdoc (`vector_store_filter.dart`
/// on [FieldEquals] and [FieldRange]); these assert the qdrant half honours
/// them, so a future divergence fails here instead of in a user's results.
void _crossBackendParityTests() {
  group('canonical semantics — qdrant half', () {
    test('numeric equality is encoded by value, not by JSON spelling', () {
      // `match` cannot carry it: ValueVariants is untagged String|Integer|Bool,
      // so a double is rejected at deserialization and an integer is compared
      // with as_i64(), which returns None for a payload of 4.0. A degenerate
      // range compares numerically and accepts both spellings.
      for (final value in <num>[4, 4.0]) {
        final json = _decode(
          FilterCodec.encode(
            Filter(
              must: [FieldEquals(key: 'price', value: value)],
            ),
            _schema,
          ),
        );
        final cond = (json['must'] as List).single as Map<String, dynamic>;
        expect(cond['match'], isNull, reason: 'match cannot express 4 == 4.0');
        expect(cond['range'], {'gte': value, 'lte': value});
      }
    });

    test('a string equality still uses match', () {
      final json = _decode(
        FilterCodec.encode(
          const Filter(
            must: [FieldEquals(key: 'lang', value: 'en')],
          ),
          _schema,
        ),
      );
      final cond = (json['must'] as List).single as Map<String, dynamic>;
      expect(cond['match'], {'value': 'en'});
    });

    test('a range with neither bound contributes no clause', () {
      // Not `range: {}` — qdrant reads that as an existence test and excludes
      // every non-numeric document, the opposite of the SQLite arm's no-op.
      final json = FilterCodec.encode(
        const Filter(must: [FieldRange(key: 'price')]),
        _schema,
      );
      expect(json, isNull, reason: 'a no-op condition leaves nothing to send');
    });

    test('a one-sided range still encodes that bound', () {
      final json = _decode(
        FilterCodec.encode(
          const Filter(must: [FieldRange(key: 'price', gte: 10)]),
          _schema,
        ),
      );
      final cond = (json['must'] as List).single as Map<String, dynamic>;
      expect(cond['range'], {'gte': 10});
    });
  });
}
