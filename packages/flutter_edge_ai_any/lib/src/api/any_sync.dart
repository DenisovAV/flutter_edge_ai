// The public API of flutter_edge_ai_any (design v2.2 §1) and the store
// behind it. One library, in parts, so the value types keep private
// constructors while the account and the store build them.
//
// Nothing here calls native code: every native call is a job sent through
// the AnyNative seam (lib/src/native/any_native.dart), built by a
// top-level function in lib/src/logic/jobs.dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:meta/meta.dart';

import '../logic/engine.dart';
import '../logic/filter_mongo.dart';
import '../logic/formats.dart';
import '../logic/jobs.dart';
import '../native/any_native.dart';
import '../native/fs.dart';
import '../native/native_factory.dart';

part 'account.dart';
part 'core.dart';
part 'exceptions.dart';
part 'provider.dart';
part 'store.dart';
part 'types.dart';

/// The platform's native layer, or the test override.
AnyNative _nativeLayer() => debugAnyNativeOverride ?? createAnyNative();

/// The largest topK a search takes (any-store's KnnMaxK).
const _maxTopK = 10000;

/// A FIFO async lock.
final class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() body) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) => body()).whenComplete(done.complete);
  }
}

/// The binding as the local state stores it.
Map<String, Object?> _bindingJson(VectorStoreBinding b) => {
  'profileId': b.profile.id,
  'dimension': b.profile.dimension,
  'documents': b.documents.name,
};

VectorStoreBinding _bindingFrom(Map<String, Object?> j) => VectorStoreBinding(
  profile: EmbeddingProfile(
    id: j['profileId']! as String,
    dimension: j['dimension']! as int,
  ),
  documents: _modality(j['documents'] as String?) ?? EmbeddingModality.text,
);

/// The text of a text search as any-store's `$search`: every
/// whitespace-separated term as a quoted phrase (`"` doubled), so user
/// input never reaches the query syntax; the terms are OR'ed (any-store's
/// default).
String? _textQuery(String text) {
  // C strings end at a NUL; a NUL is never part of a term.
  final terms = text
      .replaceAll('\u0000', ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (terms.isEmpty) return null;
  return terms.map((t) => '"${t.replaceAll('"', '""')}"').join(' ');
}
