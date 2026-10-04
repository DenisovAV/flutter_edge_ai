import 'dart:convert';

import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/utils/file_name_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One complete, versioned active-embedder pointer.
///
/// This record deliberately contains no application-level embedding profile
/// or RAG identity. It only preserves core model-management state.
final class ActiveEmbeddingIdentityRecord {
  static const int currentSchemaVersion = 1;

  const ActiveEmbeddingIdentityRecord._({
    required this.schemaVersion,
    required this.active,
    this.name,
    this.modelSource,
    this.tokenizerSource,
    this.modelFilename,
    this.tokenizerFilename,
    this.modelFilenameExplicit,
    this.tokenizerFilenameExplicit,
  });

  factory ActiveEmbeddingIdentityRecord.fromSpec(EmbeddingModelSpec spec) {
    final files = spec.files;
    return ActiveEmbeddingIdentityRecord._(
      schemaVersion: currentSchemaVersion,
      active: true,
      name: spec.name,
      modelSource: spec.modelSource.encode(),
      tokenizerSource: spec.tokenizerSource.encode(),
      modelFilename: files[0].filename,
      tokenizerFilename: files[1].filename,
      modelFilenameExplicit: spec.modelFilename != null,
      tokenizerFilenameExplicit: spec.tokenizerFilename != null,
    );
  }

  const ActiveEmbeddingIdentityRecord.cleared()
    : this._(schemaVersion: currentSchemaVersion, active: false);

  final int schemaVersion;
  final bool active;
  final String? name;
  final String? modelSource;
  final String? tokenizerSource;
  final String? modelFilename;
  final String? tokenizerFilename;
  final bool? modelFilenameExplicit;
  final bool? tokenizerFilenameExplicit;

  String encode() => jsonEncode(<String, Object?>{
    'schemaVersion': schemaVersion,
    'active': active,
    if (active) ...{
      'name': name,
      'modelSource': modelSource,
      'tokenizerSource': tokenizerSource,
      'modelFilename': modelFilename,
      'tokenizerFilename': tokenizerFilename,
      'modelFilenameExplicit': modelFilenameExplicit,
      'tokenizerFilenameExplicit': tokenizerFilenameExplicit,
    },
  });

  /// Returns null for malformed, partial, or unsupported records.
  ///
  /// Active records are also checked for internal compatibility: their source
  /// descriptors and explicitness flags must resolve back to the exact stored
  /// filenames. This prevents a partial/mixed record from relabeling files.
  static ActiveEmbeddingIdentityRecord? tryDecode(String? encoded) {
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['schemaVersion'] != currentSchemaVersion ||
          value['active'] is! bool) {
        return null;
      }
      final active = value['active'] as bool;
      if (!active) {
        return const ActiveEmbeddingIdentityRecord.cleared();
      }

      final name = value['name'];
      final modelSource = value['modelSource'];
      final tokenizerSource = value['tokenizerSource'];
      final modelFilename = value['modelFilename'];
      final tokenizerFilename = value['tokenizerFilename'];
      final modelFilenameExplicit = value['modelFilenameExplicit'];
      final tokenizerFilenameExplicit = value['tokenizerFilenameExplicit'];
      if (name is! String ||
          name.isEmpty ||
          modelSource is! String ||
          tokenizerSource is! String ||
          modelFilename is! String ||
          tokenizerFilename is! String ||
          modelFilenameExplicit is! bool ||
          tokenizerFilenameExplicit is! bool) {
        return null;
      }

      FileNameUtils.validatePortableFileNameSegment(
        modelFilename,
        parameterName: 'modelFilename',
      );
      FileNameUtils.validatePortableFileNameSegment(
        tokenizerFilename,
        parameterName: 'tokenizerFilename',
      );
      final decodedModelSource = ModelSource.tryDecode(modelSource);
      final decodedTokenizerSource = ModelSource.tryDecode(tokenizerSource);
      if (decodedModelSource == null || decodedTokenizerSource == null) {
        return null;
      }
      final reconstructed = EmbeddingModelSpec(
        name: name,
        modelSource: decodedModelSource,
        tokenizerSource: decodedTokenizerSource,
        modelFilename: modelFilenameExplicit ? modelFilename : null,
        tokenizerFilename: tokenizerFilenameExplicit ? tokenizerFilename : null,
      );
      final resolved = reconstructed.files;
      if (resolved[0].filename != modelFilename ||
          resolved[1].filename != tokenizerFilename) {
        return null;
      }

      return ActiveEmbeddingIdentityRecord._(
        schemaVersion: currentSchemaVersion,
        active: true,
        name: name,
        modelSource: modelSource,
        tokenizerSource: tokenizerSource,
        modelFilename: modelFilename,
        tokenizerFilename: tokenizerFilename,
        modelFilenameExplicit: modelFilenameExplicit,
        tokenizerFilenameExplicit: tokenizerFilenameExplicit,
      );
    } catch (_) {
      return null;
    }
  }

  EmbeddingModelSpec toSpec({
    ModelSource? runtimeModelSource,
    ModelSource? runtimeTokenizerSource,
  }) {
    if (!active) {
      throw StateError('A cleared embedding identity has no model spec');
    }
    return EmbeddingModelSpec(
      name: name!,
      modelSource: runtimeModelSource ?? ModelSource.tryDecode(modelSource!)!,
      tokenizerSource:
          runtimeTokenizerSource ?? ModelSource.tryDecode(tokenizerSource!)!,
      modelFilename: modelFilenameExplicit! ? modelFilename : null,
      tokenizerFilename: tokenizerFilenameExplicit! ? tokenizerFilename : null,
    );
  }
}

/// Storage seam used to test delayed/out-of-order platform persistence.
abstract interface class ActiveEmbeddingIdentityPersistence {
  Future<String?> read();
  Future<bool> write(String encodedRecord);
  Future<void> reload();
}

/// Receives committed identity changes without keeping managers alive.
abstract interface class ActiveEmbeddingIdentityObserver {
  void onActiveEmbeddingIdentityEnqueued(int generation);
  void onActiveEmbeddingIdentityCommitted(
    ActiveEmbeddingIdentityRecord record,
    int generation,
  );
  void onActiveEmbeddingIdentityPoisoned();
}

final class ActiveEmbeddingIdentityMutation {
  const ActiveEmbeddingIdentityMutation({
    required this.generation,
    required this.committed,
  });

  final int generation;
  final Future<bool> committed;
}

final class ActiveEmbeddingIdentityReadLease {
  const ActiveEmbeddingIdentityReadLease({
    required this.encodedRecord,
    required this.generation,
  });

  final String? encodedRecord;
  final int generation;

  /// Exact persistence fingerprint observed by this lease.
  String get fingerprint => encodedRecord ?? '<absent>';
}

final class ActiveEmbeddingIdentityPersistenceException implements Exception {
  const ActiveEmbeddingIdentityPersistenceException({
    required this.writeFailure,
    this.reloadFailure,
  });

  final Object writeFailure;
  final Object? reloadFailure;

  @override
  String toString() {
    final reload = reloadFailure == null
        ? 'cache reload completed'
        : 'cache reload failed: $reloadFailure';
    return 'Active embedding identity persistence failed: $writeFailure; '
        '$reload. The coordinator is poisoned.';
  }
}

final class SharedPreferencesActiveEmbeddingIdentityPersistence
    implements ActiveEmbeddingIdentityPersistence {
  const SharedPreferencesActiveEmbeddingIdentityPersistence();

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(PreferencesKeys.activeEmbeddingIdentityRecord);
  }

  @override
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
  }

  @override
  Future<bool> write(String encodedRecord) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = await prefs.setString(
      PreferencesKeys.activeEmbeddingIdentityRecord,
      encodedRecord,
    );
    if (!stored) return false;

    // The atomic record is authoritative once stored. Legacy cleanup is only
    // hygiene and must never turn a successful replacement into a failure.
    try {
      await Future.wait(<Future<bool>>[
        prefs.remove(PreferencesKeys.activeEmbeddingFilename),
        prefs.remove(PreferencesKeys.activeEmbeddingTokenizerFilename),
        prefs.remove(PreferencesKeys.activeEmbeddingSource),
        prefs.remove(PreferencesKeys.activeEmbeddingTokenizerSource),
        prefs.remove(PreferencesKeys.activeEmbeddingModelFilenameExplicit),
        prefs.remove(PreferencesKeys.activeEmbeddingTokenizerFilenameExplicit),
      ]);
    } catch (_) {
      // Best effort: readers must trust the atomic record whenever it exists.
    }
    return true;
  }
}

/// Serializes active-identity replacement so a slower old write cannot win.
final class ActiveEmbeddingIdentityCoordinator {
  ActiveEmbeddingIdentityCoordinator(this._persistence);

  factory ActiveEmbeddingIdentityCoordinator.shared(
    ActiveEmbeddingIdentityPersistence persistence,
  ) {
    if (persistence is SharedPreferencesActiveEmbeddingIdentityPersistence) {
      return _sharedPreferencesCoordinator;
    }
    return _sharedByPersistence[persistence] ??=
        ActiveEmbeddingIdentityCoordinator(persistence);
  }

  static final ActiveEmbeddingIdentityCoordinator
  _sharedPreferencesCoordinator = ActiveEmbeddingIdentityCoordinator(
    const SharedPreferencesActiveEmbeddingIdentityPersistence(),
  );
  static final Map<
    ActiveEmbeddingIdentityPersistence,
    ActiveEmbeddingIdentityCoordinator
  >
  _sharedByPersistence = Map.identity();

  final ActiveEmbeddingIdentityPersistence _persistence;
  Future<void> _writeTail = Future<void>.value();
  int _generation = 0;
  ActiveEmbeddingIdentityPersistenceException? _poisonedBy;
  final List<WeakReference<ActiveEmbeddingIdentityObserver>> _observers = [];

  void registerObserver(ActiveEmbeddingIdentityObserver observer) {
    _observers.removeWhere((reference) => reference.target == null);
    if (_observers.any((reference) => identical(reference.target, observer))) {
      return;
    }
    _observers.add(WeakReference<ActiveEmbeddingIdentityObserver>(observer));
  }

  void _forEachObserver(
    void Function(ActiveEmbeddingIdentityObserver observer) notify,
  ) {
    _observers.removeWhere((reference) {
      final observer = reference.target;
      if (observer == null) return true;
      notify(observer);
      return false;
    });
  }

  void _notifyEnqueued(int generation) => _forEachObserver(
    (observer) => observer.onActiveEmbeddingIdentityEnqueued(generation),
  );

  void _notifyCommitted(ActiveEmbeddingIdentityRecord record, int generation) =>
      _forEachObserver(
        (observer) =>
            observer.onActiveEmbeddingIdentityCommitted(record, generation),
      );

  void _notifyPoisoned() => _forEachObserver(
    (observer) => observer.onActiveEmbeddingIdentityPoisoned(),
  );

  Never _throwPoisoned() {
    throw _poisonedBy!;
  }

  Future<Never> _poisonAfterWriteFailure(Object writeFailure) async {
    Object? reloadFailure;
    try {
      await _persistence.reload();
    } catch (error) {
      reloadFailure = error;
    }
    final failure = ActiveEmbeddingIdentityPersistenceException(
      writeFailure: writeFailure,
      reloadFailure: reloadFailure,
    );
    _poisonedBy = failure;
    _notifyPoisoned();
    throw failure;
  }

  Future<ActiveEmbeddingIdentityReadLease> readLease() async {
    try {
      await _writeTail;
    } catch (_) {
      // The structured failure is rethrown below from coordinator poison so
      // no manager in this isolate can trust a possibly mutated cache.
    }
    if (_poisonedBy != null) _throwPoisoned();
    final generation = _generation;
    final encodedRecord = await _persistence.read();
    return ActiveEmbeddingIdentityReadLease(
      encodedRecord: encodedRecord,
      generation: generation,
    );
  }

  bool isLeaseCurrent(ActiveEmbeddingIdentityReadLease lease) =>
      _poisonedBy == null && lease.generation == _generation;

  /// Enqueues a replacement, or returns null synchronously once poisoned.
  ///
  /// The generation is assigned before this method returns. A later enqueue
  /// can therefore supersede an in-flight write before its caller publishes
  /// any corresponding in-memory state.
  ActiveEmbeddingIdentityMutation? enqueue(
    ActiveEmbeddingIdentityRecord record,
  ) {
    if (_poisonedBy != null) return null;
    final generation = ++_generation;
    _notifyEnqueued(generation);
    final previous = _writeTail;
    final operation = () async {
      try {
        await previous;
      } catch (_) {
        // A failed older write must not poison later replacements.
      }
      if (_poisonedBy != null) _throwPoisoned();
      if (generation != _generation) return false;
      late final bool stored;
      try {
        stored = await _persistence.write(record.encode());
      } catch (error) {
        return _poisonAfterWriteFailure(error);
      }
      if (!stored) {
        return _poisonAfterWriteFailure(StateError('write returned false'));
      }
      if (generation != _generation) return false;
      _notifyCommitted(record, generation);
      return true;
    }();
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return ActiveEmbeddingIdentityMutation(
      generation: generation,
      committed: operation,
    );
  }

  ActiveEmbeddingIdentityMutation enqueueOrThrow(
    ActiveEmbeddingIdentityRecord record,
  ) => enqueue(record) ?? _throwPoisoned();

  Future<bool> replace(ActiveEmbeddingIdentityRecord record) =>
      enqueueOrThrow(record).committed;
}
