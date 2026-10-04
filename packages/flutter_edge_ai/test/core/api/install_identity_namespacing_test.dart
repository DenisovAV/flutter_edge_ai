// Install-identity namespacing (2026-08-02): end-to-end builder tests
// proving companion files (LoRA, embedding/STT tokenizers, TTS bundle
// members) install under a per-model-namespaced identity, using the exact
// PathProviderPlatform-fixture pattern already established in
// test/core/api/stt_install_plumbing_test.dart.
//
// Run: flutter test test/core/api/install_identity_namespacing_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/active_embedding_identity.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show FlutterEdgeAiMobile, MobileModelManager;

// FileSourceHandler enforces a minimum size per extension (1MB for model
// files, 1KB for small/config extensions like .json) to catch truncated
// downloads — fixtures below must clear both thresholds.
final _fakeModelBytes = Uint8List(1024 * 1024 + 16);
final _fakeCompanionBytes = Uint8List(2048);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;
  late Directory sourceDir;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_docs_',
    );
    fakeAppSupport = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_appsupport_',
    );
    sourceDir = await Directory.systemTemp.createTemp('flutter_edge_ai_src_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    for (final dir in [fakeDocuments, fakeAppSupport, sourceDir]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  group('Task 4: builder namespacing wiring', () {
    test(
      'InferenceInstallationBuilder namespaces the LoRA file by the model',
      () async {
        await ServiceRegistry.initialize();

        final modelFile = File(path.join(sourceDir.path, 'model.bin'));
        await modelFile.writeAsBytes(_fakeModelBytes);
        final loraFile = File(path.join(sourceDir.path, 'lora.bin'));
        // .bin is NOT in FileNameUtils.isSmallFile's list (only .json/.model
        // are) — use the >=1MB fixture, not the 2KB companion one, so this
        // stays correct even if a size-floor check is ever added to this
        // path later.
        await loraFile.writeAsBytes(_fakeModelBytes);

        await FlutterEdgeAi.installModel(
          modelType: ModelType.general,
        ).fromFile(modelFile.path).withLoraFromFile(loraFile.path).install();

        final repository = ServiceRegistry.instance.modelRepository;
        expect(await repository.isInstalled('model.bin'), isTrue);
        expect(await repository.isInstalled('model__lora.bin'), isTrue);
        // The colliding plain key must NOT be the one that got registered.
        expect(await repository.isInstalled('lora.bin'), isFalse);
      },
    );

    test(
      'EmbeddingInstallationBuilder namespaces the tokenizer by the model',
      () async {
        await ServiceRegistry.initialize();

        final modelFile = File(
          path.join(sourceDir.path, 'Gecko_64_quant.tflite'),
        );
        await modelFile.writeAsBytes(_fakeModelBytes);
        final tokenizerFile = File(
          path.join(sourceDir.path, 'sentencepiece.model'),
        );
        await tokenizerFile.writeAsBytes(_fakeCompanionBytes);

        await FlutterEdgeAi.installEmbedder()
            .modelFromFile(modelFile.path)
            .tokenizerFromFile(tokenizerFile.path)
            .install();

        final repository = ServiceRegistry.instance.modelRepository;
        expect(await repository.isInstalled('Gecko_64_quant.tflite'), isTrue);
        expect(
          await repository.isInstalled('Gecko_64_quant__sentencepiece.model'),
          isTrue,
        );
        expect(await repository.isInstalled('sentencepiece.model'), isFalse);
      },
    );

    test(
      'EmbeddingInstallationBuilder honors versioned artifact identities',
      () async {
        await ServiceRegistry.initialize();

        final modelFile = File(path.join(sourceDir.path, 'model.tflite'));
        await modelFile.writeAsBytes(_fakeModelBytes);
        final tokenizerFile = File(
          path.join(sourceDir.path, 'sentencepiece.model'),
        );
        await tokenizerFile.writeAsBytes(_fakeCompanionBytes);

        await FlutterEdgeAi.installEmbedder()
            .modelFromFile(modelFile.path, filename: 'model__rev-abc123.tflite')
            .tokenizerFromFile(
              tokenizerFile.path,
              filename: 'sentencepiece__rev-abc123.model',
            )
            .install();

        final repository = ServiceRegistry.instance.modelRepository;
        expect(
          await repository.isInstalled('model__rev-abc123.tflite'),
          isTrue,
        );
        expect(
          await repository.isInstalled('sentencepiece__rev-abc123.model'),
          isTrue,
        );
        expect(await repository.isInstalled('model.tflite'), isFalse);
        expect(await repository.isInstalled('sentencepiece.model'), isFalse);
      },
    );

    test(
      'explicit embedding identities survive a native restart unchanged',
      () async {
        final fixtureDownload = _FixtureDownloadService(_fakeModelBytes);
        await ServiceRegistry.initialize(downloadService: fixtureDownload);

        const modelIdentity = 'weights__rev-abc123.tflite';
        const tokenizerIdentity = 'tokenizer__rev-abc123.model';
        await FlutterEdgeAi.installEmbedder()
            .modelFromNetwork(
              'https://example.com/model.tflite',
              filename: modelIdentity,
            )
            .tokenizerFromNetwork(
              'https://example.com/sentencepiece.model',
              filename: tokenizerIdentity,
            )
            .install();

        final prefs = await SharedPreferences.getInstance();
        final persisted = ActiveEmbeddingIdentityRecord.tryDecode(
          prefs.getString(PreferencesKeys.activeEmbeddingIdentityRecord),
        );
        expect(persisted, isNotNull);
        expect(persisted!.modelFilenameExplicit, isTrue);
        expect(persisted.tokenizerFilenameExplicit, isTrue);
        expect(persisted.modelFilename, modelIdentity);
        expect(persisted.tokenizerFilename, tokenizerIdentity);
        expect(
          persisted.modelSource,
          ModelSource.network('https://example.com/model.tflite').encode(),
        );
        expect(
          persisted.tokenizerSource,
          ModelSource.network(
            'https://example.com/sentencepiece.model',
          ).encode(),
        );
        expect(
          prefs.getString(PreferencesKeys.activeEmbeddingFilename),
          isNull,
          reason: 'new installs persist one atomic record, not legacy pieces',
        );
        expect(
          prefs.getString(PreferencesKeys.activeEmbeddingTokenizerFilename),
          isNull,
        );

        final freshManager = MobileModelManager();
        await freshManager.initialize();

        final restored = freshManager.activeEmbeddingModel;
        expect(restored, isA<EmbeddingModelSpec>());
        final embeddingSpec = restored! as EmbeddingModelSpec;
        expect(embeddingSpec.modelFilename, modelIdentity);
        expect(embeddingSpec.tokenizerFilename, tokenizerIdentity);
        expect(embeddingSpec.files.map((file) => file.filename), [
          modelIdentity,
          tokenizerIdentity,
        ]);
        final repository = ServiceRegistry.instance.modelRepository;
        expect(await repository.isInstalled(tokenizerIdentity), isTrue);
        expect(
          await repository.isInstalled(
            'weights__rev-abc123__tokenizer__rev-abc123.model',
          ),
          isFalse,
          reason: 'restore must not relabel an explicit tokenizer identity',
        );

        await freshManager.clearActiveEmbeddingIdentity();
        final cleared = ActiveEmbeddingIdentityRecord.tryDecode(
          prefs.getString(PreferencesKeys.activeEmbeddingIdentityRecord),
        );
        expect(cleared, isNotNull);
        expect(cleared!.active, isFalse);
        final afterClear = MobileModelManager();
        await afterClear.initialize();
        expect(afterClear.activeEmbeddingModel, isNull);
      },
    );

    test(
      'delayed older persistence cannot overwrite a rapid model switch',
      () async {
        final persistence = _DelayedEmbeddingIdentityPersistence();
        final firstManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final secondManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final first = EmbeddingModelSpec(
          name: 'first',
          modelSource: NetworkSource('https://example.com/first.tflite'),
          tokenizerSource: NetworkSource(
            'https://example.com/first-tokenizer.model',
          ),
          modelFilename: 'first__rev-1.tflite',
          tokenizerFilename: 'first-tokenizer__rev-1.model',
        );
        final second = EmbeddingModelSpec(
          name: 'second',
          modelSource: NetworkSource('https://example.com/second.tflite'),
          tokenizerSource: NetworkSource(
            'https://example.com/second-tokenizer.model',
          ),
          modelFilename: 'second__rev-2.tflite',
          tokenizerFilename: 'second-tokenizer__rev-2.model',
        );

        final firstWrite = firstManager.setActiveEmbeddingModel(first);
        await persistence.firstWriteStarted.future;
        final secondWrite = secondManager.setActiveEmbeddingModel(second);
        persistence.releaseFirstWrite.complete();
        await Future.wait([firstWrite, secondWrite]);

        final persisted = ActiveEmbeddingIdentityRecord.tryDecode(
          persistence.encodedRecord,
        );
        expect(persisted!.modelFilename, 'second__rev-2.tflite');
        expect(firstManager.activeEmbeddingModel, isNull);
        expect(secondManager.activeEmbeddingModel, second);
      },
    );

    test(
      'throwing atomic write reloads cache and poisons every mobile manager',
      () async {
        final backing = _EmbeddingIdentityPersistenceBacking();
        final persistence = _ScriptedEmbeddingIdentityPersistence(
          backing,
          failureMode: _EmbeddingIdentityWriteFailure.throwAfterCacheMutation,
        );
        final firstManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final secondManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );

        final firstFailure = expectLater(
          firstManager.setActiveEmbeddingModel(
            _embeddingSpecForTest('throwing'),
          ),
          throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
        );
        await persistence.reloadCompleted.future;
        await firstFailure;

        expect(firstManager.activeEmbeddingModel, isNull);
        expect(secondManager.activeEmbeddingModel, isNull);
        expect(backing.cachedRecord, backing.durableRecord);
        await expectLater(
          secondManager.setActiveEmbeddingModel(
            _embeddingSpecForTest('blocked-after-throw'),
          ),
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
                  isNull,
                ),
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
      test('superseded durable A plus ${failureMode.name} B fails closed on '
          'mobile and a fresh coordinator restores only A', () async {
        final backing = _EmbeddingIdentityPersistenceBacking();
        final persistence = _ScriptedEmbeddingIdentityPersistence(
          backing,
          delayFirstSuccess: true,
          failureMode: failureMode,
        );
        final firstManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final secondManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final first = _embeddingSpecForTest('durable-a-${failureMode.name}');
        final second = _embeddingSpecForTest('failed-b-${failureMode.name}');

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
            _embeddingSpecForTest('rejected-after-${failureMode.name}'),
          ),
          throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
        );

        await ServiceRegistry.initialize(
          fileSystemService: _AlwaysExistingFileSystemService(),
        );
        final freshManager = MobileModelManager(
          activeEmbeddingIdentityPersistence:
              _ScriptedEmbeddingIdentityPersistence(backing),
        );
        await freshManager.initialize();
        expect(freshManager.activeEmbeddingModel?.name, first.name);
      });
    }

    test(
      'suspended native restore cannot publish after concurrent clear',
      () async {
        final oldSpec = _embeddingSpecForTest('restore-old');
        final persistence = _MemoryEmbeddingIdentityPersistence()
          ..encodedRecord = ActiveEmbeddingIdentityRecord.fromSpec(
            oldSpec,
          ).encode();
        final fileSystem = _SuspendingFileSystemService();
        await ServiceRegistry.initialize(fileSystemService: fileSystem);
        final restoringManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final clearingManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );

        final restoring = restoringManager.initialize();
        await fileSystem.firstFileCheckStarted.future;
        final clearing = clearingManager.clearActiveEmbeddingIdentity();
        fileSystem.releaseFirstFileCheck.complete();
        await Future.wait([restoring, clearing]);

        expect(restoringManager.activeEmbeddingModel, isNull);
        expect(clearingManager.activeEmbeddingModel, isNull);
        expect(
          ActiveEmbeddingIdentityRecord.tryDecode(
            persistence.encodedRecord,
          )!.active,
          isFalse,
        );
      },
    );

    test(
      'suspended native restore cannot publish over concurrent switch',
      () async {
        final oldSpec = _embeddingSpecForTest('restore-old-switch');
        final newSpec = _embeddingSpecForTest('restore-new-switch');
        final persistence = _MemoryEmbeddingIdentityPersistence()
          ..encodedRecord = ActiveEmbeddingIdentityRecord.fromSpec(
            oldSpec,
          ).encode();
        final fileSystem = _SuspendingFileSystemService();
        await ServiceRegistry.initialize(fileSystemService: fileSystem);
        final restoringManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final switchingManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );

        final restoring = restoringManager.initialize();
        await fileSystem.firstFileCheckStarted.future;
        await switchingManager.setActiveEmbeddingModel(newSpec);
        expect(switchingManager.activeEmbeddingModel, same(newSpec));
        fileSystem.releaseFirstFileCheck.complete();
        await restoring;
        await pumpEventQueue();

        expect(restoringManager.activeEmbeddingModel, isNull);
        expect(switchingManager.activeEmbeddingModel, same(newSpec));
      },
    );

    test(
      'a delayed old manager cannot resurrect identity after another clears',
      () async {
        final persistence = _DelayedEmbeddingIdentityPersistence();
        final oldManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final clearingManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final first = EmbeddingModelSpec(
          name: 'first',
          modelSource: NetworkSource('https://example.com/first.tflite'),
          tokenizerSource: NetworkSource(
            'https://example.com/first-tokenizer.model',
          ),
          modelFilename: 'first__rev-1.tflite',
          tokenizerFilename: 'first-tokenizer__rev-1.model',
        );

        final oldWrite = oldManager.setActiveEmbeddingModel(first);
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

    test('committed clear invalidates another manager active spec', () async {
      await ServiceRegistry.initialize();
      final persistence = _MemoryEmbeddingIdentityPersistence();
      final activeManager = MobileModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final clearingManager = MobileModelManager(
        activeEmbeddingIdentityPersistence: persistence,
      );
      final first = _embeddingSpecForTest('active');

      await activeManager.setActiveEmbeddingModel(first);
      expect(activeManager.activeEmbeddingModel, first);
      await clearingManager.clearActiveEmbeddingIdentity();

      expect(activeManager.activeEmbeddingModel, isNull);
      expect(clearingManager.activeEmbeddingModel, isNull);
    });

    test(
      'uninstallEmbedder persists exactly one clear after a successful delete',
      () async {
        await ServiceRegistry.initialize();
        final spec = _embeddingSpecForTest('uninstall-once');
        final registry = ServiceRegistry.instance;
        final installedPaths = <String>[];
        for (final file in spec.files) {
          final filePath = await registry.fileSystemService.getWriteTargetPath(
            file.filename,
          );
          installedPaths.add(filePath);
          await Directory(path.dirname(filePath)).create(recursive: true);
          await File(filePath).writeAsBytes(
            file.filename.endsWith('.tflite')
                ? _fakeModelBytes
                : _fakeCompanionBytes,
          );
          await registry.modelRepository.saveModel(
            repo.ModelInfo(
              id: file.filename,
              source: file.source,
              installedAt: DateTime(2026),
              sizeBytes: await File(filePath).length(),
              type: repo.ModelType.embedding,
              hasLoraWeights: false,
            ),
          );
        }

        final persistence = _FailOnSecondEmbeddingIdentityWritePersistence(
          ActiveEmbeddingIdentityRecord.fromSpec(spec).encode(),
        );
        final manager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        await manager.initialize();
        expect(manager.activeEmbeddingModel, isNotNull);

        final previousPlugin = FlutterEdgeAiPlugin.instance;
        FlutterEdgeAiPlugin.instance = _ManagerOverrideMobile(manager);
        try {
          await FlutterEdgeAi.uninstallEmbedder();
        } finally {
          FlutterEdgeAiPlugin.instance = previousPlugin;
        }

        expect(
          persistence.writeCount,
          1,
          reason:
              'deleteModel owns the clear; a facade-level second tombstone '
              'would hit the injected failure',
        );
        expect(
          ActiveEmbeddingIdentityRecord.tryDecode(
            persistence.encodedRecord,
          )?.active,
          isFalse,
        );
        expect(manager.activeEmbeddingModel, isNull);
        for (var i = 0; i < spec.files.length; i++) {
          expect(File(installedPaths[i]).existsSync(), isFalse);
          expect(
            await registry.modelRepository.isInstalled(spec.files[i].filename),
            isFalse,
          );
        }
      },
    );

    test(
      'committed activation invalidates another manager stale spec',
      () async {
        final persistence = _MemoryEmbeddingIdentityPersistence();
        final firstManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final secondManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final first = _embeddingSpecForTest('first-active');
        final second = _embeddingSpecForTest('second-active');

        await firstManager.setActiveEmbeddingModel(first);
        await secondManager.setActiveEmbeddingModel(second);

        expect(firstManager.activeEmbeddingModel, isNull);
        expect(secondManager.activeEmbeddingModel, second);
      },
    );

    test(
      'installer fails and does not activate when atomic write is rejected',
      () async {
        final persistence = _RejectedEmbeddingIdentityPersistence();
        final manager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final modelFile = File(path.join(sourceDir.path, 'rejected.tflite'));
        await modelFile.writeAsBytes(_fakeModelBytes);
        final tokenizerFile = File(
          path.join(sourceDir.path, 'rejected-tokenizer.model'),
        );
        await tokenizerFile.writeAsBytes(_fakeCompanionBytes);
        await ServiceRegistry.initialize();
        final previousPlugin = FlutterEdgeAiPlugin.instance;
        FlutterEdgeAiPlugin.instance = _ManagerOverrideMobile(manager);
        try {
          await expectLater(
            FlutterEdgeAi.installEmbedder()
                .modelFromFile(
                  modelFile.path,
                  filename: 'rejected__rev-1.tflite',
                )
                .tokenizerFromFile(
                  tokenizerFile.path,
                  filename: 'rejected-tokenizer__rev-1.model',
                )
                .install(),
            throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
          );
        } finally {
          FlutterEdgeAiPlugin.instance = previousPlugin;
        }

        expect(manager.activeEmbeddingModel, isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(PreferencesKeys.activeEmbeddingIdentityRecord),
          isNull,
        );
        expect(persistence.reloadCount, 1);
        final secondManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        await secondManager.initialize();
        expect(secondManager.activeEmbeddingModel, isNull);
        expect(persistence.cachedRecord, isNull);
      },
    );

    test(
      'reload failure poisons shared persistence and fails closed',
      () async {
        final persistence = _RejectedEmbeddingIdentityPersistence(
          reloadFails: true,
        );
        final firstManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );
        final secondManager = MobileModelManager(
          activeEmbeddingIdentityPersistence: persistence,
        );

        await expectLater(
          firstManager.setActiveEmbeddingModel(_embeddingSpecForTest('first')),
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
        await secondManager.initialize();
        expect(secondManager.activeEmbeddingModel, isNull);
        await expectLater(
          secondManager.setActiveEmbeddingModel(
            _embeddingSpecForTest('second'),
          ),
          throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
        );
        expect(persistence.writeCount, 1);
        expect(persistence.reloadCount, 1);
      },
    );

    test(
      'awaitable activation reports embedding persistence failure',
      () async {
        final manager = MobileModelManager(
          activeEmbeddingIdentityPersistence:
              _RejectedEmbeddingIdentityPersistence(),
        );

        await expectLater(
          manager.setActiveEmbeddingModel(_embeddingSpecForTest('rejected')),
          throwsA(isA<ActiveEmbeddingIdentityPersistenceException>()),
        );
        expect(manager.activeEmbeddingModel, isNull);
      },
    );

    test(
      'identical resolved embedding filenames fail before storage mutation',
      () async {
        final fixtureDownload = _FixtureDownloadService(_fakeModelBytes);
        await ServiceRegistry.initialize(downloadService: fixtureDownload);
        final manager = FlutterEdgeAiPlugin.instance.modelManager;
        final activeBefore = manager.activeEmbeddingModel;
        final storageDir = await ServiceRegistry.instance.fileSystemService
            .getModelStorageDirectory();

        await expectLater(
          FlutterEdgeAi.installEmbedder()
              .modelFromNetwork(
                'https://example.com/model.tflite',
                filename: 'same-artifact.tflite',
              )
              .tokenizerFromNetwork(
                'https://example.com/tokenizer.model',
                filename: 'same-artifact.tflite',
              )
              .install(),
          throwsArgumentError,
        );

        expect(fixtureDownload.requestedTargetPaths, isEmpty);
        expect(
          await ServiceRegistry.instance.modelRepository.listInstalled(),
          isEmpty,
        );
        expect(Directory(storageDir).listSync(), isEmpty);
        expect(manager.activeEmbeddingModel, same(activeBefore));
      },
    );

    test('builder and spec reject non-portable exact filenames', () {
      expect(
        () => FlutterEdgeAi.installEmbedder().modelFromNetwork(
          'https://example.com/model.tflite',
          filename: 'CON.tflite',
        ),
        throwsArgumentError,
      );
      expect(
        () => EmbeddingModelSpec(
          name: 'embedding',
          modelSource: NetworkSource('https://example.com/model.tflite'),
          tokenizerSource: NetworkSource('https://example.com/tokenizer.model'),
          tokenizerFilename: 'bad:name.model',
        ),
        throwsArgumentError,
      );
    });

    test(
      'versioned network identities download beside legacy URL-basename cache',
      () async {
        final fixtureDownload = _FixtureDownloadService(_fakeModelBytes);
        await ServiceRegistry.initialize(downloadService: fixtureDownload);

        const modelUrl = 'https://example.com/model.tflite';
        const tokenizerUrl = 'https://example.com/sentencepiece.model';
        await FlutterEdgeAi.installEmbedder()
            .modelFromNetwork(modelUrl)
            .tokenizerFromNetwork(tokenizerUrl)
            .install();
        await FlutterEdgeAi.installEmbedder()
            .modelFromNetwork(modelUrl, filename: 'model__rev-abc123.tflite')
            .tokenizerFromNetwork(
              tokenizerUrl,
              filename: 'model__sentencepiece__rev-abc123.model',
            )
            .install();

        final repository = ServiceRegistry.instance.modelRepository;
        for (final id in [
          'model.tflite',
          'model__sentencepiece.model',
          'model__rev-abc123.tflite',
          'model__sentencepiece__rev-abc123.model',
        ]) {
          expect(
            await repository.isInstalled(id),
            isTrue,
            reason: '$id must remain independently installed',
          );
        }
        expect(fixtureDownload.requestedTargetPaths, hasLength(4));
      },
    );

    test(
      'SttInstallationBuilder namespaces the tokenizer by the model',
      () async {
        await ServiceRegistry.initialize();

        final modelFile = File(
          path.join(sourceDir.path, 'moonshine_tiny_5s_f32.tflite'),
        );
        await modelFile.writeAsBytes(_fakeModelBytes);
        final tokenizerFile = File(path.join(sourceDir.path, 'tokenizer.json'));
        await tokenizerFile.writeAsBytes(_fakeCompanionBytes);

        await FlutterEdgeAi.installStt()
            .modelFromFile(modelFile.path)
            .tokenizerFromFile(tokenizerFile.path)
            .ofType(SttModelType.moonshine)
            .install();

        final repository = ServiceRegistry.instance.modelRepository;
        expect(
          await repository.isInstalled('moonshine_tiny_5s_f32.tflite'),
          isTrue,
        );
        expect(
          await repository.isInstalled('moonshine_tiny_5s_f32__tokenizer.json'),
          isTrue,
        );
        expect(await repository.isInstalled('tokenizer.json'), isFalse);
      },
    );

    test('TtsInstallationBuilder writes every bundle file under its namespaced '
        'name on disk (not just the isInstalled key)', () async {
      final fixtureDownload = _FixtureDownloadService(_fakeCompanionBytes);
      await ServiceRegistry.initialize(downloadService: fixtureDownload);

      await FlutterEdgeAi.installTts()
          .fromNetwork('https://example.com/matcha/')
          .ofType(TtsModelType.matcha)
          .install();

      final repository = ServiceRegistry.instance.modelRepository;
      expect(
        await repository.isInstalled('matcha__matcha_textenc_fp16.tflite'),
        isTrue,
      );
      expect(await repository.isInstalled('matcha__config.json'), isTrue);
      // Written under the NAMESPACED name in the actual model storage dir —
      // not the plain manifest name (that was the bug this task fixes:
      // before the targetFilename fix, the repository key was namespaced
      // but the physical write stayed on the plain basename). Resolve the
      // storage dir via the same FileSystemService the builder used rather
      // than hardcoding fakeDocuments.path — on desktop hosts (this test
      // typically runs as a native VM test) writes land under
      // ApplicationSupport/flutter_edge_ai/, not Documents; on mobile they
      // land directly under Documents.
      final storageDir = await ServiceRegistry.instance.fileSystemService
          .getModelStorageDirectory();
      expect(
        File(path.join(storageDir, 'matcha__config.json')).existsSync(),
        isTrue,
      );
      expect(File(path.join(storageDir, 'config.json')).existsSync(), isFalse);
    });
  });

  group('Task 5: restore-on-launch reads the namespaced identity', () {
    test(
      'MobileModelManager restores the active TTS model with the correct '
      'namespaced filenames after install (simulating an app relaunch)',
      () async {
        final fixtureDownload = _FixtureDownloadService(_fakeCompanionBytes);
        await ServiceRegistry.initialize(downloadService: fixtureDownload);

        await FlutterEdgeAi.installTts()
            .fromNetwork('https://example.com/matcha/')
            .ofType(TtsModelType.matcha)
            .install();

        // A fresh manager instance has never restored anything yet — this
        // exercises _restoreActiveTtsModel from a cold start, exactly like
        // a real app relaunch.
        final freshManager = MobileModelManager();
        await freshManager.initialize();

        final restored = freshManager.activeTtsModel;
        expect(restored, isNotNull);
        expect(restored!.type, ModelManagementType.tts);
        // The restored spec's OWN .files getter must reproduce the SAME
        // namespaced filenames as install time — no double-prefix
        // (matcha__matcha__config.json) and no missing prefix (config.json).
        final configFile = restored.files.firstWhere(
          (f) => f.prefsKey == 'config.json',
        );
        expect(configFile.filename, 'matcha__config.json');
      },
    );
  });

  group('Task 6 (superseded 2026-08-04, whole-branch review): TTS install-time '
      'adoption REMOVED — a not-yet-installed manifest file is always '
      'downloaded fresh, never adopted from an on-disk plain file, even when '
      'its basename is unique within the TTS catalog. Adoption at install time '
      'could not distinguish "an old flat file this exact model installed '
      "before namespacing shipped\" from \"a same-named file some OTHER "
      "model's catalog (e.g. an STT tokenizer.json) happened to leave "
      'behind" — no size/hash check was available to tell them apart. The '
      'only remaining (safe) adoption path is restore-time, in '
      'MobileModelManager._migrateLegacyCompanionForRestore, which operates on '
      'a single KNOWN active model so the ambiguity cannot occur.', () {
    test('an old flat TTS bundle file at the pre-refactor path is left '
        'untouched — install() downloads the namespaced file fresh instead '
        'of adopting it', () async {
      final fixtureDownload = _FixtureDownloadService(_fakeCompanionBytes);
      await ServiceRegistry.initialize(downloadService: fixtureDownload);

      // Resolve the storage dir via the same FileSystemService the
      // builder uses rather than hardcoding fakeDocuments.path — on
      // desktop hosts (this test typically runs as a native VM test)
      // writes land under ApplicationSupport/flutter_edge_ai/, not
      // Documents; on mobile they land directly under Documents.
      final storageDir = await ServiceRegistry.instance.fileSystemService
          .getModelStorageDirectory();

      // Pre-seed ONE bundle member at its OLD, pre-refactor flat path —
      // simulating a matcha install from before the namespacing refactor
      // shipped. Its basename is unique within the TTS catalog, so
      // pre-fix this WOULD have been adopted.
      final oldPath = path.join(storageDir, 'matcha_textenc_fp16.tflite');
      await File(oldPath).writeAsBytes([7, 7, 7, 7]);

      await FlutterEdgeAi.installTts()
          .fromNetwork('https://example.com/matcha/')
          .ofType(TtsModelType.matcha)
          .install();

      // NOT adopted: the old flat file is left exactly as it was...
      expect(await File(oldPath).readAsBytes(), [7, 7, 7, 7]);
      // ...and the namespaced file was downloaded fresh (fixture bytes),
      // not renamed from the old path (which would carry [7,7,7,7]).
      final newPath = path.join(
        storageDir,
        'matcha__matcha_textenc_fp16.tflite',
      );
      expect(await File(newPath).readAsBytes(), _fakeCompanionBytes);
      expect(
        fixtureDownload.requestedTargetPaths.contains(newPath),
        isTrue,
        reason:
            'a not-yet-installed bundle file must always be '
            'downloaded, never adopted',
      );

      // Every OTHER bundle member (no old file seeded) was also
      // downloaded normally under its namespaced name.
      final otherPath = path.join(storageDir, 'matcha__config.json');
      expect(fixtureDownload.requestedTargetPaths.contains(otherPath), isTrue);

      final repository = ServiceRegistry.instance.modelRepository;
      expect(
        await repository.isInstalled('matcha__matcha_textenc_fp16.tflite'),
        isTrue,
      );
    });

    test('a FOREIGN plain file left by another catalog (e.g. an STT '
        'tokenizer.json) is NEVER adopted into a Qwen3 TTS install — the '
        'exact collision this fix closes', () async {
      final fixtureDownload = _FixtureDownloadService(_fakeCompanionBytes);
      await ServiceRegistry.initialize(downloadService: fixtureDownload);

      final storageDir = await ServiceRegistry.instance.fileSystemService
          .getModelStorageDirectory();

      // Pre-seed a plain `tokenizer.json` at the real storage location —
      // standing in for a leftover Moonshine/Whisper/Parakeet STT
      // tokenizer. Distinct byte content from the qwen3 fixture bytes so
      // adoption-vs-download is unambiguous.
      final foreignPath = path.join(storageDir, 'tokenizer.json');
      await File(foreignPath).writeAsBytes([1, 2, 3, 4, 5]);

      final installation = await FlutterEdgeAi.installTts()
          .fromNetwork(
            'https://huggingface.co/litert-community/'
            'Qwen3-TTS-12Hz-0.6B-Base/resolve/main/',
          )
          .ofType(TtsModelType.qwen3)
          .install();

      // The foreign file is completely untouched.
      expect(await File(foreignPath).readAsBytes(), [1, 2, 3, 4, 5]);

      // qwen3's own tokenizer.json was downloaded fresh under ITS
      // namespaced identity, carrying the fixture bytes — not the
      // foreign file's bytes.
      final qwen3TokenizerPath = path.join(storageDir, 'qwen3__tokenizer.json');
      expect(await File(qwen3TokenizerPath).readAsBytes(), _fakeCompanionBytes);
      expect(
        fixtureDownload.requestedTargetPaths.contains(qwen3TokenizerPath),
        isTrue,
      );

      final repository = ServiceRegistry.instance.modelRepository;
      expect(await repository.isInstalled('qwen3__tokenizer.json'), isTrue);
      // The plain foreign key was never claimed by this install.
      expect(await repository.isInstalled('tokenizer.json'), isFalse);

      // The installed identity is qwen3's, not the foreign file's.
      expect(installation.spec.ttsModelType, TtsModelType.qwen3);
    });
  });

  group('Task 6b: STT install-time collision guard (unaffected by the TTS '
      'adoption removal — STT install() never adopted at all)', () {
    test(
      'a colliding companion (tokenizer) NEVER triggers migration — it always '
      'installs fresh under the namespaced key (the mis-adoption guard)',
      () async {
        await ServiceRegistry.initialize();

        // Pre-seed an old flat tokenizer.json at the REAL storage location
        // (see storageDir note above) — this must be IGNORED, not adopted,
        // because a plain tokenizer.json on disk could belong to ANY
        // previously-installed STT/embedding model.
        final storageDir = await ServiceRegistry.instance.fileSystemService
            .getModelStorageDirectory();
        final oldTokenizerPath = path.join(storageDir, 'tokenizer.json');
        await File(oldTokenizerPath).writeAsBytes([9, 9, 9]);

        final modelFile = File(
          path.join(sourceDir.path, 'moonshine_tiny_5s_f32.tflite'),
        );
        await modelFile.writeAsBytes(_fakeModelBytes);
        final tokenizerFile = File(path.join(sourceDir.path, 'tokenizer.json'));
        await tokenizerFile.writeAsBytes(_fakeCompanionBytes);

        await FlutterEdgeAi.installStt()
            .modelFromFile(modelFile.path)
            .tokenizerFromFile(tokenizerFile.path)
            .ofType(SttModelType.moonshine)
            .install();

        // The stale flat file is untouched — proof no migration/adoption
        // logic ever ran against it.
        expect(await File(oldTokenizerPath).readAsBytes(), [9, 9, 9]);

        final repository = ServiceRegistry.instance.modelRepository;
        expect(
          await repository.isInstalled('moonshine_tiny_5s_f32__tokenizer.json'),
          isTrue,
        );
      },
    );
  });

  group('Task 7: coexistence — the actual bug, end to end', () {
    test('installing moonshine THEN whisper keeps two distinct tokenizer '
        'files + two true isInstalled keys; neither silently reuses the '
        "other's file", () async {
      await ServiceRegistry.initialize();
      final repository = ServiceRegistry.instance.modelRepository;

      final moonshineModel = File(
        path.join(sourceDir.path, 'moonshine_tiny_5s_f32.tflite'),
      );
      await moonshineModel.writeAsBytes(_fakeModelBytes);
      final moonshineTokenizer = File(
        path.join(sourceDir.path, 'moonshine_tokenizer.json'),
      );
      await moonshineTokenizer.writeAsBytes(
        Uint8List.fromList(List.filled(2048, 1)),
      );

      await FlutterEdgeAi.installStt()
          .modelFromFile(moonshineModel.path)
          .tokenizerFromFile(moonshineTokenizer.path)
          .ofType(SttModelType.moonshine)
          .install();

      final whisperDir = await Directory.systemTemp.createTemp(
        'flutter_edge_ai_whisper_src_',
      );
      addTearDown(() => whisperDir.delete(recursive: true));
      final whisperModel = File(
        path.join(whisperDir.path, 'whisper_tiny_30s_f32.tflite'),
      );
      await whisperModel.writeAsBytes(_fakeModelBytes);
      // Both catalogs literally name this file 'tokenizer.json' — see
      // example/lib/models/stt_model.dart.
      final whisperTokenizer = File(
        path.join(whisperDir.path, 'tokenizer.json'),
      );
      await whisperTokenizer.writeAsBytes(
        Uint8List.fromList(List.filled(2048, 2)),
      );

      await FlutterEdgeAi.installStt()
          .modelFromFile(whisperModel.path)
          .tokenizerFromFile(whisperTokenizer.path)
          .ofType(SttModelType.whisper)
          .install();

      expect(
        await repository.isInstalled(
          'moonshine_tiny_5s_f32__moonshine_tokenizer.json',
        ),
        isTrue,
      );
      expect(
        await repository.isInstalled('whisper_tiny_30s_f32__tokenizer.json'),
        isTrue,
      );
    });

    test(
      'installing embeddinggemma THEN Gecko keeps two distinct tokenizer '
      'files despite BOTH being sentencepiece.model AND BOTH '
      'ModelManagementType.embedding (the per-broad-type-would-fail case)',
      () async {
        await ServiceRegistry.initialize();
        final repository = ServiceRegistry.instance.modelRepository;

        final gemmaModel = File(
          path.join(
            sourceDir.path,
            'embeddinggemma-300M_seq1024_mixed-precision.tflite',
          ),
        );
        await gemmaModel.writeAsBytes(_fakeModelBytes);
        final gemmaTokenizer = File(
          path.join(sourceDir.path, 'sentencepiece.model'),
        );
        await gemmaTokenizer.writeAsBytes(
          Uint8List.fromList(List.filled(2048, 3)),
        );

        await FlutterEdgeAi.installEmbedder()
            .modelFromFile(gemmaModel.path)
            .tokenizerFromFile(gemmaTokenizer.path)
            .install();

        final geckoDir = await Directory.systemTemp.createTemp(
          'flutter_edge_ai_gecko_src_',
        );
        addTearDown(() => geckoDir.delete(recursive: true));
        final geckoModel = File(
          path.join(geckoDir.path, 'Gecko_64_quant.tflite'),
        );
        await geckoModel.writeAsBytes(_fakeModelBytes);
        final geckoTokenizer = File(
          path.join(geckoDir.path, 'sentencepiece.model'),
        );
        await geckoTokenizer.writeAsBytes(
          Uint8List.fromList(List.filled(2048, 4)),
        );

        await FlutterEdgeAi.installEmbedder()
            .modelFromFile(geckoModel.path)
            .tokenizerFromFile(geckoTokenizer.path)
            .install();

        expect(
          await repository.isInstalled(
            'embeddinggemma-300M_seq1024_mixed-precision__sentencepiece.model',
          ),
          isTrue,
        );
        expect(
          await repository.isInstalled('Gecko_64_quant__sentencepiece.model'),
          isTrue,
        );
      },
    );
  });

  group('C1 regression: restore-on-launch migrates a pre-refactor plain-named '
      'tokenizer so createStt/Embedding does not break on upgrade', () {
    test('STT: a pre-refactor moonshine install (plain tokenizer.json) is '
        'migrated to the namespaced identity on restore, and the restored '
        'active spec resolves (getModelFilePaths non-null)', () async {
      await ServiceRegistry.initialize();
      final fs = ServiceRegistry.instance.fileSystemService;
      final repository = ServiceRegistry.instance.modelRepository;

      const modelName = 'moonshine_tiny_5s_f32.tflite';
      const plainTokenizer = 'tokenizer.json';
      const namespacedTokenizer = 'moonshine_tiny_5s_f32__tokenizer.json';

      // Seed PRE-REFACTOR on-disk + repo + prefs state: model + tokenizer both
      // written under their PLAIN names, repo keyed PLAIN, active prefs PLAIN —
      // exactly what a pre-namespacing install left behind. The model weight
      // was never namespaced, so only the tokenizer is a migration candidate.
      final modelPath = await fs.getWriteTargetPath(modelName);
      final plainTokenizerPath = await fs.getWriteTargetPath(plainTokenizer);
      await File(modelPath).writeAsBytes(_fakeModelBytes);
      await File(plainTokenizerPath).writeAsBytes(_fakeCompanionBytes);
      await repository.saveModel(
        repo.ModelInfo(
          id: modelName,
          source: ModelSource.file(modelPath),
          installedAt: DateTime(2026),
          sizeBytes: _fakeModelBytes.length,
          type: repo.ModelType.stt,
          hasLoraWeights: false,
        ),
      );
      await repository.saveModel(
        repo.ModelInfo(
          id: plainTokenizer,
          source: ModelSource.file(plainTokenizerPath),
          installedAt: DateTime(2026),
          sizeBytes: _fakeCompanionBytes.length,
          type: repo.ModelType.stt,
          hasLoraWeights: false,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PreferencesKeys.activeSttFilename, modelName);
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerFilename,
        plainTokenizer,
      );
      await prefs.setString(
        PreferencesKeys.activeSttModelType,
        SttModelType.moonshine.name,
      );

      // Cold relaunch: a fresh manager restores + migrates.
      final manager = MobileModelManager();
      await manager.initialize();

      // Repo re-keyed plain -> namespaced (no-clobber, old key removed).
      expect(await repository.isInstalled(namespacedTokenizer), isTrue);
      expect(await repository.isInstalled(plainTokenizer), isFalse);
      // File renamed on disk (adopted, not re-downloaded — bytes preserved).
      final namespacedPath = await fs.getWriteTargetPath(namespacedTokenizer);
      expect(File(namespacedPath).existsSync(), isTrue);
      expect(File(plainTokenizerPath).existsSync(), isFalse);
      // Persisted active filename updated so the next launch is a no-op.
      expect(
        prefs.getString(PreferencesKeys.activeSttTokenizerFilename),
        namespacedTokenizer,
      );

      // THE fix: the restored active model now resolves instead of throwing.
      final active = manager.activeSttModel;
      expect(active, isNotNull);
      final paths = await manager.getModelFilePaths(active!);
      expect(
        paths,
        isNotNull,
        reason:
            'pre-C1 this returned null -> createSttModel threw StateError on '
            'first launch after upgrade',
      );
    });

    test('Embedding: a pre-refactor install (plain sentencepiece.model) is '
        'migrated to the namespaced identity on restore', () async {
      await ServiceRegistry.initialize();
      final fs = ServiceRegistry.instance.fileSystemService;
      final repository = ServiceRegistry.instance.modelRepository;

      const modelName = 'embeddinggemma-300M_seq1024_mixed-precision.tflite';
      const plainTokenizer = 'sentencepiece.model';
      const namespacedTokenizer =
          'embeddinggemma-300M_seq1024_mixed-precision__sentencepiece.model';

      final modelPath = await fs.getWriteTargetPath(modelName);
      final plainTokenizerPath = await fs.getWriteTargetPath(plainTokenizer);
      await File(modelPath).writeAsBytes(_fakeModelBytes);
      await File(plainTokenizerPath).writeAsBytes(_fakeCompanionBytes);
      await repository.saveModel(
        repo.ModelInfo(
          id: modelName,
          source: ModelSource.file(modelPath),
          installedAt: DateTime(2026),
          sizeBytes: _fakeModelBytes.length,
          type: repo.ModelType.embedding,
          hasLoraWeights: false,
        ),
      );
      await repository.saveModel(
        repo.ModelInfo(
          id: plainTokenizer,
          source: ModelSource.file(plainTokenizerPath),
          installedAt: DateTime(2026),
          sizeBytes: _fakeCompanionBytes.length,
          type: repo.ModelType.embedding,
          hasLoraWeights: false,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PreferencesKeys.activeEmbeddingFilename, modelName);
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerFilename,
        plainTokenizer,
      );

      final manager = MobileModelManager();
      await manager.initialize();

      expect(await repository.isInstalled(namespacedTokenizer), isTrue);
      expect(await repository.isInstalled(plainTokenizer), isFalse);
      final active = manager.activeEmbeddingModel;
      expect(active, isNotNull);
      final paths = await manager.getModelFilePaths(active!);
      expect(paths, isNotNull);
      final migratedRecord = ActiveEmbeddingIdentityRecord.tryDecode(
        prefs.getString(PreferencesKeys.activeEmbeddingIdentityRecord),
      );
      expect(migratedRecord, isNotNull);
      expect(migratedRecord!.modelFilename, modelName);
      expect(migratedRecord.tokenizerFilename, namespacedTokenizer);
    });

    test(
      'present malformed or future embedding record fails closed over legacy',
      () async {
        await ServiceRegistry.initialize();
        final fs = ServiceRegistry.instance.fileSystemService;
        const modelName = 'legacy-model.tflite';
        const tokenizerName = 'legacy-tokenizer.model';
        await File(
          await fs.getWriteTargetPath(modelName),
        ).writeAsBytes(_fakeModelBytes);
        await File(
          await fs.getWriteTargetPath(tokenizerName),
        ).writeAsBytes(_fakeCompanionBytes);

        for (final atomicRecord in <String>[
          '{"schemaVersion":1,"active":true,"name":"partial"}',
          '{"schemaVersion":2,"active":false}',
        ]) {
          SharedPreferences.setMockInitialValues(<String, Object>{
            PreferencesKeys.activeEmbeddingIdentityRecord: atomicRecord,
            PreferencesKeys.activeEmbeddingFilename: modelName,
            PreferencesKeys.activeEmbeddingTokenizerFilename: tokenizerName,
            PreferencesKeys.activeEmbeddingModelFilenameExplicit: true,
            PreferencesKeys.activeEmbeddingTokenizerFilenameExplicit: true,
          });

          final manager = MobileModelManager();
          await manager.initialize();
          expect(
            manager.activeEmbeddingModel,
            isNull,
            reason: 'atomic record $atomicRecord must block legacy restore',
          );
        }
      },
    );

    test('idempotent: a post-refactor install (already-namespaced tokenizer) '
        'restores without any migration', () async {
      await ServiceRegistry.initialize();
      final fs = ServiceRegistry.instance.fileSystemService;
      final repository = ServiceRegistry.instance.modelRepository;

      const modelName = 'moonshine_tiny_5s_f32.tflite';
      const namespacedTokenizer = 'moonshine_tiny_5s_f32__tokenizer.json';

      final modelPath = await fs.getWriteTargetPath(modelName);
      final tokenizerPath = await fs.getWriteTargetPath(namespacedTokenizer);
      await File(modelPath).writeAsBytes(_fakeModelBytes);
      await File(tokenizerPath).writeAsBytes(_fakeCompanionBytes);
      await repository.saveModel(
        repo.ModelInfo(
          id: modelName,
          source: ModelSource.file(modelPath),
          installedAt: DateTime(2026),
          sizeBytes: _fakeModelBytes.length,
          type: repo.ModelType.stt,
          hasLoraWeights: false,
        ),
      );
      await repository.saveModel(
        repo.ModelInfo(
          id: namespacedTokenizer,
          source: ModelSource.file(tokenizerPath),
          installedAt: DateTime(2026),
          sizeBytes: _fakeCompanionBytes.length,
          type: repo.ModelType.stt,
          hasLoraWeights: false,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PreferencesKeys.activeSttFilename, modelName);
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerFilename,
        namespacedTokenizer,
      );
      await prefs.setString(
        PreferencesKeys.activeSttModelType,
        SttModelType.moonshine.name,
      );

      final manager = MobileModelManager();
      await manager.initialize();

      // The already-namespaced key survives; no double-prefix key appears.
      expect(await repository.isInstalled(namespacedTokenizer), isTrue);
      expect(
        await repository.isInstalled(
          'moonshine_tiny_5s_f32__moonshine_tiny_5s_f32__tokenizer.json',
        ),
        isFalse,
      );
      expect(File(tokenizerPath).existsSync(), isTrue);
      final paths = await manager.getModelFilePaths(manager.activeSttModel!);
      expect(paths, isNotNull);
    });
  });
}

/// PathProviderPlatform stub that returns fixed, distinct paths for
/// Documents and ApplicationSupport so tests can distinguish them (mirrors
/// test/core/api/stt_install_plumbing_test.dart).
class _FixedPathProviderPlatform extends PathProviderPlatform {
  final String documentsPath;
  final String appSupportPath;

  _FixedPathProviderPlatform({
    required this.documentsPath,
    required this.appSupportPath,
  });

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => appSupportPath;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

/// A real (non-mock) DownloadService fake that writes [bytes] to whatever
/// targetPath it's asked to download to, instead of making a real HTTP
/// request. Tracks every requested target path so tests can assert exactly
/// which files were (re-)downloaded vs adopted via migration (Task 6/7).
class _FixtureDownloadService implements DownloadService {
  final Uint8List bytes;
  final List<String> requestedTargetPaths = [];
  _FixtureDownloadService(this.bytes);

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    requestedTargetPaths.add(targetPath);
    await File(targetPath).writeAsBytes(bytes);
  }

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) async* {
    requestedTargetPaths.add(targetPath);
    await File(targetPath).writeAsBytes(bytes);
    yield 100;
  }
}

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

  @override
  Future<String?> read() async => encodedRecord;

  @override
  Future<void> reload() async {}

  @override
  Future<bool> write(String encodedRecord) async {
    this.encodedRecord = encodedRecord;
    return true;
  }
}

class _FailOnSecondEmbeddingIdentityWritePersistence
    implements ActiveEmbeddingIdentityPersistence {
  _FailOnSecondEmbeddingIdentityWritePersistence(this.encodedRecord);

  String? encodedRecord;
  int writeCount = 0;

  @override
  Future<String?> read() async => encodedRecord;

  @override
  Future<void> reload() async {}

  @override
  Future<bool> write(String encodedRecord) async {
    writeCount++;
    if (writeCount > 1) {
      throw StateError('unexpected second embedding identity write');
    }
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

EmbeddingModelSpec _embeddingSpecForTest(String name) => EmbeddingModelSpec(
  name: name,
  modelSource: NetworkSource('https://example.com/$name.tflite'),
  tokenizerSource: NetworkSource('https://example.com/$name-tokenizer.model'),
  modelFilename: '${name}__rev-1.tflite',
  tokenizerFilename: '$name-tokenizer__rev-1.model',
);

class _SuspendingFileSystemService implements FileSystemService {
  final firstFileCheckStarted = Completer<void>();
  final releaseFirstFileCheck = Completer<void>();
  int _fileCheckCount = 0;

  @override
  Future<bool> fileExists(String path) async {
    if (_fileCheckCount++ == 0) {
      firstFileCheckStarted.complete();
      await releaseFirstFileCheck.future;
    }
    return true;
  }

  @override
  Future<String> getReadTargetPath(String filename) async => '/fake/$filename';

  @override
  Future<String> getWriteTargetPath(String filename) async => '/fake/$filename';

  @override
  Future<String> getTargetPath(String filename) async => '/fake/$filename';

  @override
  Future<void> writeFile(String path, Uint8List data) async {}

  @override
  Future<Uint8List> readFile(String path) async => Uint8List(0);

  @override
  Future<void> deleteFile(String path) async {}

  @override
  Future<int> getFileSize(String path) async => _fakeModelBytes.length;

  @override
  Future<String> getBundledResourcePath(String resourceName) async =>
      '/fake/$resourceName';

  @override
  Future<void> registerExternalFile(
    String filename,
    String externalPath,
  ) async {}

  @override
  Future<String> getModelStorageDirectory() async => '/fake';

  @override
  Future<bool> adoptLegacyFile(String oldFilename, String newFilename) async =>
      false;
}

final class _AlwaysExistingFileSystemService
    extends _SuspendingFileSystemService {
  @override
  Future<bool> fileExists(String path) async => true;
}

final class _ManagerOverrideMobile extends FlutterEdgeAiMobile {
  _ManagerOverrideMobile(this._manager);

  final MobileModelManager _manager;

  @override
  MobileModelManager get modelManager => _manager;
}
