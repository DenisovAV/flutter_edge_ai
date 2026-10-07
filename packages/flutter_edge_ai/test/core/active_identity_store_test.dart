import 'dart:io';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/model_management/active_identity_store.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fakeDocuments = await Directory.systemTemp.createTemp('identity_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('identity_support_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    ServiceRegistry.reset();
    await ServiceRegistry.initialize();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    for (final dir in [fakeDocuments, fakeAppSupport]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  /// Puts a model file where the manager looks for [filename].
  Future<void> installFile(String filename) async {
    final path = await ServiceRegistry.instance.fileSystemService
        .getWriteTargetPath(filename);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(List.filled(16, 1));
  }

  group('ActiveIdentityStore', () {
    test('writes every field under one key and drops the old keys', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PreferencesKeys.activeTtsName, 'old');

      await ActiveIdentityStore.write(prefs, ActiveIdentityKind.tts, {
        PreferencesKeys.activeTtsName: 'matcha',
        PreferencesKeys.activeTtsModelType: 'matcha',
      });

      expect(prefs.getString(PreferencesKeys.activeTtsIdentity), isNotNull);
      expect(prefs.getString(PreferencesKeys.activeTtsName), isNull);
      expect(ActiveIdentityStore.read(prefs, ActiveIdentityKind.tts), {
        PreferencesKeys.activeTtsName: 'matcha',
        PreferencesKeys.activeTtsModelType: 'matcha',
      });
    });

    test('the record wins over stale per-field keys', () async {
      SharedPreferences.setMockInitialValues({
        PreferencesKeys.activeTtsIdentity:
            '{"${PreferencesKeys.activeTtsName}":"new"}',
        PreferencesKeys.activeTtsName: 'old',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        ActiveIdentityStore.read(
          prefs,
          ActiveIdentityKind.tts,
        )?[PreferencesKeys.activeTtsName],
        'new',
      );
    });

    test('without a record, reads the keys an older release wrote', () async {
      SharedPreferences.setMockInitialValues({
        PreferencesKeys.activeSttFilename: 'm.tflite',
        PreferencesKeys.activeSttModelType: 'whisper',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(ActiveIdentityStore.read(prefs, ActiveIdentityKind.stt), {
        PreferencesKeys.activeSttFilename: 'm.tflite',
        PreferencesKeys.activeSttModelType: 'whisper',
      });
    });

    test('an unreadable record restores nothing', () async {
      SharedPreferences.setMockInitialValues({
        PreferencesKeys.activeInferenceIdentity: 'not json',
        PreferencesKeys.activeInferenceFilename: 'old.litertlm',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        ActiveIdentityStore.read(prefs, ActiveIdentityKind.inference),
        isNull,
      );
    });

    test('clear removes the record and the old keys', () async {
      SharedPreferences.setMockInitialValues({
        PreferencesKeys.activeSttIdentity: '{}',
        PreferencesKeys.activeSttFilename: 'm.tflite',
      });
      final prefs = await SharedPreferences.getInstance();
      await ActiveIdentityStore.clear(prefs, ActiveIdentityKind.stt);
      expect(prefs.getKeys(), isEmpty);
    });

    test('a failed cleanup of the old keys does not fail the write', () async {
      final prefs = _RemoveFailsPrefs();
      await ActiveIdentityStore.write(prefs, ActiveIdentityKind.tts, {
        PreferencesKeys.activeTtsName: 'matcha',
      });
      expect(
        ActiveIdentityStore.read(
          prefs,
          ActiveIdentityKind.tts,
        )?[PreferencesKeys.activeTtsName],
        'matcha',
      );
    });

    test('clear fails loudly when a removal does not happen', () async {
      final prefs = _RemoveRefusedPrefs();
      await prefs.setString(PreferencesKeys.activeSttIdentity, '{}');
      await expectLater(
        ActiveIdentityStore.clear(prefs, ActiveIdentityKind.stt),
        throwsStateError,
      );
    });

    test(
      'only a tokenizer namespaced by another installed model is foreign',
      () {
        const installed = ['whisper-base', 'moonshine-tiny'];
        bool foreign(String tokenizer) =>
            ActiveIdentityStore.sttTokenizerOfAnotherModel(
              'whisper-base',
              tokenizer,
              installed,
            );
        expect(foreign('whisper-base__tokenizer.json'), isFalse);
        expect(foreign('tokenizer.json'), isFalse);
        expect(foreign('my__tokenizer.json'), isFalse);
        expect(foreign('moonshine-tiny__tokenizer.json'), isTrue);
      },
    );
  });

  group('restore', () {
    test('an STT identity mixed by an older release is not restored', () async {
      // The reported crash shape: the process died between the separate
      // writes, so the model filename is Whisper's and the rest moonshine's.
      await installFile('whisper-base.tflite');
      await installFile('moonshine-tiny__tokenizer.json');
      await ServiceRegistry.instance.modelRepository.saveModel(
        repo.ModelInfo(
          id: 'moonshine-tiny.tflite',
          source: ModelSource.network('https://x/moonshine-tiny.tflite'),
          installedAt: DateTime(2026),
          sizeBytes: 16,
          type: repo.ModelType.stt,
          hasLoraWeights: false,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeSttFilename,
        'whisper-base.tflite',
      );
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerFilename,
        'moonshine-tiny__tokenizer.json',
      );
      await prefs.setString(
        PreferencesKeys.activeSttModelType,
        SttModelType.moonshine.name,
      );

      final manager = MobileModelManager();
      await manager.initialize();

      expect(manager.activeSttModel, isNull);
    });

    test('a consistent STT identity from an older release restores', () async {
      await installFile('whisper-base.tflite');
      await installFile('whisper-base__tokenizer.json');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeSttFilename,
        'whisper-base.tflite',
      );
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerFilename,
        'whisper-base__tokenizer.json',
      );
      await prefs.setString(
        PreferencesKeys.activeSttModelType,
        SttModelType.whisper.name,
      );

      final manager = MobileModelManager();
      await manager.initialize();

      final active = manager.activeSttModel as SttModelSpec?;
      expect(active?.sttModelType, SttModelType.whisper);
    });

    test('a plain tokenizer name containing __ from an older release still '
        'restores', () async {
      await installFile('whisper-base.tflite');
      await installFile('my__tokenizer.json');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeSttFilename,
        'whisper-base.tflite',
      );
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerFilename,
        'my__tokenizer.json',
      );
      await prefs.setString(
        PreferencesKeys.activeSttModelType,
        SttModelType.whisper.name,
      );

      final manager = MobileModelManager();
      await manager.initialize();

      expect(manager.activeSttModel, isNotNull);
    });

    test('an activated STT model survives a restart as one record', () async {
      await installFile('whisper-base.tflite');
      await installFile('whisper-base__tokenizer.json');
      await MobileModelManager().activateInstalledModel(
        SttModelSpec(
          name: 'whisper-base',
          modelSource: ModelSource.network('https://x/whisper-base.tflite'),
          tokenizerSource: ModelSource.network('https://x/tokenizer.json'),
          sttModelType: SttModelType.whisper,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PreferencesKeys.activeSttFilename), isNull);

      final restarted = MobileModelManager();
      await restarted.initialize();

      final active = restarted.activeSttModel as SttModelSpec?;
      expect(active?.sttModelType, SttModelType.whisper);
    });

    test('an inference identity from an older release restores, and the next '
        'activation replaces its keys with one record', () async {
      await installFile('gemma.litertlm');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeInferenceModelType,
        ModelType.gemmaIt.name,
      );
      await prefs.setString(
        PreferencesKeys.activeInferenceFileType,
        ModelFileType.litertlm.name,
      );
      await prefs.setString(
        PreferencesKeys.activeInferenceFilename,
        'gemma.litertlm',
      );

      final manager = MobileModelManager();
      await manager.initialize();
      expect(manager.activeInferenceModel, isNotNull);

      await manager.activateInstalledModel(
        InferenceModelSpec(
          name: 'gemma',
          modelSource: ModelSource.network('https://x/gemma.litertlm'),
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
        ),
      );
      expect(prefs.getString(PreferencesKeys.activeInferenceFilename), isNull);
      expect(
        ActiveIdentityStore.read(
          prefs,
          ActiveIdentityKind.inference,
        )?[PreferencesKeys.activeInferenceFilename],
        'gemma.litertlm',
      );
    });
  });
}

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

/// Preferences whose `remove` always fails, as a platform write can.
class _RemoveFailsPrefs implements SharedPreferences {
  final Map<String, String> _values = {};

  @override
  String? getString(String key) => _values[key];

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async =>
      throw StateError('platform remove failed');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Preferences whose `remove` reports failure without throwing.
class _RemoveRefusedPrefs implements SharedPreferences {
  final Map<String, String> _values = {};

  @override
  String? getString(String key) => _values[key];

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
