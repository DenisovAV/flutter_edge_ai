// A restore that fails for one kind is printed, so a release build (where
// edgeAiLog is silent) reports it too, and the start goes on without it.

import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
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

  setUp(() async {
    // Debug logging off: what is left is what a release build says.
    edgeAiLogLevel = EdgeAiLogLevel.none;
    root = await Directory.systemTemp.createTemp('fea_restore_print_');
    PathProviderPlatform.instance = _Paths(root.path);
    ServiceRegistry.reset();
  });

  tearDown(() async {
    edgeAiLogLevel = EdgeAiLogLevel.info;
    ServiceRegistry.reset();
    await root.delete(recursive: true);
  });

  test('a restore that throws is printed and the start goes on', () async {
    // Not a string: reading the record throws.
    SharedPreferences.setMockInitialValues({
      PreferencesKeys.activeInferenceIdentity: 5,
    });
    // A manager of its own: the plugin's is initialized once per run.
    final manager = MobileModelManager();
    final printed = <String>[];
    await runZoned(
      () async {
        await ServiceRegistry.initialize();
        await manager.ensureInitialized();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
    expect(manager.activeInferenceModel, isNull);
    expect(
      printed,
      contains(
        startsWith(
          'flutter_edge_ai: the active inference model was not restored',
        ),
      ),
    );
  });

  test('a restore skipped for a missing file is printed', () async {
    SharedPreferences.setMockInitialValues({
      'active_inference_model_type': 'gemma4',
      'active_inference_file_type': 'litertlm',
      'active_inference_filename': 'gone.litertlm',
      'active_inference_source': 'network|https://example.com/gone.litertlm',
    });
    // A manager of its own: the plugin's is initialized once per run.
    final manager = MobileModelManager();
    final printed = <String>[];
    await runZoned(
      () async {
        await ServiceRegistry.initialize();
        await manager.ensureInitialized();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
    expect(
      printed,
      contains(
        allOf(
          startsWith('flutter_edge_ai: '),
          contains('gone.litertlm is not installed or missing'),
        ),
      ),
    );
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
