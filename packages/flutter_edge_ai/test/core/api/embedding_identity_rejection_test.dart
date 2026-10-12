// A persisted active-embedder record the restore refuses (corrupt, from a
// newer core, or breaking the 2.3 spec rules) still fails closed — but it is
// said, in release builds too, and getActiveEmbedder names the reason instead
// of the false "No active embedding model set".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_edge_ai/src/model_management/active_embedding_identity.dart';
import 'package:flutter_edge_ai/src/model_management/active_identity_store.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A v1 record pairing a .litertlm bundle with a tokenizer: 2.2 could write
/// it, the 2.3 spec rules refuse it.
String _litertlmWithTokenizerRecord() => jsonEncode({
  'schemaVersion': 1,
  'active': true,
  'name': 'eg2',
  'modelSource': ModelSource.network('https://h/eg2.litertlm').encode(),
  'tokenizerSource': ModelSource.network('https://h/t.model').encode(),
  'modelFilename': 'eg2.litertlm',
  'tokenizerFilename': 'eg2__t.model',
  'modelFilenameExplicit': false,
  'tokenizerFilenameExplicit': false,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FlutterEdgeAiPlugin original;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('emb_rejection_');
    PathProviderPlatform.instance = _FixedPathProvider(dir.path);
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    await ServiceRegistry.initialize();
    original = FlutterEdgeAiPlugin.instance;
    resetRejectedActiveEmbeddingIdentity();
  });

  tearDown(() async {
    FlutterEdgeAiPlugin.instance = original;
    ServiceRegistry.reset();
    resetRejectedActiveEmbeddingIdentity();
    await dir.delete(recursive: true);
  });

  group('decode says why it refuses', () {
    test('a .litertlm with a tokenizer', () {
      final result = ActiveEmbeddingIdentityRecord.decode(
        _litertlmWithTokenizerRecord(),
      );
      expect(result.record, isNull);
      expect(result.rejection, contains('carries its own tokenizer'));
    });

    test('a schema this version does not read', () {
      final result = ActiveEmbeddingIdentityRecord.decode(
        '{"schemaVersion":3,"active":true}',
      );
      expect(result.rejection, contains('schema version 3'));
    });

    test('not JSON', () {
      expect(
        ActiveEmbeddingIdentityRecord.decode('{nope').rejection,
        isNotNull,
      );
    });

    test('nothing stored is not a rejection', () {
      final result = ActiveEmbeddingIdentityRecord.decode(null);
      expect(result.record, isNull);
      expect(result.rejection, isNull);
    });
  });

  test('a refused record fails closed, is printed once with its reason, and '
      'getActiveEmbedder says so', () async {
    SharedPreferences.setMockInitialValues({
      PreferencesKeys.activeEmbeddingIdentityRecord:
          _litertlmWithTokenizerRecord(),
    });
    final printed = <String>[];
    final plugin = FlutterEdgeAiMobile();
    await runZoned(
      () async {
        await plugin.modelManager.ensureInitialized();
        // A second manager reading the same record says nothing new.
        await MobileModelManager().ensureInitialized();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    expect(plugin.modelManager.activeEmbeddingModel, isNull);
    final notices = printed.where((l) => l.contains('could not be read'));
    expect(notices, hasLength(1));
    expect(notices.single, contains('carries its own tokenizer'));

    FlutterEdgeAiPlugin.instance = plugin;
    await expectLater(
      FlutterEdgeAi.getActiveEmbedder(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('could not be read'),
            contains('carries its own tokenizer'),
            contains('installEmbedder'),
          ),
        ),
      ),
    );
  });

  test('writing a new identity forgets the old rejection', () async {
    SharedPreferences.setMockInitialValues({
      PreferencesKeys.activeEmbeddingIdentityRecord:
          _litertlmWithTokenizerRecord(),
    });
    final plugin = FlutterEdgeAiMobile();
    await plugin.modelManager.ensureInitialized();
    expect(rejectedActiveEmbeddingIdentity, isNotNull);

    await plugin.modelManager.clearActiveEmbeddingIdentity();
    expect(rejectedActiveEmbeddingIdentity, isNull);
    FlutterEdgeAiPlugin.instance = plugin;
    await expectLater(
      FlutterEdgeAi.getActiveEmbedder(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          isNot(contains('could not be read')),
        ),
      ),
    );
  });

  test('pre-2.3 keys the new rules refuse fail closed without skipping the '
      'restores after it (STT here)', () async {
    SharedPreferences.setMockInitialValues({
      PreferencesKeys.activeEmbeddingFilename: 'eg2.litertlm',
      PreferencesKeys.activeEmbeddingTokenizerFilename: 't.model',
    });
    final prefs = await SharedPreferences.getInstance();
    // The pre-record keys of a .litertlm paired with a tokenizer — which 2.2
    // could install — and an active STT model. Each file as an install
    // leaves it: in core's directory, with its record (restores find files
    // through their records).
    for (final (name, type) in [
      ('eg2.litertlm', repo.ModelType.embedding),
      ('t.model', repo.ModelType.embedding),
      ('whisper.tflite', repo.ModelType.stt),
      ('whisper__tokenizer.json', repo.ModelType.stt),
    ]) {
      File('${dir.path}/$name').writeAsBytesSync(List.filled(4096, 0));
      await ServiceRegistry.instance.modelRepository.saveModel(
        repo.ModelInfo(
          id: name,
          source: ModelSource.network('https://h/$name'),
          installedAt: DateTime.now(),
          sizeBytes: 4096,
          type: type,
          hasLoraWeights: false,
        ),
      );
    }
    await ActiveIdentityStore.write(prefs, ActiveIdentityKind.stt, {
      PreferencesKeys.activeSttFilename: 'whisper.tflite',
      PreferencesKeys.activeSttTokenizerFilename: 'whisper__tokenizer.json',
      PreferencesKeys.activeSttModelType: SttModelType.values.first.name,
    });

    final printed = <String>[];
    final manager = MobileModelManager();
    await runZoned(
      manager.ensureInitialized,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    expect(manager.activeEmbeddingModel, isNull, reason: 'fails closed');
    expect(
      rejectedActiveEmbeddingIdentity,
      contains('carries its own tokenizer'),
    );
    expect(printed.join('\n'), contains('could not be read'));
    expect(
      manager.activeSttModel,
      isNotNull,
      reason: 'the embedding restore must not abort the STT restore',
    );
  });

  test('no record at all keeps the plain message', () async {
    SharedPreferences.setMockInitialValues({});
    final plugin = FlutterEdgeAiMobile();
    await plugin.modelManager.ensureInitialized();
    FlutterEdgeAiPlugin.instance = plugin;
    await expectLater(
      FlutterEdgeAi.getActiveEmbedder(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('No active embedding model set'),
            isNot(contains('could not be read')),
          ),
        ),
      ),
    );
  });
}

final class _FixedPathProvider extends PathProviderPlatform {
  _FixedPathProvider(this._path);

  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;

  @override
  Future<String?> getApplicationSupportPath() async => _path;

  @override
  Future<String?> getTemporaryPath() async => _path;
}
