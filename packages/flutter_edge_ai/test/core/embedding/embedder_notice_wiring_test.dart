// Pins the WIRING of noticeEmbedderBackendIgnored, which the unit tests for the
// notice itself cannot see.
//
// Why each shell is driven DIRECTLY instead of through `FlutterEdgeAi
// .getActiveEmbedder`: on a desktop test host `FlutterEdgeAiPlugin.instance`
// resolves to the desktop shell, and desktop was the one shell that already
// called the notice on its create path. A test that went through the facade
// would have been green while mobile and web stayed silent on the first — and
// usually only — call an app makes.
//
// Each case asks for an embedder with no active identity, so the call throws.
// That is deliberate: the notice must fire BEFORE anything else in
// createEmbeddingModel, so the throw proves nothing about the notice and the
// captured output proves everything.
//
// How the shells compare, reuse and rebuild embedders is in
// embedder_shell_test.dart.
//
// Run: flutter test test/core/embedding/embedder_notice_wiring_test.dart

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

  group('the notice reaches the first call, not only a reuse', () {
    test('mobile', () async {
      await firstCall(FlutterEdgeAiMobile());
      expect(
        notices(),
        hasLength(1),
        reason:
            'a single getActiveEmbedder(preferredBackend:) is the ordinary '
            'shape; if it only speaks on the second call it never speaks',
      );
    });

    test('desktop', () async {
      await firstCall(FlutterEdgeAiDesktop.instance);
      expect(notices(), hasLength(1));
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
