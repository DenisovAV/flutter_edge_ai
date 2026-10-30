// A restore that fails for one kind is printed, so a release build (where
// edgeAiLog is silent) reports it too, and the start goes on without it.

import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fea_restore_print_');
    PathProviderPlatform.instance = _Paths(root.path);
    ServiceRegistry.reset();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    await root.delete(recursive: true);
  });

  test('a restore that throws is printed and the start goes on', () async {
    // Not a string: reading the record throws.
    SharedPreferences.setMockInitialValues({
      PreferencesKeys.activeInferenceIdentity: 5,
    });
    final printed = <String>[];
    await runZoned(
      () async {
        await ServiceRegistry.initialize();
        await FlutterEdgeAiPlugin.instance.modelManager.ensureInitialized();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
    expect(
      FlutterEdgeAiPlugin.instance.modelManager.activeInferenceModel,
      isNull,
    );
    expect(
      printed,
      contains(
        startsWith(
          'flutter_edge_ai: the active inference model was not restored',
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
