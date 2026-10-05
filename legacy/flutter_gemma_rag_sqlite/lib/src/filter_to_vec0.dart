import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;

import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

/// Translates a [Filter] into a SQL `WHERE` fragment over vec0's declared
/// typed metadata columns, plus the ordered bind list.
///
/// It also owns the value dialect for the OTHER direction — the `INSERT` binds
/// both store arms promote a document's metadata into ([coerceForColumn],
/// [declaredColumnValues]). The two sides live together deliberately: a value
/// written into a typed vec0 column and a value bound into a predicate over
/// that column must be the same SQLite type, or the row is unfindable. They
/// used to live in three places and had already drifted (see
/// [coerceForColumn]).
///
/// vec0 KNN only filters on columns declared in the `vec0(...)` DDL
/// (TEXT/INT/FLOAT/BOOLEAN, max 16), with operators `= != > >= < <= BETWEEN IN`.
/// `json_extract` and auxiliary `+` columns are NOT filterable — so this
/// translator maps each [Condition] onto a single declared column by its
/// [FilterField.name].
///
/// Contract (mirrors [VectorStoreRepository]'s never-throws filter guarantee):
///   * A condition whose key is NOT in [FilterSchema] is **skipped** — a
///     documented no-op, never an error. The same applies to a [FieldRange]
///     with both bounds null (no constraint to express).
///   * An empty / all-skipped [Filter] yields an empty `whereSql` and empty
///     `binds`; the caller runs the unfiltered KNN.
///   * Booleans bind as `0`/`1` (vec0 has no boolean literal in bound params).
///
/// Bucket semantics match [Filter]:
///   * `must`    — conditions AND-joined.
///   * `should`  — conditions OR-joined, wrapped in one parenthesised group.
///   * `mustNot` — conditions AND-joined, negated as `NOT (...)`.
/// Buckets are themselves AND-joined together.
class FilterToVec0 {
  const FilterToVec0._();

  /// Wraps a declared [FilterField.name] in SQLite's double-quoted identifier
  /// form for use in statements **SQLite itself** parses (the `INSERT` column
  /// list, the KNN `WHERE`).
  ///
  /// Needed because [FilterField.namePattern] accepts names that are also SQL
  /// keywords. Measured on vec0 0.1.9: `order` passes the `vec0(…)` DDL (its
  /// tokenizer has no keyword table) but then
  /// `INSERT INTO t(id, embedding, order, …)` dies with
  /// `near "order": syntax error`. Quoting fixes it, and it is the right fix
  /// rather than banning keywords, because a keyword is a perfectly good
  /// qdrant payload key — a ban there would have no cross-backend
  /// justification.
  ///
  /// Quoting is applied **only** here, never in the `vec0(…)` DDL: sqlite-vec's
  /// own DDL grammar rejects every quoting form (see [FilterField]), so the
  /// column is created bare and referenced quoted.
  ///
  /// No escaping is needed: [FilterField.namePattern] has already excluded `"`
  /// (and every other non-word character), so the name cannot terminate the
  /// quoted identifier.
  ///
  /// Measured not to cost pushdown — `category = ?` and `"category" = ?` yield
  /// the identical vec0 plan (`SCAN t VIRTUAL TABLE INDEX 0:3{___}___&Aa_`)
  /// and the identical rows, because SQLite resolves the identifier before
  /// `xBestIndex` ever sees it.
  static String quoteColumn(String name) => '"$name"';

  /// Translates [filter] against [schema] into a vec0 `WHERE` fragment.
  ///
  /// The returned [whereSql] does NOT include the leading `WHERE`/`AND` — the
  /// caller splices it in after `embedding MATCH ? AND k = ?`. It is empty when
  /// there is nothing to filter on.
  static ({String whereSql, List<Object?> binds, bool matchesNothing})
  translate(Filter? filter, FilterSchema schema) {
    if (filter == null || filter.isEmpty) {
      return (whereSql: '', binds: const [], matchesNothing: false);
    }

    final binds = <Object?>[];
    final groups = <String>[];

    final mustSql = _joinConditions(filter.must, schema, binds, ' AND ');
    if (mustSql != null) groups.add(mustSql);

    // `should` is an OR, and that is where dropping a no-op goes wrong. A
    // condition that matches EVERY document makes the whole disjunction true,
    // so the bucket must disappear — losing just that arm leaves the remaining
    // arms as a real constraint, strictly narrower than no filter at all. The
    // condition that was supposed to be ignored would change the answer.
    //
    // "Ignored" and "always true" are different (see core's Condition
    // dartdoc): an undeclared key or a range on a text column is skipped as if
    // never written, in every bucket. Only an unbounded range on a numeric
    // field is evaluated-and-true, and _shouldBucketIsAlwaysTrue asks about
    // exactly that.
    final fusedShould = _fuseOneFieldDisjunction(filter.should, schema);
    final shouldIsAlwaysTrue = _bucketIsAlwaysTrue(fusedShould, schema);
    if (!shouldIsAlwaysTrue) {
      final shouldSql = _joinConditions(fusedShould, schema, binds, ' OR ');
      if (shouldSql != null) {
        groups.add('($shouldSql)');
      } else if (_bucketHasEvaluatedCondition(fusedShould, schema)) {
        // Every arm that was actually EVALUATED matches nothing, so the
        // disjunction does too.
        //
        // The test cannot be "was any arm declared". An ignored arm — a range
        // on a TEXT column — is declared, but it is skipped as if never
        // written, so a bucket holding only ignored arms is a bucket that was
        // never there: no constraint. Asking about declaredness sank the whole
        // filter for `should: [FieldRange(key: 'lang')]` on a string field,
        // while the same condition in `must` correctly matched everything.
        return (whereSql: '', binds: const [], matchesNothing: true);
      }
    }

    // mustNot is "no condition may match", so the two degenerate cases swap
    // places: excluding a condition EVERY document satisfies leaves nothing.
    if (_bucketIsAlwaysTrue(filter.mustNot, schema)) {
      return (whereSql: '', binds: const [], matchesNothing: true);
    }

    // mustNot = "no condition may match". The obvious rendering is
    // NOT (A OR B …), and that is what this used to emit — but vec0 accepts
    // only single-column comparison constraints in a KNN query, and `NOT (…)`
    // is not one. SQLite could not hand it to the virtual table, so vec0
    // returned the k nearest rows UNFILTERED and SQLite discarded afterwards:
    // a post-filter over a global top-k, which silently returns fewer than k
    // rows, or none at all, while looking like a filtered search.
    //
    // Measured on vec0 0.1.9: `NOT (category = 'a')` at k=2 over a 4-row
    // corpus returned 0 rows (EXPLAIN plan `0:3{___}___`, nothing pushed),
    // while `category != 'a'` returned the right 2 (plan `…&Aa_`, pushed).
    //
    // So apply De Morgan and negate each condition into its own pushable
    // comparison: NOT (A OR B) ≡ (NOT A) AND (NOT B).
    final mustNotSql = _joinNegatedConditions(filter.mustNot, schema, binds);
    if (mustNotSql != null) groups.add(mustNotSql);

    if (groups.isEmpty) {
      return (whereSql: '', binds: const [], matchesNothing: false);
    }
    return (
      whereSql: groups.join(' AND '),
      binds: binds,
      matchesNothing: false,
    );
  }

  /// Whether [conditions] contains an arm that is EVALUATED at all — as
  /// opposed to one that is ignored (an undeclared key, or a [FieldRange] on a
  /// non-numeric field). See core's `Condition` dartdoc: ignored and
  /// always-false are different, and only the second makes a disjunction
  /// unsatisfiable.
  static bool _bucketHasEvaluatedCondition(
    List<Condition>? conditions,
    FilterSchema schema,
  ) {
    if (conditions == null) return false;
    for (final c in conditions) {
      final field = schema.fieldFor(c.key);
      if (field == null) continue; // ignored
      if (c is FieldRange && field.type != FilterFieldType.number) {
        continue; // ignored: a range only means something over a number
      }
      return true;
    }
    return false;
  }

  /// Whether [conditions] contains one that is EVALUATED and true of every
  /// document — as opposed to one that is ignored (see core's `Condition`
  /// dartdoc for why those are not the same).
  ///
  /// Today that is exactly an unbounded [FieldRange] on a declared numeric
  /// field: no bound is no constraint. A range on a text/bool column is
  /// ignored instead, and an undeclared key is ignored in every bucket.
  static bool _bucketIsAlwaysTrue(
    List<Condition>? conditions,
    FilterSchema schema,
  ) {
    if (conditions == null) return false;
    for (final c in conditions) {
      final field = schema.fieldFor(c.key);
      if (field == null) continue; // ignored, not true
      if (c is FieldRange &&
          c.gte == null &&
          c.lte == null &&
          field.type == FilterFieldType.number) {
        return true;
      }
    }
    return false;
  }

  /// Rewrites a `should` bucket that is entirely set membership over ONE
  /// declared field into the single [FieldMatchAny] it already means, so the
  /// rendering of that shape is decided here rather than by SQLite.
  ///
  /// `should` is an OR, and SQLite rewrites `year = ? OR year = ?` into
  /// `year IN (?, ?)` on its own — measured, for bound parameters as well as
  /// literals. On a FLOAT column that rewrite throws out of `prepare` (see
  /// [_numberSetMembership]), so the bug reached callers who never wrote a
  /// [FieldMatchAny] at all. Fusing first means the number case takes the
  /// pushable-envelope path, and the string/bool case emits the same `IN` the
  /// optimiser would have produced, explicitly.
  ///
  /// Anything else — two different fields, a [FieldRange] in the mix — is
  /// returned untouched: SQLite folds only same-column equalities, so those
  /// shapes never reach the refusal.
  static List<Condition>? _fuseOneFieldDisjunction(
    List<Condition>? conditions,
    FilterSchema schema,
  ) {
    if (conditions == null || conditions.length < 2) return conditions;

    // Partition rather than bail out. An earlier version returned the whole
    // list untouched the moment it met a FieldRange — and if that range then
    // emitted nothing (unbounded, or on a non-number field: both documented
    // no-ops), what was left was exactly the raw same-column OR this fusion
    // exists to prevent. SQLite folds it back to `IN`, and vec0 refuses `IN`
    // on a FLOAT column, so adding a documented no-op to a working filter
    // turned it into a throw.
    String? key;
    final values = <Object>[];
    final untouched = <Condition>[];
    for (final condition in conditions) {
      // Undeclared keys contribute no fragment at all, so they cannot make the
      // bucket a mixed-column OR either.
      if (schema.fieldFor(condition.key) == null) continue;
      final fusable = switch (condition) {
        FieldEquals() || FieldMatchAny() => true,
        FieldRange() => false,
      };
      if (!fusable || (key != null && condition.key != key)) {
        untouched.add(condition);
        continue;
      }
      key = condition.key;
      switch (condition) {
        case FieldEquals(:final value):
          values.add(value);
        case FieldMatchAny(values: final members):
          values.addAll(members);
        case FieldRange():
          break; // unreachable — FieldRange is never fusable
      }
    }
    if (key == null) return conditions; // nothing fusable was found
    return [FieldMatchAny(key: key, values: values), ...untouched];
  }

  /// Renders one bucket's conditions, appending their binds to [binds] in SQL
  /// order. Skipped conditions (undeclared key, empty range) contribute
  /// nothing. Returns null when the bucket has no usable condition.
  static String? _joinConditions(
    List<Condition>? conditions,
    FilterSchema schema,
    List<Object?> binds,
    String separator,
  ) {
    if (conditions == null || conditions.isEmpty) return null;
    final fragments = <String>[];
    for (final condition in conditions) {
      final field = schema.fieldFor(condition.key);
      if (field == null) continue; // undeclared key → documented no-op
      final fragment = _encodeCondition(condition, field, binds);
      if (fragment != null) fragments.add(fragment);
    }
    if (fragments.isEmpty) return null;
    return fragments.join(separator);
  }

  /// Renders `mustNot` as AND-joined per-condition negations, each one a
  /// comparison vec0 can push into the KNN scan. Returns null when no
  /// condition contributes a constraint.
  static String? _joinNegatedConditions(
    List<Condition>? conditions,
    FilterSchema schema,
    List<Object?> binds,
  ) {
    if (conditions == null || conditions.isEmpty) return null;
    final fragments = <String>[];
    for (final condition in conditions) {
      final field = schema.fieldFor(condition.key);
      if (field == null) continue; // undeclared key — documented no-op
      final sql = _encodeNegatedCondition(condition, field, binds);
      if (sql != null) fragments.add(sql);
    }
    if (fragments.isEmpty) return null;
    return fragments.join(' AND ');
  }

  /// The negation of [condition], written as a constraint vec0 can push.
  /// Null when the condition constrains nothing, so its negation constrains
  /// nothing either.
  static String? _encodeNegatedCondition(
    Condition condition,
    FilterField field,
    List<Object?> binds,
  ) {
    final column = quoteColumn(field.name);
    switch (condition) {
      case FieldEquals(:final value):
        final bind = coerceForColumn(value, field.type);
        // Unstorable value → no stored row equals it → excluding it excludes
        // nothing. Emit no constraint (binding NULL into a pushed `!=` would
        // be handed to vec0, whose comparison is not SQL NULL semantics).
        if (bind == null) return null;
        binds.add(bind);
        return '$column != ?';

      case FieldRange(:final gte, :final lte):
        if (field.type != FilterFieldType.number) return null;
        // A range no document can satisfy excludes nothing, so its negation is
        // no constraint. See the positive branch for why the bounds need their
        // own finite check.
        if (!_isFiniteBound(gte) || !_isFiniteBound(lte)) return null;
        // Two-sided is the one shape that cannot be rescued: measured, vec0
        // pushes neither `NOT BETWEEN` nor the `< a OR > b` rewrite, because
        // OR across bounds is not a single comparison. It therefore keeps the
        // old post-filter behaviour — for this shape alone, instead of for
        // every mustNot. Fixing it needs over-fetching at the store level.
        if (gte != null && lte != null) {
          binds.add(gte);
          binds.add(lte);
          return '$column NOT BETWEEN ? AND ?';
        }
        if (gte != null) {
          binds.add(gte);
          return '$column < ?';
        }
        if (lte != null) {
          // `col > lte` is the obvious negation and it is WRONG here: the
          // absent-number sentinel is -Infinity, which is not > anything, so a
          // document merely MISSING this field would be excluded. It must be
          // returned — a missing key never satisfies a condition, so mustNot
          // keeps it (see FieldEquals in core's vector_store_filter.dart, and
          // qdrant's check_must_not, which is all(|c| !check(c))).
          //
          // `col > lte OR col = -Infinity` says it exactly, but a disjunction
          // is not pushable. NOT BETWEEN covers both in one comparison — it is
          // true of -Infinity and of everything above lte — at the cost of the
          // same post-filter the two-sided negation already accepts. Measured:
          // over d1{2020} d2{2021} d3{absent} d4{2019}, `col > 2020` returned
          // [d2] and NOT BETWEEN returned [d2, d3].
          // The lower guard is a LITERAL, for the same reason absentNumberSql
          // is — and this one is not theoretical. dart2js dispatches
          // package:sqlite3's bind on `is int`, which it implements as
          // `Math.floor(x) === x`; that is TRUE of -double.maxFinite, so the
          // value took the int path, went through `BigInt(-1.797e308)`, and
          // the JS->wasm i64 conversion wrapped it to exactly 0. Measured:
          //   BigInt.asIntN(64, BigInt(-Number.MAX_VALUE)) === 0n
          // so the web emitted `NOT BETWEEN 0 AND lte` and every document with
          // a NEGATIVE value came back from a mustNot that should have
          // excluded it. Native binds the same double correctly, which is why
          // this survived until the arms were compared on rows.
          //
          // As a literal it also keeps the pushdown: measured on vec0 0.1.9,
          // bound and literal forms give the same plan and the same rows.
          binds.add(lte);
          return '$column NOT BETWEEN $lowestFiniteSql AND ?';
        }
        // Unreachable: an unbounded range in mustNot matches every document,
        // so excluding it leaves nothing — translate() answers that before
        // reaching here (_bucketIsAlwaysTrue). It used to return null, reading
        // "constrains nothing, so neither does its negation", which inverted
        // the meaning: the range constrains nothing because it is TRUE of
        // everything, and excluding everything is the strongest constraint
        // there is.
        return null;

      case FieldMatchAny(:final values):
        // "match none of []" excludes nothing, so emit no constraint. Same for
        // a list of values no row could hold. The positive side emits the
        // always-false sentinel '0'; its negation would be an always-true '1',
        // which is not pushable and would drag the whole group back to a
        // post-filter.
        final unwanted = _coerceSet(values, field.type);
        if (unwanted.isEmpty) return null;
        // A chain of `!=`, NOT `NOT IN`. Measured on vec0 0.1.9 at k=1 over a
        // 4-row corpus: `category NOT IN ('a')` returned 0 rows (not pushed),
        // while `category != 'a' AND category != 'b'` returned the right row.
        // Same logic, and only one of the two reaches the KNN scan.
        //
        // This is also why the negated side needs no FLOAT special case: a
        // conjunction of `!=` is exactly what vec0 pushes, on every column
        // kind including FLOAT (measured, plan `…&Af_&Af_`). It is the
        // positive disjunction that has no pushable form, not this.
        final parts = <String>[];
        for (final value in unwanted) {
          binds.add(value);
          parts.add('$column != ?');
        }
        return parts.length == 1 ? parts.first : '(${parts.join(' AND ')})';
    }
  }

  /// Encodes one declared [condition] onto the column for [field], appending
  /// binds (coerced to the column's vec0 storage type). Returns null when the
  /// condition expresses no constraint (e.g. a range with both bounds null).
  static String? _encodeCondition(
    Condition condition,
    FilterField field,
    List<Object?> binds,
  ) {
    final column = quoteColumn(field.name);
    switch (condition) {
      case FieldEquals(:final value):
        final bind = coerceForColumn(value, field.type);
        // Unstorable value → no stored row can equal it. Match nothing rather
        // than binding NULL into a comparison vec0 will push.
        if (bind == null) return '0';
        binds.add(bind);
        return '$column = ?';

      case FieldRange(:final gte, :final lte):
        // A range only makes sense over a numeric column. If the declared field
        // is TEXT/BOOLEAN, treat the condition as unsupported and skip it (a
        // documented no-op), rather than emitting a typed comparison that
        // silently mis-filters.
        if (field.type != FilterFieldType.number) return null;
        // Bounds bypass coerceForColumn — they are bound directly — so the
        // non-finite rule has to be restated here. FieldRange asserts finite
        // bounds, but asserts vanish in release, and -Infinity IS the
        // absent-value sentinel: `year >= -Infinity` returned exactly the
        // documents with no year. Nothing storable compares against a
        // non-finite bound, so the range matches nothing.
        if (!_isFiniteBound(gte) || !_isFiniteBound(lte)) return '0';
        if (gte != null && lte != null) {
          binds.add(gte);
          binds.add(lte);
          return '$column BETWEEN ? AND ?';
        }
        if (gte != null) {
          binds.add(gte);
          return '$column >= ?';
        }
        if (lte != null) {
          // The one positive shape the absent-number sentinel leaks into:
          // -Infinity is <= every bound, so a document MISSING this field
          // would satisfy `year <= 2020`. Measured. Exclude it with a second
          // conjunct — and note both push (plan `…&Bc_&Bb_`), so this costs no
          // pushdown, unlike the OR it replaces.
          binds.add(lte);
          // The sentinel goes in as a LITERAL, not a bind. It is a constant, so
          // there is nothing to inject — and under dart2js it cannot be bound at
          // all: `-Infinity is int` is true there (`_isInt` is
          // `Math.floor(x) === x`), so package:sqlite3's bind switch takes the
          // int branch and the BigInt conversion throws. The message differs per
          // engine (V8: "cannot be converted to a BigInt"; JavaScriptCore: "Not
          // an integer"), so do not grep for it. dart2wasm keeps the two numeric
          // types apart and would have bound it fine — which is why this is
          // browser-conditional, not web-wide. Native binds it fine too, and that
          // is exactly why it stayed invisible until the arms were compared.
          return '($column <= ? AND $column > $absentNumberSql)';
        }
        return null; // no bound → no constraint, skip

      case FieldMatchAny(:final values):
        // Empty list is "match nothing" (see FieldMatchAny dartdoc); vec0 has
        // no `IN ()` literal, so emit an always-false fragment with no binds.
        // Same for a list whose every member is unstorable in this column.
        final wanted = _coerceSet(values, field.type);
        if (wanted.isEmpty) return '0';

        // One member is not a set — and `=` is pushable on every column kind,
        // including FLOAT, where `IN` is not (below).
        if (wanted.length == 1) {
          binds.add(wanted.first);
          return '$column = ?';
        }

        if (field.type != FilterFieldType.number) {
          binds.addAll(wanted);
          final placeholders = List.filled(wanted.length, '?').join(', ');
          return '$column IN ($placeholders)';
        }
        return _numberSetMembership(column, wanted.cast<double>(), binds);
    }
  }

  /// Set membership over a FLOAT column, which vec0 will not accept as `IN`.
  ///
  /// Measured on vec0 0.1.9: `year IN (2023.0, 2024.0)` does not just fail to
  /// push, it *throws* out of `sqlite3_prepare` —
  /// `'xxx in (...)' is only available on INTEGER or TEXT metadata columns.` —
  /// which breaks [VectorStoreRepository]'s promise that a filter never
  /// throws. (TEXT and INTEGER columns do take `IN`, and it is pushed: plan
  /// `…&Ca_`. Only FLOAT and BOOLEAN kinds refuse, in vec0's `xBestIndex`.)
  ///
  /// The obvious rewrite does NOT work: SQLite's OR-to-IN optimisation folds
  /// `year = ? OR year = ?` back into `year IN (?, ?)` before the virtual
  /// table is consulted, so the OR chain throws identically — measured, with
  /// bound parameters as well as with literals. That fold is also why a
  /// `should` bucket of several [FieldEquals] on one FLOAT column used to
  /// throw without ever naming `IN`.
  ///
  /// So the exact test is written as a `CASE`, which SQLite cannot turn into
  /// an `IN` under any optimisation. The cost, stated plainly: **a `CASE` is
  /// not pushable**. vec0's KNN takes a conjunction of single-column
  /// comparisons and nothing else, so a disjunction over one column has no
  /// pushable exact form at all — the `CASE` runs as a post-filter over rows
  /// vec0 already chose, and a post-filter can only ever return FEWER than `k`
  /// rows, never reach past them.
  ///
  /// What can be pushed is the set's envelope, `BETWEEN min AND max`, which is
  /// a superset of it (measured pushed: plan `…&Ae_&Ac_`) and so discards no
  /// match. Emitting both makes vec0 pick its `k` from inside the envelope
  /// instead of from the whole table, which turns the common contiguous case
  /// into an exact, fully-pushed filter. Measured over a 5-row corpus at k=2,
  /// wanting `{2021, 2022}` while the two nearest rows are 1998/1999: the
  /// `CASE` alone returned 0 rows, envelope + `CASE` returned both. Only the
  /// gaps in a non-contiguous set are still paid for as a post-filter.
  static String _numberSetMembership(
    String column,
    List<double> wanted,
    List<Object?> binds,
  ) {
    binds.add(wanted.reduce(math.min));
    binds.add(wanted.reduce(math.max));
    binds.addAll(wanted);
    final whens = List.filled(wanted.length, 'WHEN ? THEN 1').join(' ');
    return '($column BETWEEN ? AND ? AND CASE $column $whens ELSE 0 END)';
  }

  /// The ONE Dart→SQLite mapping for a declared vec0 column, used by both the
  /// `INSERT` binds and the KNN `WHERE` binds, on both the native and the web
  /// store arm:
  ///   * [FilterFieldType.string] → the `String` (vec0 TEXT column);
  ///   * [FilterFieldType.number] → `double` (vec0 FLOAT column);
  ///   * [FilterFieldType.bool]   → `0`/`1` (declared INTEGER, since a bound
  ///     parameter has no boolean literal).
  ///
  /// It has to be one function, because a vec0 metadata column is strictly
  /// typed on write. Measured on vec0 0.1.9, inserting an INTEGER `2024` into
  /// a FLOAT column fails outright:
  /// `Expected float for FLOAT metadata column year, received INTEGER`.
  /// The rule used to be spelled three times — once here for predicates, once
  /// in each store for inserts — and the copies had drifted: the web arm
  /// coerced only the bool case, so `addDocument` with metadata
  /// `{"year": 2024}` stored fine on native (bound `2024.0`) and threw on web
  /// (bound `2024`). Same document, same schema, same package version.
  ///
  /// Returns null when [value] has no representation in the column (absent,
  /// or a JSON type the column cannot hold — a `String` for a FLOAT column,
  /// say). Null means different things to the two callers, and neither of them
  /// may bind it:
  ///   * predicates: a value that cannot be stored can never equal a stored
  ///     one, so the condition is rendered as the always-false `0` (or, when
  ///     negated, dropped) rather than binding NULL;
  ///   * inserts: the column has no value — and vec0 metadata columns are NOT
  ///     nullable (measured: `Expected float for FLOAT metadata column year,
  ///     received NULL`), so the document cannot be stored. That is a vec0
  ///     constraint we cannot paper over; what matters here is that both arms
  ///     now hit it on exactly the same inputs.
  static Object? coerceForColumn(Object? value, FilterFieldType type) {
    switch (type) {
      case FilterFieldType.string:
        return value is String ? value : null;
      case FilterFieldType.number:
        // `bool` is not a `num` in Dart, so booleans fall through to null.
        //
        // NaN and ±Infinity are rejected here, and that is load-bearing rather
        // than tidiness. JSON has no literal for any of them, so no stored
        // payload can hold one and no comparison against one can be satisfied
        // — which is precisely what returning null already means to both
        // callers. Passing them through went wrong in two different ways:
        //
        //   * -Infinity IS the absent-value sentinel, so `FieldEquals(year,
        //     -double.infinity)` bound -Infinity and matched exactly the
        //     documents that have no `year` at all — the opposite of a filter
        //     on year, and returned as an ordinary hit.
        //   * on the qdrant side the same value reached `jsonEncode`, which
        //     refuses all three (measured: JsonUnsupportedObjectError), so the
        //     filter threw out of searchSimilar and broke the never-throws
        //     contract the two stores share.
        //
        // Rejecting here makes both backends agree on one rule, stated in
        // core's Condition dartdoc: a non-finite number matches nothing.
        if (value is! num || !value.isFinite) return null;
        return value.toDouble();
      case FilterFieldType.bool:
        if (value is bool) return value ? 1 : 0;
        // JSON often carries booleans as 0/1; anything else is not a boolean
        // and inventing a truthiness rule for it would answer filters wrongly.
        if (value is num && (value == 0 || value == 1)) {
          return value == 1 ? 1 : 0;
        }
        return null;
    }
  }

  /// Whether [bound] is absent or a number JSON can actually represent.
  ///
  /// NaN and +/-Infinity have no JSON literal, so no stored payload holds one.
  /// Range bounds do not pass through [coerceForColumn], which is where the
  /// same rule lives for equality and set membership, so it is restated here
  /// rather than assumed.
  static bool _isFiniteBound(double? bound) => bound == null || bound.isFinite;

  /// The only shape a declared field name may take here: an ASCII letter, then
  /// ASCII letters, digits or underscores.
  ///
  /// This is `vec0`'s identifier grammar, not a preference. sqlite-vec parses
  /// its own `CREATE VIRTUAL TABLE … USING vec0(…)` DDL with a hand-rolled
  /// tokenizer that accepts nothing else and has NO quoted-identifier form —
  /// `"doc-type"`, `[doc-type]` and backticks were each measured against vec0
  /// 0.1.9 and each fails. So an out-of-set name is unrepresentable, not merely
  /// unescaped, and rejecting it is the only option. A name carrying a comma is
  /// worse than an error: the DDL renders `'$name $type'`, so
  /// `FilterField(name: 'a TEXT, b')` silently declares TWO columns.
  static final RegExp namePattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

  /// Names `vec0` already declares for itself.
  ///
  /// Five are visible in the DDL the stores build; `distance` and `k` are
  /// HIDDEN columns vec0 appends to every table it declares — `sqlite-vec.c`:
  /// `sqlite3_str_appendall(createStr, " distance hidden, k hidden) ")`. They
  /// do not appear in either store's CREATE statement, so reading those is not
  /// enough to find them, which is how `k` was missed on the first pass.
  ///
  /// Measured on vec0 0.1.9: each of these makes the table refuse to be
  /// created. `rowid`, checked at the same time, is accepted and so is
  /// deliberately absent from this list.
  static const reservedNames = {
    'id',
    'embedding',
    'content',
    'metadata',
    'distance',
    'k',
  };

  /// Throws [ArgumentError] when [name] cannot be a vec0 column.
  ///
  /// Lives here rather than in core because these are facts about sqlite-vec:
  /// core has no backends, and holding one backend's grammar there would grow
  /// it with every backend added. The trade-off is that a name legal on qdrant
  /// is refused here — at `configure()`, naming this store, rather than at the
  /// first `addDocument`, which is when the table is actually built.
  static void validateFieldName(String name) {
    if (reservedNames.contains(name)) {
      throw ArgumentError.value(
        name,
        'FilterField.name',
        'reserved: the vec0 table already declares this column '
            '(measured: the table refuses to be created)',
      );
    }
    if (!namePattern.hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'FilterField.name',
        r'must match ^[A-Za-z][A-Za-z0-9_]*$ — it becomes a sqlite-vec `vec0` '
            'column, and that DDL grammar has no quoted identifier form, so '
            'this name cannot be represented there',
      );
    }
  }

  /// How far over-fetching may grow, as a multiple of the requested topK.
  /// Bounded on purpose: without a cap an unpushable filter turns every search
  /// into an O(n) scan, and the cost is invisible until the collection is big.
  static const int maxOverFetchFactor = 16;

  /// Whether to ask vec0 for more candidates, given how many rows the LAST
  /// query returned.
  ///
  /// [rowsReturned] must be the count SQLite handed back — already filtered,
  /// but BEFORE any similarity-threshold rejection. Those two are not the same
  /// limit and must not share a counter: rows arrive ordered by distance, so
  /// once one falls below the threshold every later one does too, and
  /// over-fetching for a threshold shortfall can never help. An earlier version
  /// counted post-threshold rows and so scanned to 16x on a fully-pushed filter
  /// that simply matched nothing, then blamed the filter in its log.
  ///
  /// Shared by the native and web stores. They are one dialect with two call
  /// sites, and the web arm shipped without this loop at all — the same filter
  /// answered `[d4]` on native and `[]` on web.
  static bool shouldOverFetch({
    required int rowsReturned,
    required int topK,
    required int fetch,
    required int totalRows,
  }) {
    if (rowsReturned >= topK) return false; // enough survived the filter
    if (fetch >= totalRows) return false; // asked for the whole table already
    return fetch < topK * maxOverFetchFactor;
  }

  /// Sentinels written for a declared field a document does not carry.
  ///
  /// vec0 type-checks every declared metadata column and exempts nothing —
  /// `sqlite-vec.c` around 8189-8221 rejects NULL for TEXT, FLOAT and INTEGER
  /// alike, and an omitted column IS a NULL. So once a [FilterSchema] declares
  /// a field, a document without it could not be inserted at all: heterogeneous
  /// metadata, the normal RAG case, threw a raw SqliteException.
  ///
  /// A sentinel is a real value, chosen to be as close to unreachable as the
  /// storage allows. NOT unreachable — this used to claim no user value could
  /// equal it, and the very next bullet explains why that is false for TEXT:
  ///
  ///   * TEXT — a NUL-led marker, and it is COLLIDABLE. RFC 8259 forbids only
  ///     RAW control characters, and Dart's jsonDecode accepts the `\u0000`
  ///     escape, so `{"a":"\u0000"}` is legal JSON — and by the same token so
  ///     is `{"a":"\u0000__absent__"}`. A document carrying that exact string
  ///     is indistinguishable from one that omits the field: an equality on it
  ///     also returns every document that has no value at all. There is no
  ///     string a user cannot write, so no choice of marker removes this.
  ///
  ///     The write path logs the collision (see [declaredColumnValues]) — but
  ///     `gemmaLog` is `kDebugMode`-gated, so that is a DEBUG-build diagnostic
  ///     and nothing at all in a shipped app. Saying "the write path reports
  ///     it" without that qualifier would describe a guarantee users do not
  ///     get.
  ///   * FLOAT — negative infinity. NOT NaN: measured, SQLite converts NaN to
  ///     NULL before vec0 sees it (`typeof(9e999*0)` is `null`, and binding
  ///     `double.nan` binds NULL), so a NaN sentinel would throw the very error
  ///     this fixes.
  ///   * INTEGER (bool) — the minimum 64-bit integer. Legal because bool fields
  ///     are declared INTEGER, not BOOLEAN; vec0's BOOLEAN kind accepts only
  ///     0 and 1.
  ///
  /// Why a real value rather than a companion "is present" column: `mustNot`
  /// must return a document that lacks the field — qdrant's `must_not` excludes
  /// only points that SATISFY the condition, and a missing key never does — and
  /// a real sentinel gives that for free, since `col != ?` is true of it and
  /// pushes into the KNN scan. A presence column would need `present = 0 OR
  /// col != ?`, and an OR is exactly what vec0 cannot push, dragging every
  /// mustNot back into the post-filter this file exists to avoid.
  static const String absentText = '\u0000__absent__';
  static const double absentNumber = double.negativeInfinity;

  /// [absentNumber] as a SQL literal, for the places it must not be BOUND.
  ///
  /// SQLite parses an out-of-range exponent as the corresponding infinity, so
  /// this is -Infinity as a REAL — the same value the native arm binds,
  /// expressed where the web's numeric model cannot lose it.
  static const String absentNumberSql = '-9e999';

  /// `-double.maxFinite` as a SQL literal — the lowest FINITE value, used as the
  /// lower guard of a `NOT BETWEEN`.
  ///
  /// Distinct from [absentNumberSql] on purpose: the absent sentinel is
  /// -Infinity and sits BELOW this, which is what makes `NOT BETWEEN
  /// lowestFinite AND x` return the documents that have no value at all — the
  /// documented mustNot behaviour.
  static const String lowestFiniteSql = '-1.7976931348623157e308';
  static const int absentBool = -9223372036854775808;

  /// The sentinel for [type].
  static Object absentValue(FilterFieldType type) => switch (type) {
    FilterFieldType.string => absentText,
    FilterFieldType.number => absentNumber,
    FilterFieldType.bool => absentBool,
  };

  /// Decodes a document's raw [metadata] JSON into the declared typed columns,
  /// one entry per [FilterSchema] field in declaration order, coerced by
  /// [coerceForColumn]. Absent keys, non-object metadata and unparseable
  /// metadata all yield the per-type sentinel for that column, never a throw.
  ///
  /// Shared by both store arms for the same reason [coerceForColumn] is: this
  /// is the write half of the same dialect, and while each arm owned a copy
  /// they disagreed about what `{"year": 2024}` means.
  static Map<String, Object?> declaredColumnValues(
    String? metadata,
    FilterSchema schema,
  ) {
    if (schema.isEmpty) return const {};
    Object? decoded;
    if (metadata != null && metadata.isNotEmpty) {
      try {
        decoded = jsonDecode(metadata);
      } on FormatException {
        decoded = null;
      }
    }
    final json = decoded is Map ? decoded : const {};
    final values = <String, Object?>{};
    for (final field in schema.fields) {
      final raw = json[field.name];
      final coerced = coerceForColumn(raw, field.type);
      if (coerced == absentText && kDebugMode) {
        // A real value equal to the TEXT sentinel. It cannot be told apart
        // from an absent field afterwards, so an equality on it will also
        // return documents that never carried the field. Unfixable in the
        // storage (any string is writable) — see absentText — so the least
        // dishonest thing is to say it happened.
        gemmaLog(
          '[FilterToVec0] metadata["${field.name}"] equals the absent-value '
          'sentinel — this document is indistinguishable from one missing the '
          'field, and filters on it will answer accordingly',
        );
      }
      if (coerced == null && raw != null && kDebugMode) {
        // PRESENT but unstorable — a list for a scalar column, a string for a
        // FLOAT one. It becomes the absent sentinel, so the document reads as
        // if it never carried the field at all: `must` excludes it and
        // `mustNot` returns it, both without a word. The first evidence a
        // developer gets is a query returning fewer rows than expected, long
        // after the write that caused it.
        //
        // Worth a line because this is the one place the two backends cannot
        // be made to agree. qdrant stores the payload verbatim, so an array
        // there has list semantics and DOES match; vec0 has a single scalar
        // column and no way to express that. Neither can imitate the other, so
        // the honest move is to say so at the moment the value is dropped.
        gemmaLog(
          '[FilterToVec0] metadata["${field.name}"] is a ${raw.runtimeType} '
          'but the field is declared ${field.type.name} — stored as absent, '
          'so filters on it will not match this document',
        );
      }
      values[field.name] = coerced ?? absentValue(field.type);
    }
    return values;
  }

  /// The distinct, storable members of a [FieldMatchAny] value list, in the
  /// order given. Values with no representation in the column are dropped —
  /// they can never equal a stored value, so they widen nothing.
  static List<Object> _coerceSet(List<Object> values, FilterFieldType type) {
    final out = <Object>[];
    for (final value in values) {
      final bind = coerceForColumn(value, type);
      if (bind == null || out.contains(bind)) continue;
      out.add(bind);
    }
    return out;
  }
}
