// The active-identity writes must land as one uninterruptible burst (#468).
//
// WebModelManager pulls in dart:js_interop and cannot load on the VM, so this
// runs in a browser and `tool/test_all.sh` (VM only) does not pick it up:
//   flutter test test/web/web_identity_write_atomicity_test.dart --platform chrome
@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_management/active_embedding_identity.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

InferenceModelSpec _spec(String name) => InferenceModelSpec(
  name: name,
  modelSource: ModelSource.network('https://x/$name.litertlm'),
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
  });

  tearDown(ServiceRegistry.reset);

  test('awaited activation persists the whole identity', () async {
    // The #468 shape: every web engine builds a FRESH manager per createModel
    // via WebModelSourceResolver.forActiveModel(), which rehydrates from prefs.
    // The old non-awaited activation let a reader in a later microtask catch
    // the identity half-written -- measured, one key of four -- and throw
    // "No active inference model set" over a model that had just installed.
    //
    // Asserted on prefs rather than on `activeInferenceModel`, which also needs
    // the model FILE present; the four identity keys are what the writes own.
    await WebModelManager().activateInstalledModel(_spec('gemma'));

    await WebModelManager().ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(PreferencesKeys.activeInferenceModelType),
      isNotNull,
    );
    expect(prefs.getString(PreferencesKeys.activeInferenceFileType), isNotNull);
    expect(prefs.getString(PreferencesKeys.activeInferenceFilename), isNotNull);
    expect(prefs.getString(PreferencesKeys.activeInferenceSource), isNotNull);
  });

  test('a re-install is never observable half-applied', () async {
    // The variant the issue never reported and the one that is worse: on a
    // switch, prefs hold the previous identity until each key is overwritten.
    // A reader catching the write half-done sees the NEW filename against the
    // OLD source -- a complete, well-formed identity that passes isInstalled,
    // so the engine loads the wrong weights with nothing thrown.
    await WebModelManager().activateInstalledModel(_spec('first'));
    await WebModelManager().ensureInitialized();

    await WebModelManager().activateInstalledModel(_spec('second'));
    await WebModelManager().ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final filename = prefs.getString(PreferencesKeys.activeInferenceFilename);
    final source = prefs.getString(PreferencesKeys.activeInferenceSource);

    // Both keys must describe the SAME model, whichever one won.
    final fromFilename = filename!.contains('second') ? 'second' : 'first';
    final fromSource = source!.contains('second') ? 'second' : 'first';
    expect(
      fromSource,
      fromFilename,
      reason:
          'filename says $fromFilename but source says $fromSource — '
          'that mixed identity is what loads the wrong weights',
    );
  });

  test(
    'explicit embedding identities survive a web restart unchanged',
    () async {
      await ServiceRegistry.initialize();
      final modelSource = NetworkSource('https://x/source-model.tflite');
      final tokenizerSource = NetworkSource('https://x/source-tokenizer.model');
      const modelIdentity = 'weights__rev-abc123.tflite';
      const tokenizerIdentity = 'tokenizer__rev-abc123.model';
      final spec = EmbeddingModelSpec(
        name: 'versioned-embedding',
        modelSource: modelSource,
        tokenizerSource: tokenizerSource,
        modelFilename: modelIdentity,
        tokenizerFilename: tokenizerIdentity,
      );
      final repository = ServiceRegistry.instance.modelRepository;
      for (final file in spec.files) {
        await repository.saveModel(
          repo.ModelInfo(
            id: file.filename,
            source: file.source,
            installedAt: DateTime(2026),
            sizeBytes: 2048,
            type: repo.ModelType.embedding,
            hasLoraWeights: false,
          ),
        );
      }

      final manager = WebModelManager();
      await manager.setActiveEmbeddingModel(spec);

      final prefs = await SharedPreferences.getInstance();
      final persisted = ActiveEmbeddingIdentityRecord.tryDecode(
        prefs.getString(PreferencesKeys.activeEmbeddingIdentityRecord),
      );
      expect(persisted, isNotNull);
      expect(persisted!.modelFilenameExplicit, isTrue);
      expect(persisted.tokenizerFilenameExplicit, isTrue);

      final freshManager = WebModelManager();
      await freshManager.ensureInitialized();

      final restored = freshManager.activeEmbeddingModel as EmbeddingModelSpec;
      expect(restored.modelFilename, modelIdentity);
      expect(restored.tokenizerFilename, tokenizerIdentity);
      expect(restored.files.map((file) => file.filename), [
        modelIdentity,
        tokenizerIdentity,
      ]);
      expect(await repository.isInstalled(tokenizerIdentity), isTrue);
      expect(
        await repository.isInstalled(
          'weights__rev-abc123__tokenizer__rev-abc123.model',
        ),
        isFalse,
      );
    },
  );

  test(
    'delayed older web persistence cannot overwrite a rapid switch',
    () async {
      final persistence = _DelayedEmbeddingIdentityPersistence();
      final firstManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final secondManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final first = _embeddingSpec('first');
      final second = _embeddingSpec('second');

      final firstWrite = firstManager.setActiveEmbeddingModel(first);
      await persistence.firstWriteStarted.future;
      final secondWrite = secondManager.setActiveEmbeddingModel(second);
      persistence.releaseFirstWrite.complete();
      await Future.wait([firstWrite, secondWrite]);

      final persisted = ActiveEmbeddingIdentityRecord.tryDecode(
        persistence.encodedRecord,
      );
      expect(persisted!.name, 'second');
      expect(firstManager.activeEmbeddingModel, isNull);
      expect(secondManager.activeEmbeddingModel, second);
    },
  );

  test(
    'throwing atomic write reloads cache and poisons every web manager',
    () async {
      final backing = _EmbeddingIdentityPersistenceBacking();
      final persistence = _ScriptedEmbeddingIdentityPersistence(
        backing,
        failureMode: _EmbeddingIdentityWriteFailure.throwAfterCacheMutation,
      );
      final firstManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final secondManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );

      final firstFailure = expectLater(
        firstManager.setActiveEmbeddingModel(_embeddingSpec('throwing')),
        throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
      );
      await persistence.reloadCompleted.future;
      await firstFailure;

      expect(firstManager.activeEmbeddingModel, isNull);
      expect(secondManager.activeEmbeddingModel, isNull);
      expect(backing.cachedRecord, backing.durableRecord);
      await expectLater(
        secondManager.setActiveEmbeddingModel(
          _embeddingSpec('blocked-after-throw'),
        ),
        throwsA(
          isA<ActiveEmbeddingIdentityPersistenceException>()
              .having(
                (error) => error.writeFailure,
                'writeFailure',
                isA<StateError>(),
              )
              .having((error) => error.reloadFailure, 'reloadFailure', isNull),
        ),
      );

      final freshPersistence = _ScriptedEmbeddingIdentityPersistence(backing);
      expect(
        (await ActiveEmbeddingIdentityCoordinator.shared(
          freshPersistence,
        ).readLease()).encodedRecord,
        isNull,
      );
    },
  );

  for (final failureMode in _EmbeddingIdentityWriteFailure.values) {
    test('superseded durable A plus ${failureMode.name} B fails closed on web '
        'and a fresh coordinator restores only A', () async {
      final backing = _EmbeddingIdentityPersistenceBacking();
      final persistence = _ScriptedEmbeddingIdentityPersistence(
        backing,
        delayFirstSuccess: true,
        failureMode: failureMode,
      );
      final firstManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final secondManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final first = _embeddingSpec('durable-a-${failureMode.name}');
      final second = _embeddingSpec('failed-b-${failureMode.name}');

      final firstWrite = firstManager.setActiveEmbeddingModel(first);
      await persistence.firstWriteStarted.future;
      final failedSecond = secondManager.setActiveEmbeddingModel(second);
      persistence.releaseFirstWrite.complete();
      await expectLater(
        failedSecond,
        throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
      );
      await firstWrite;

      expect(firstManager.activeEmbeddingModel, isNull);
      expect(secondManager.activeEmbeddingModel, isNull);
      expect(backing.cachedRecord, backing.durableRecord);
      final durable = ActiveEmbeddingIdentityRecord.tryDecode(
        backing.durableRecord,
      );
      expect(durable, isNotNull);
      expect(durable!.name, first.name);
      await expectLater(
        firstManager.setActiveEmbeddingModel(
          _embeddingSpec('rejected-after-${failureMode.name}'),
        ),
        throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
      );

      await ServiceRegistry.initialize(
        modelRepository: _AlwaysInstalledModelRepository(),
      );
      final freshManager = WebModelManager(
        activeEmbeddingIdentityPersistence:
            _ScriptedEmbeddingIdentityPersistence(backing),
      );
      await freshManager.initialize();
      expect(freshManager.activeEmbeddingModel?.name, first.name);
    });
  }

  test('suspended web restore cannot publish after concurrent clear', () async {
    final oldSpec = _embeddingSpec('restore-old');
    final persistence = _MemoryEmbeddingIdentityPersistence()
      ..encodedRecord = ActiveEmbeddingIdentityRecord.fromSpec(
        oldSpec,
      ).encode();
    final repository = _SuspendingModelRepository();
    await ServiceRegistry.initialize(modelRepository: repository);
    final restoringManager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );
    final clearingManager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );

    final restoring = restoringManager.initialize();
    await repository.firstInstallCheckStarted.future;
    final clearing = clearingManager.clearActiveEmbeddingIdentity();
    repository.releaseFirstInstallCheck.complete();
    await Future.wait([restoring, clearing]);

    expect(restoringManager.activeEmbeddingModel, isNull);
    expect(clearingManager.activeEmbeddingModel, isNull);
    expect(
      ActiveEmbeddingIdentityRecord.tryDecode(
        persistence.encodedRecord,
      )!.active,
      isFalse,
    );
  });

  test('suspended web restore cannot publish over concurrent switch', () async {
    final oldSpec = _embeddingSpec('restore-old-switch');
    final newSpec = _embeddingSpec('restore-new-switch');
    final persistence = _MemoryEmbeddingIdentityPersistence()
      ..encodedRecord = ActiveEmbeddingIdentityRecord.fromSpec(
        oldSpec,
      ).encode();
    final repository = _SuspendingModelRepository();
    await ServiceRegistry.initialize(modelRepository: repository);
    final restoringManager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );
    final switchingManager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );

    final restoring = restoringManager.initialize();
    await repository.firstInstallCheckStarted.future;
    await switchingManager.setActiveEmbeddingModel(newSpec);
    expect(switchingManager.activeEmbeddingModel, same(newSpec));
    repository.releaseFirstInstallCheck.complete();
    await restoring;
    await pumpEventQueue();

    expect(restoringManager.activeEmbeddingModel, isNull);
    expect(switchingManager.activeEmbeddingModel, same(newSpec));
  });

  test(
    'present malformed or future web record fails closed over legacy',
    () async {
      await ServiceRegistry.initialize();
      final spec = _embeddingSpec('legacy');
      final repository = ServiceRegistry.instance.modelRepository;
      for (final file in spec.files) {
        await repository.saveModel(
          repo.ModelInfo(
            id: file.filename,
            source: file.source,
            installedAt: DateTime(2026),
            sizeBytes: 2048,
            type: repo.ModelType.embedding,
            hasLoraWeights: false,
          ),
        );
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeEmbeddingFilename,
        spec.files[0].filename,
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerFilename,
        spec.files[1].filename,
      );
      await prefs.setBool(
        PreferencesKeys.activeEmbeddingModelFilenameExplicit,
        true,
      );
      await prefs.setBool(
        PreferencesKeys.activeEmbeddingTokenizerFilenameExplicit,
        true,
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingSource,
        spec.modelSource.encode(),
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerSource,
        spec.tokenizerSource.encode(),
      );

      for (final atomicRecord in <String>[
        '{"schemaVersion":1,"active":true,"name":"partial"}',
        '{"schemaVersion":2,"active":false}',
      ]) {
        await prefs.setString(
          PreferencesKeys.activeEmbeddingIdentityRecord,
          atomicRecord,
        );
        final freshManager = WebModelManager();
        await freshManager.ensureInitialized();
        expect(
          freshManager.activeEmbeddingModel,
          isNull,
          reason: 'atomic record $atomicRecord must block legacy restore',
        );
      }
    },
  );

  test(
    'a delayed old web manager cannot resurrect identity after clear',
    () async {
      final persistence = _DelayedEmbeddingIdentityPersistence();
      final oldManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final clearingManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );

      final oldWrite = oldManager.setActiveEmbeddingModel(
        _embeddingSpec('old'),
      );
      await persistence.firstWriteStarted.future;
      final clear = clearingManager.clearActiveEmbeddingIdentity();
      persistence.releaseFirstWrite.complete();
      await Future.wait([oldWrite, clear]);

      final persisted = ActiveEmbeddingIdentityRecord.tryDecode(
        persistence.encodedRecord,
      );
      expect(persisted, isNotNull);
      expect(persisted!.active, isFalse);
      expect(oldManager.activeEmbeddingModel, isNull);
      expect(clearingManager.activeEmbeddingModel, isNull);
    },
  );

  test('committed web clear invalidates another manager active spec', () async {
    await ServiceRegistry.initialize();
    final persistence = _MemoryEmbeddingIdentityPersistence();
    final activeManager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );
    final clearingManager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );
    final first = _embeddingSpec('active-cross-manager');

    await activeManager.setActiveEmbeddingModel(first);
    expect(activeManager.activeEmbeddingModel, first);
    await clearingManager.clearActiveEmbeddingIdentity();

    expect(activeManager.activeEmbeddingModel, isNull);
    expect(clearingManager.activeEmbeddingModel, isNull);
  });

  test(
    'committed web activation invalidates another manager stale spec',
    () async {
      final persistence = _MemoryEmbeddingIdentityPersistence();
      final firstManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final secondManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final first = _embeddingSpec('first-active');
      final second = _embeddingSpec('second-active');

      await firstManager.setActiveEmbeddingModel(first);
      await secondManager.setActiveEmbeddingModel(second);

      expect(firstManager.activeEmbeddingModel, isNull);
      expect(secondManager.activeEmbeddingModel, second);
    },
  );

  test('a rejected web atomic write does not activate the embedder', () async {
    final persistence = _RejectedEmbeddingIdentityPersistence();
    final manager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );
    await expectLater(
      manager.setActiveEmbeddingModel(_embeddingSpec('rejected')),
      throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
    );
    expect(manager.activeEmbeddingModel, isNull);
    expect(persistence.reloadCount, 1);
    final secondManager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );
    await secondManager.ensureInitialized();
    expect(secondManager.activeEmbeddingModel, isNull);
    expect(persistence.cachedRecord, isNull);
  });

  test(
    'web reload failure poisons shared persistence and fails closed',
    () async {
      final persistence = _RejectedEmbeddingIdentityPersistence(
        reloadFails: true,
      );
      final firstManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final secondManager = WebModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );

      await expectLater(
        firstManager.setActiveEmbeddingModel(_embeddingSpec('poison-first')),
        throwsA(
          isA<ActiveEmbeddingIdentityPersistenceException>()
              .having(
                (error) => error.writeFailure,
                'writeFailure',
                isA<StateError>(),
              )
              .having(
                (error) => error.reloadFailure,
                'reloadFailure',
                isA<StateError>(),
              ),
        ),
      );
      await secondManager.ensureInitialized();
      expect(secondManager.activeEmbeddingModel, isNull);
      await expectLater(
        secondManager.setActiveEmbeddingModel(_embeddingSpec('poison-second')),
        throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
      );
      expect(persistence.writeCount, 1);
      expect(persistence.reloadCount, 1);
    },
  );

  test('web deleteModel deletes storage without clearing identity', () async {
    final spec = _embeddingSpec('web-storage-only-delete');
    final repository = _TrackingModelRepository();
    await ServiceRegistry.initialize(modelRepository: repository);
    final persistence = _MemoryEmbeddingIdentityPersistence()
      ..encodedRecord = ActiveEmbeddingIdentityRecord.fromSpec(spec).encode();
    final manager = WebModelManager(
      activeEmbeddingIdentityPersistence: persistence,
    );
    await manager.initialize();
    expect(manager.activeEmbeddingModel, isNotNull);

    await manager.deleteModel(spec);

    expect(repository.deletedIds, [
      spec.files[0].filename,
      spec.files[1].filename,
    ]);
    expect(persistence.writeCount, 0);
    expect(manager.activeEmbeddingModel, isNotNull);
  });

  test('cleared record blocks stale legacy keys from restoring', () async {
    await ServiceRegistry.initialize();
    final spec = _embeddingSpec('active');
    final manager = WebModelManager();
    await manager.setActiveEmbeddingModel(spec);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      PreferencesKeys.activeEmbeddingFilename,
      spec.files[0].filename,
    );
    await prefs.setString(
      PreferencesKeys.activeEmbeddingTokenizerFilename,
      spec.files[1].filename,
    );
    await prefs.setString(
      PreferencesKeys.activeEmbeddingSource,
      spec.modelSource.encode(),
    );
    await prefs.setString(
      PreferencesKeys.activeEmbeddingTokenizerSource,
      spec.tokenizerSource.encode(),
    );

    await manager.clearActiveEmbeddingIdentity();

    final cleared = ActiveEmbeddingIdentityRecord.tryDecode(
      prefs.getString(PreferencesKeys.activeEmbeddingIdentityRecord),
    );
    expect(cleared, isNotNull);
    expect(cleared!.active, isFalse);
    final freshManager = WebModelManager();
    await freshManager.ensureInitialized();
    expect(freshManager.activeEmbeddingModel, isNull);
  });
}

EmbeddingModelSpec _embeddingSpec(String name) => EmbeddingModelSpec(
  name: name,
  modelSource: NetworkSource('https://x/$name.tflite'),
  tokenizerSource: NetworkSource('https://x/$name-tokenizer.model'),
  modelFilename: '${name}__rev-1.tflite',
  tokenizerFilename: '$name-tokenizer__rev-1.model',
);

class _DelayedEmbeddingIdentityPersistence
    implements ActiveEmbeddingIdentityPersistence {
  final firstWriteStarted = Completer<void>();
  final releaseFirstWrite = Completer<void>();
  String? encodedRecord;
  int _writeCount = 0;

  @override
  Future<String?> read() async => encodedRecord;

  @override
  Future<void> reload() async {}

  @override
  Future<bool> write(String encodedRecord) async {
    if (_writeCount++ == 0) {
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
    }
    this.encodedRecord = encodedRecord;
    return true;
  }
}

class _RejectedEmbeddingIdentityPersistence
    implements ActiveEmbeddingIdentityPersistence {
  _RejectedEmbeddingIdentityPersistence({this.reloadFails = false});

  final bool reloadFails;
  String? cachedRecord;
  int writeCount = 0;
  int reloadCount = 0;
  final reloadCompleted = Completer<void>();

  @override
  Future<String?> read() async => cachedRecord;

  @override
  Future<void> reload() async {
    reloadCount++;
    try {
      if (reloadFails) throw StateError('reload failed');
      cachedRecord = null;
    } finally {
      if (!reloadCompleted.isCompleted) reloadCompleted.complete();
    }
  }

  @override
  Future<bool> write(String encodedRecord) async {
    writeCount++;
    cachedRecord = encodedRecord;
    return false;
  }
}

class _MemoryEmbeddingIdentityPersistence
    implements ActiveEmbeddingIdentityPersistence {
  String? encodedRecord;
  int writeCount = 0;

  @override
  Future<String?> read() async => encodedRecord;

  @override
  Future<void> reload() async {}

  @override
  Future<bool> write(String encodedRecord) async {
    writeCount++;
    this.encodedRecord = encodedRecord;
    return true;
  }
}

enum _EmbeddingIdentityWriteFailure { falseResult, throwAfterCacheMutation }

final class _EmbeddingIdentityPersistenceBacking {
  String? durableRecord;
  String? cachedRecord;
}

final class _ScriptedEmbeddingIdentityPersistence
    implements ActiveEmbeddingIdentityPersistence {
  _ScriptedEmbeddingIdentityPersistence(
    this.backing, {
    this.failureMode,
    this.delayFirstSuccess = false,
  });

  final _EmbeddingIdentityPersistenceBacking backing;
  final _EmbeddingIdentityWriteFailure? failureMode;
  final bool delayFirstSuccess;
  final firstWriteStarted = Completer<void>();
  final releaseFirstWrite = Completer<void>();
  final reloadCompleted = Completer<void>();
  int _writeCount = 0;

  @override
  Future<String?> read() async => backing.cachedRecord;

  @override
  Future<void> reload() async {
    backing.cachedRecord = backing.durableRecord;
    if (!reloadCompleted.isCompleted) reloadCompleted.complete();
  }

  @override
  Future<bool> write(String encodedRecord) async {
    final writeIndex = _writeCount++;
    backing.cachedRecord = encodedRecord;
    if (delayFirstSuccess && writeIndex == 0) {
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
      backing.durableRecord = encodedRecord;
      return true;
    }
    switch (failureMode) {
      case _EmbeddingIdentityWriteFailure.falseResult:
        return false;
      case _EmbeddingIdentityWriteFailure.throwAfterCacheMutation:
        throw StateError('write threw after mutating cache');
      case null:
        backing.durableRecord = encodedRecord;
        return true;
    }
  }
}

class _SuspendingModelRepository implements repo.ModelRepository {
  final firstInstallCheckStarted = Completer<void>();
  final releaseFirstInstallCheck = Completer<void>();
  int _installCheckCount = 0;

  @override
  Future<bool> isInstalled(String id) async {
    if (_installCheckCount++ == 0) {
      firstInstallCheckStarted.complete();
      await releaseFirstInstallCheck.future;
    }
    return true;
  }

  @override
  Future<void> saveModel(repo.ModelInfo info) async {}

  @override
  Future<repo.ModelInfo?> loadModel(String id) async => null;

  @override
  Future<void> deleteModel(String id) async {}

  @override
  Future<List<repo.ModelInfo>> listInstalled() async => const [];
}

final class _AlwaysInstalledModelRepository extends _SuspendingModelRepository {
  @override
  Future<bool> isInstalled(String id) async => true;
}

final class _TrackingModelRepository extends _SuspendingModelRepository {
  final List<String> deletedIds = [];

  @override
  Future<bool> isInstalled(String id) async => true;

  @override
  Future<void> deleteModel(String id) async {
    deletedIds.add(id);
  }
}
