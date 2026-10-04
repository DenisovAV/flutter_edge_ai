// Shared fixtures for the sqlite-vec parity suites — no test framework, no
// dart:io, so this is importable from a browser test as well as a VM one.
//
// It sits under lib/src/testing/ rather than test/ for one reason: the web
// suite lives in another package (flutter_edge_ai/example) and dart2js cannot
// follow a relative import that escapes its own package — the analyzer accepts
// it and the web build then fails with "Undefined name". A `package:` import
// is the only path both compilers agree on.
//
// `.pubignore` keeps this directory out of the published archive, so consumers
// do not download test data; the in-repo workspace resolves it from source.
//
// It lives here rather than being copied into each suite because a duplicated
// expectation table is a drifting one: the native and web arms of this store
// have already come apart once over metadata typing (1.2.0, "the web arm
// rejecting integer metadata the native arm accepts"), and two copies of the
// corpus would have hidden it rather than caught it.
//
// Imported by:
//   * test/cross_backend_parity_test.dart          (native: vec0 vs qdrant)
//   * flutter_edge_ai/example/integration_test/
//       rag_sqlite_web_parity_test.dart            (web: the same rows in Chrome)
library;

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

/// One document: an id and the metadata JSON it carries.
typedef Doc = ({String id, String metadata});

/// One row of the table: a filter, and the ids both stores must return.
typedef Case = ({String name, Filter filter, List<String> expected});

/// Declared once for every case, so a divergence cannot be blamed on the
/// schema differing between the two stores.
final schema = FilterSchema(
  fields: [
    FilterField(name: 'lang', type: FilterFieldType.string),
    FilterField(name: 'price', type: FilterFieldType.number),
    FilterField(name: 'archived', type: FilterFieldType.bool),
  ],
);

/// The corpus. Deliberately heterogeneous — a field missing here, a value of
/// the wrong type there — because that is where the two backends came apart,
/// not on well-formed rows.
const docs = <Doc>[
  (id: 'en_cheap', metadata: '{"lang":"en","price":10,"archived":false}'),
  (id: 'fr_dear', metadata: '{"lang":"fr","price":90,"archived":false}'),
  (id: 'de_arch', metadata: '{"lang":"de","price":50,"archived":true}'),
  // archived written as 1 rather than true — the same document to a reader,
  // and two different payload variants to qdrant.
  (id: 'es_arch1', metadata: '{"lang":"es","price":50,"archived":1}'),
  // No `price` at all. The normal RAG case, and the one that could not even be
  // inserted before absent-value sentinels.
  (id: 'no_price', metadata: '{"lang":"it","archived":false}'),
  // A NEGATIVE price. Present so the `mustNot` + upper-bound case below can
  // tell the two arms apart: the lower guard of that NOT BETWEEN used to be a
  // bound -double.maxFinite, which dart2js wrapped to 0, so the web returned
  // this document from a filter that excludes it.
  (id: 'neg_price', metadata: '{"lang":"nl","price":-5,"archived":false}'),
  // A price that is not a number. sqlite cannot store it; qdrant keeps it.
  (id: 'str_price', metadata: '{"lang":"pt","price":"cheap","archived":false}'),
];

final cases = <Case>[
  (
    name: 'equality on a string field',
    filter: const Filter(
      must: [FieldEquals(key: 'lang', value: 'en')],
    ),
    expected: ['en_cheap'],
  ),
  (
    name: 'equality compares numbers by value, not by JSON spelling',
    // 50 and 50.0 are the same number; a store must not disagree.
    filter: const Filter(must: [FieldEquals(key: 'price', value: 50.0)]),
    expected: ['de_arch', 'es_arch1'],
  ),
  (
    name: 'a missing field never satisfies a condition',
    filter: const Filter(must: [FieldRange(key: 'price', gte: 0)]),
    expected: ['en_cheap', 'fr_dear', 'de_arch', 'es_arch1'],
  ),
  (
    name: 'mustNot RETURNS the document that lacks the field',
    // The rule core documents: must excludes it, mustNot keeps it.
    filter: const Filter(mustNot: [FieldRange(key: 'price', gte: 60)]),
    expected: [
      'en_cheap',
      'de_arch',
      'es_arch1',
      'no_price',
      'str_price',
      'neg_price',
    ],
  ),
  (
    name: 'both JSON spellings of a bool are one value',
    filter: const Filter(must: [FieldEquals(key: 'archived', value: true)]),
    expected: ['de_arch', 'es_arch1'],
  ),
  (
    name: 'a value that cannot inhabit the declared type matches nothing',
    // qdrant used to match str_price here and sqlite did not.
    filter: const Filter(
      must: [FieldEquals(key: 'price', value: 'cheap')],
    ),
    expected: [],
  ),
  (
    name: 'a non-bool-ish number is not a bool',
    // `value == 1` made 2 mean false, matching every unarchived document.
    filter: const Filter(must: [FieldEquals(key: 'archived', value: 2)]),
    expected: [],
  ),
  (
    name: 'set membership over a string field',
    filter: const Filter(
      must: [
        FieldMatchAny(key: 'lang', values: ['en', 'de']),
      ],
    ),
    expected: ['en_cheap', 'de_arch'],
  ),
  (
    name: 'set membership over a number field',
    filter: const Filter(
      must: [
        FieldMatchAny(key: 'price', values: [10, 90]),
      ],
    ),
    expected: ['en_cheap', 'fr_dear'],
  ),
  (
    name: 'an off-type member of a set is dropped, not matched',
    filter: const Filter(
      must: [
        FieldMatchAny(key: 'price', values: ['cheap', 10]),
      ],
    ),
    expected: ['en_cheap'],
  ),
  (
    name: 'an undeclared key is a no-op, not a narrowing',
    filter: const Filter(
      must: [
        FieldEquals(key: 'lang', value: 'en'),
        FieldEquals(key: 'nosuchfield', value: 'x'),
      ],
    ),
    expected: ['en_cheap'],
  ),
  (
    name: 'an undeclared key in should does not narrow either',
    filter: const Filter(
      should: [
        FieldEquals(key: 'lang', value: 'en'),
        FieldEquals(key: 'nosuchfield', value: 'x'),
      ],
    ),
    expected: ['en_cheap'],
  ),
  (
    name: 'an unbounded range constrains nothing',
    filter: const Filter(
      must: [
        FieldEquals(key: 'lang', value: 'en'),
        FieldRange(key: 'price'),
      ],
    ),
    expected: ['en_cheap'],
  ),
  (
    name: 'an always-true arm makes the whole should bucket true',
    filter: const Filter(
      should: [
        FieldEquals(key: 'lang', value: 'en'),
        FieldRange(key: 'price'),
      ],
    ),
    expected: [
      'en_cheap',
      'fr_dear',
      'de_arch',
      'es_arch1',
      'no_price',
      'str_price',
      'neg_price',
    ],
  ),
  (
    name: 'an ignored range on a string field is skipped in should',
    filter: const Filter(
      should: [
        FieldEquals(key: 'lang', value: 'en'),
        FieldRange(key: 'lang', gte: 1),
      ],
    ),
    expected: ['en_cheap'],
  ),
  (
    name: 'an empty set matches nothing',
    filter: const Filter(
      must: [FieldMatchAny(key: 'lang', values: [])],
    ),
    expected: [],
  ),
  (
    name: 'excluding an empty set excludes nothing',
    filter: const Filter(
      mustNot: [FieldMatchAny(key: 'lang', values: [])],
    ),
    expected: [
      'en_cheap',
      'fr_dear',
      'de_arch',
      'es_arch1',
      'no_price',
      'str_price',
      'neg_price',
    ],
  ),
  (
    // The shape that caught the dart2js i64 wrap. A one-sided upper bound in
    // mustNot compiles to `NOT BETWEEN <lowest finite> AND lte`, and the lower
    // guard has to really be the lowest finite value — bound as a double it
    // became 0 on the web, so everything negative came back.
    name: 'mustNot with an upper bound excludes the negative value too',
    filter: const Filter(mustNot: [FieldRange(key: 'price', lte: 20)]),
    expected: ['fr_dear', 'de_arch', 'es_arch1', 'no_price', 'str_price'],
  ),
  (
    name: 'mustNot over a set',
    filter: const Filter(
      mustNot: [
        FieldMatchAny(key: 'lang', values: ['en', 'fr']),
      ],
    ),
    expected: ['de_arch', 'es_arch1', 'no_price', 'str_price', 'neg_price'],
  ),
  (
    name: 'must and mustNot compose',
    filter: const Filter(
      must: [FieldRange(key: 'price', gte: 10, lte: 90)],
      mustNot: [FieldEquals(key: 'lang', value: 'fr')],
    ),
    expected: ['en_cheap', 'de_arch', 'es_arch1'],
  ),
];

/// A vector that is the same for every document, so distance never decides the
/// result set and any difference is the filter's doing.
final embedding = List<double>.filled(4, 0.5);
