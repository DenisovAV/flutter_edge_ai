// A request without an active embedder must not claim that all backends
// ignore GPU. Notices now follow provider selection in the shared loader.

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/desktop/flutter_edge_ai_desktop.dart';
import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> printed;
  late DebugPrintCallback original;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetEmbedderBackendNotice();
    printed = <String>[];
    original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };
  });

  tearDown(() => debugPrint = original);

  Iterable<String> notices() =>
      printed.where((l) => l.contains('preferredBackend'));

  /// One call, no prior embedder — the shape an app actually uses.
  Future<void> firstCall(FlutterEdgeAiPlugin plugin) async {
    await expectLater(
      plugin.createEmbeddingModel(preferredBackend: PreferredBackend.gpu),
      throwsStateError,
    );
  }

  group('no backend is claimed before an active provider is resolved', () {
    test('mobile', () async {
      await firstCall(FlutterEdgeAiMobile());
      expect(
        notices(),
        isEmpty,
        reason: 'without a model no accelerator has been chosen',
      );
    });

    test('desktop', () async {
      await firstCall(FlutterEdgeAiDesktop.instance);
      expect(notices(), isEmpty);
    });
  });

  test('a backend that embeddings DO use stays quiet', () async {
    await expectLater(
      FlutterEdgeAiMobile().createEmbeddingModel(
        preferredBackend: PreferredBackend.cpu,
      ),
      throwsStateError,
    );
    expect(notices(), isEmpty);
  });
}
