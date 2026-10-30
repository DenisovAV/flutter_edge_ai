// A restore that fails or is skipped for one kind is said through the log
// sink (debugPrint, which release builds keep, unlike edgeAiLog), the start
// goes on without it, and EdgeAiLogLevel.none silences it.
//
// That release builds keep it cannot be seen here: `flutter test` always
// runs in debug mode, so a `kDebugMode` gate on restoreNotice would stay
// open in every test. Only a release build can show it.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart'
    show MobileModelManager;
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late List<String> said;
  final sink = debugPrint;

  setUp(() async {
    said = [];
    debugPrint = (message, {wrapWidth}) => said.add(message ?? '');
    root = await Directory.systemTemp.createTemp('fea_restore_notice_');
    PathProviderPlatform.instance = _Paths(root.path);
    ServiceRegistry.reset();
  });

  tearDown(() async {
    debugPrint = sink;
    edgeAiLogLevel = EdgeAiLogLevel.info;
    ServiceRegistry.reset();
    await root.delete(recursive: true);
  });

  /// A start with a manager of its own (the plugin's starts once per run).
  Future<MobileModelManager> start() async {
    final manager = MobileModelManager();
    await ServiceRegistry.initialize();
    await manager.ensureInitialized();
    return manager;
  }

  /// An active inference model whose file is not installed.
  final missing = {
    PreferencesKeys.activeInferenceModelType: 'gemma4',
    PreferencesKeys.activeInferenceFileType: 'litertlm',
    PreferencesKeys.activeInferenceFilename: 'gone.litertlm',
    PreferencesKeys.activeInferenceSource:
        'network|https://example.com/gone.litertlm',
  };

  test('a restore that throws is said, and the start goes on', () async {
    // Not a string: reading the record throws.
    SharedPreferences.setMockInitialValues({
      PreferencesKeys.activeInferenceIdentity: 5,
    });
    final manager = await start();
    expect(manager.activeInferenceModel, isNull);
    expect(
      said,
      contains(
        startsWith(
          'flutter_edge_ai: the active inference model was not restored',
        ),
      ),
    );
  });

  test('a restore skipped for a missing file is said', () async {
    SharedPreferences.setMockInitialValues(missing);
    await start();
    expect(
      said,
      contains(
        allOf(
          startsWith('flutter_edge_ai: '),
          contains('gone.litertlm is not installed or missing'),
        ),
      ),
    );
  });

  test('EdgeAiLogLevel.none silences it', () async {
    edgeAiLogLevel = EdgeAiLogLevel.none;
    SharedPreferences.setMockInitialValues(missing);
    await start();
    expect(said, isEmpty);
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}
