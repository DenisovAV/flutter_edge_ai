// The web shell passes supportImage / maxNumImages to the engine and says
// nothing about images itself: whether a web engine takes them is the
// engine's to report, and each one does. Core used to log "Image support is
// not yet implemented for web platform" for every engine, which was wrong for
// MediaPipe `.task`, the path the docs recommend for images on web.
//
// FlutterEdgeAiWeb pulls in dart:js_interop, so this runs in a browser and
// `tool/test_all.sh` (VM only) does not pick it up:
//   flutter test test/web/web_media_log_test.dart --platform chrome
@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/src/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/src/registry/engine_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/web/flutter_edge_ai_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingEngine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    FlutterEdgeAiPlugin.instance = FlutterEdgeAiWeb();
    engine = _RecordingEngine();
    EngineRegistry.instance
      ..reset()
      ..registerAll([engine]);
    final manager =
        FlutterEdgeAiPlugin.instance.modelManager as WebModelManager;
    await manager.ensureInitialized();
    await manager.activateInstalledModel(
      InferenceModelSpec(
        name: 'gemma-4-E2B-it-web',
        modelSource: ModelSource.network('https://x/gemma-4-E2B-it-web.task'),
        modelType: ModelType.gemma4,
        fileType: ModelFileType.task,
      ),
    );
  });

  tearDown(() async {
    await FlutterEdgeAiPlugin.instance.initializedModel?.close();
    EngineRegistry.instance.reset();
    ServiceRegistry.reset();
  });

  test('supportImage and maxNumImages reach the engine, and core logs nothing '
      'about images', () async {
    // Both channels: edgeAiLog goes through debugPrint, and a warning meant
    // for release builds goes through print.
    final logged = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logged.add(message);
    };
    try {
      await runZoned(
        () => FlutterEdgeAi.getActiveModel(
          maxTokens: 4096,
          supportImage: true,
          maxNumImages: 4,
          // Logged on web: proves the capture sees the shell's own lines.
          activationDataType: ActivationDataType.float16,
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => logged.add(line),
        ),
      );
    } finally {
      debugPrint = original;
    }

    expect(engine.configs, hasLength(1));
    expect(engine.configs.single.supportImage, isTrue);
    expect(engine.configs.single.maxNumImages, 4);
    expect(
      logged,
      contains(contains('[FlutterEdgeAiWeb] activationDataType')),
      reason: 'the capture must see what the shell logs',
    );
    expect(
      logged.where(
        (line) => RegExp(
          'image|vision|multimodal',
          caseSensitive: false,
        ).hasMatch(line),
      ),
      isEmpty,
    );
  });
}

class _RecordingEngine implements InferenceEngineProvider {
  final configs = <RuntimeConfig>[];

  @override
  String get name => 'Recording';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) => true;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    configs.add(config);
    return _FakeModel();
  }
}

class _FakeModel with CloseNotifier implements InferenceModel {
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    fireCloseListeners();
  }

  // The shell only calls close(), isClosed and addCloseListener() on the model
  // it caches; anything else should fail loudly.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
