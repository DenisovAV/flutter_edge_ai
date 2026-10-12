import 'dart:convert';

import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/domain/no_active_model_error.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/utils/file_name_utils.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// One complete, versioned active-embedder pointer.
///
/// This record deliberately contains no application-level embedding profile
/// or RAG identity. It only preserves core model-management state.
///
/// Two schemas (R5 §5.4):
///  * **v1** — a model plus its tokenizer. Written byte for byte as 2.1 wrote
///    it, so a downgrade still reads it; [cleared] is v1 too.
///  * **v2** — a self-contained model (`EmbeddingModelSpec.isSelfContained`,
///    a `.litertlm` bundle): no tokenizer fields. A 2.1 reader accepts only
///    schema 1, so it gets null and restores no active embedder — it fails
///    closed instead of pairing the bundle with a tokenizer it never had.
final class ActiveEmbeddingIdentityRecord {
  /// The schema of a record with a tokenizer, and of [cleared].
  static const int currentSchemaVersion = 1;

  /// The schema of a self-contained record.
  static const int selfContainedSchemaVersion = 2;

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
    final tokenizerSource = spec.tokenizerSource;
    if (tokenizerSource == null) {
      return ActiveEmbeddingIdentityRecord._(
        schemaVersion: selfContainedSchemaVersion,
        active: true,
        name: spec.name,
        modelSource: spec.modelSource.encode(),
        modelFilename: files[0].filename,
        modelFilenameExplicit: spec.modelFilename != null,
      );
    }
    return ActiveEmbeddingIdentityRecord._(
      schemaVersion: currentSchemaVersion,
      active: true,
      name: spec.name,
      modelSource: spec.modelSource.encode(),
      tokenizerSource: tokenizerSource.encode(),
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

  /// Null in a self-contained (v2) record.
  final String? tokenizerSource;
  final String? modelFilename;

  /// Null in a self-contained (v2) record.
  final String? tokenizerFilename;
  final bool? modelFilenameExplicit;

  /// Null in a self-contained (v2) record.
  final bool? tokenizerFilenameExplicit;

  /// Whether this record names a self-contained model (schema v2).
  bool get isSelfContained => schemaVersion == selfContainedSchemaVersion;

  String encode() => jsonEncode(<String, Object?>{
    'schemaVersion': schemaVersion,
    'active': active,
    if (active && isSelfContained) ...{
      'name': name,
      'modelSource': modelSource,
      'modelFilename': modelFilename,
      'modelFilenameExplicit': modelFilenameExplicit,
    } else if (active) ...{
      'name': name,
      'modelSource': modelSource,
      'tokenizerSource': tokenizerSource,
      'modelFilename': modelFilename,
      'tokenizerFilename': tokenizerFilename,
      'modelFilenameExplicit': modelFilenameExplicit,
      'tokenizerFilenameExplicit': tokenizerFilenameExplicit,
    },
  });

  /// Returns null for malformed, partial, or unsupported records — see
  /// [decode] for why.
  static ActiveEmbeddingIdentityRecord? tryDecode(String? encoded) =>
      decode(encoded).record;

  /// The record [encoded] stands for, or — when it is refused — why.
  ///
  /// Active records are also checked for internal compatibility: they are
  /// rebuilt through the `EmbeddingModelSpec` constructor (so its invariants
  /// apply), and their source descriptors and explicitness flags must resolve
  /// back to the exact stored filenames. This prevents a partial/mixed record
  /// from relabeling files. Nothing stored ([encoded] null) is neither a
  /// record nor a rejection.
  static ({ActiveEmbeddingIdentityRecord? record, String? rejection}) decode(
    String? encoded,
  ) {
    ({ActiveEmbeddingIdentityRecord? record, String? rejection}) refuse(
      String why,
    ) => (record: null, rejection: why);

    if (encoded == null) return (record: null, rejection: null);
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> || value['active'] is! bool) {
        return refuse('it is not a JSON object with an "active" flag');
      }
      final schemaVersion = value['schemaVersion'];
      final active = value['active'] as bool;
      if (schemaVersion == selfContainedSchemaVersion) {
        return active
            ? _decodeSelfContained(value)
            : refuse(
                'it is an inactive schema-2 record, which is never written',
              );
      }
      if (schemaVersion != currentSchemaVersion) {
        return refuse(
          'its schema version $schemaVersion is not one this version reads '
          '($currentSchemaVersion or $selfContainedSchemaVersion)',
        );
      }
      if (!active) {
        return (
          record: const ActiveEmbeddingIdentityRecord.cleared(),
          rejection: null,
        );
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
        return refuse('it is missing fields, or has fields of the wrong type');
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
        return refuse('it names a model source this version cannot decode');
      }
      final reconstructed = EmbeddingModelSpec(
        name: name,
        modelSource: decodedModelSource,
        tokenizerSource: decodedTokenizerSource,
        modelFilename: modelFilenameExplicit ? modelFilename : null,
        tokenizerFilename: tokenizerFilenameExplicit ? tokenizerFilename : null,
      );
      final resolved = reconstructed.files;
      if (resolved.length != 2 ||
          resolved[0].filename != modelFilename ||
          resolved[1].filename != tokenizerFilename) {
        return refuse('its file names do not resolve from its sources');
      }

      return (
        record: ActiveEmbeddingIdentityRecord._(
          schemaVersion: currentSchemaVersion,
          active: true,
          name: name,
          modelSource: modelSource,
          tokenizerSource: tokenizerSource,
          modelFilename: modelFilename,
          tokenizerFilename: tokenizerFilename,
          modelFilenameExplicit: modelFilenameExplicit,
          tokenizerFilenameExplicit: tokenizerFilenameExplicit,
        ),
        rejection: null,
      );
    } on ArgumentError catch (e) {
      return refuse('${e.message}');
    } catch (e) {
      return refuse('$e');
    }
  }

  /// A v2 record: name, model source and model filename, no tokenizer. Only
  /// ever active — a clear is written as v1.
  static ({ActiveEmbeddingIdentityRecord? record, String? rejection})
  _decodeSelfContained(Map<String, dynamic> value) {
    final name = value['name'];
    final modelSource = value['modelSource'];
    final modelFilename = value['modelFilename'];
    final modelFilenameExplicit = value['modelFilenameExplicit'];
    if (name is! String ||
        name.isEmpty ||
        modelSource is! String ||
        modelFilename is! String ||
        modelFilenameExplicit is! bool) {
      return (
        record: null,
        rejection: 'it is missing fields, or has fields of the wrong type',
      );
    }
    FileNameUtils.validatePortableFileNameSegment(
      modelFilename,
      parameterName: 'modelFilename',
    );
    final decodedModelSource = ModelSource.tryDecode(modelSource);
    if (decodedModelSource == null) {
      return (
        record: null,
        rejection: 'it names a model source this version cannot decode',
      );
    }
    // The constructor refuses anything but a self-contained bundle here.
    final reconstructed = EmbeddingModelSpec(
      name: name,
      modelSource: decodedModelSource,
      modelFilename: modelFilenameExplicit ? modelFilename : null,
    );
    final resolved = reconstructed.files;
    if (resolved.length != 1 || resolved[0].filename != modelFilename) {
      return (
        record: null,
        rejection: 'its file name does not resolve from its source',
      );
    }
    return (
      record: ActiveEmbeddingIdentityRecord._(
        schemaVersion: selfContainedSchemaVersion,
        active: true,
        name: name,
        modelSource: modelSource,
        modelFilename: modelFilename,
        modelFilenameExplicit: modelFilenameExplicit,
      ),
      rejection: null,
    );
  }

  /// The spec this record stands for. [runtimeModelSource] and
  /// [runtimeTokenizerSource] replace the persisted sources (native restore
  /// points them at the installed files); a self-contained record has no
  /// tokenizer, so [runtimeTokenizerSource] is ignored for it.
  EmbeddingModelSpec toSpec({
    ModelSource? runtimeModelSource,
    ModelSource? runtimeTokenizerSource,
  }) {
    if (!active) {
      throw StateError('A cleared embedding identity has no model spec');
    }
    final modelSource =
        runtimeModelSource ?? ModelSource.tryDecode(this.modelSource!)!;
    if (isSelfContained) {
      return EmbeddingModelSpec(
        name: name!,
        modelSource: modelSource,
        modelFilename: modelFilenameExplicit! ? modelFilename : null,
      );
    }
    return EmbeddingModelSpec(
      name: name!,
      modelSource: modelSource,
      tokenizerSource:
          runtimeTokenizerSource ?? ModelSource.tryDecode(tokenizerSource!)!,
      modelFilename: modelFilenameExplicit! ? modelFilename : null,
      tokenizerFilename: tokenizerFilenameExplicit! ? tokenizerFilename : null,
    );
  }
}

/// Why the persisted active-embedder record was refused at the last restore
/// in this isolate, or null. The restore fails closed (no embedder is
/// active); this lets `getActiveEmbedder` say why instead of "No active
/// embedding model set". Cleared whenever a new identity is written.
String? _rejectedActiveEmbeddingIdentity;
bool _rejectionPrinted = false;

/// See [_rejectedActiveEmbeddingIdentity].
String? get rejectedActiveEmbeddingIdentity => _rejectedActiveEmbeddingIdentity;

/// Records that the persisted record was refused, and says so once per
/// isolate — with `print`, because `edgeAiLog` is silent in release builds,
/// where an app that "forgot" its embedder after an update gets debugged.
void reportRejectedActiveEmbeddingIdentity(String reason) {
  _rejectedActiveEmbeddingIdentity = reason;
  if (_rejectionPrinted) return;
  _rejectionPrinted = true;
  // ignore: avoid_print
  print(
    '[flutter_edge_ai] WARNING: the persisted active embedding model could '
    'not be read ($reason), so no embedder is active. Install it again with '
    'FlutterEdgeAi.installEmbedder().',
  );
}

/// Forgets a rejection and the one-shot notice. For tests.
@visibleForTesting
void resetRejectedActiveEmbeddingIdentity() {
  _rejectedActiveEmbeddingIdentity = null;
  _rejectionPrinted = false;
}

/// What asking for the active embedder answers when none is active: the
/// reason a persisted record was refused, when one was.
NoActiveModelError noActiveEmbedderError() {
  final rejected = _rejectedActiveEmbeddingIdentity;
  return NoActiveModelError(
    rejected == null
        ? 'No active embedding model set. Use FlutterEdgeAi.installEmbedder() '
              'first.'
        : 'The persisted active embedding model could not be read '
              '($rejected), so none is active. Install it again with '
              'FlutterEdgeAi.installEmbedder().',
  );
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
    // A new identity (activation or clear) supersedes a refused old record.
    _rejectedActiveEmbeddingIdentity = null;
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
