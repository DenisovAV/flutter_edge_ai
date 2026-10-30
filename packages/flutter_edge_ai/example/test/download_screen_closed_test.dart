// The download screen, popped while a catalog install runs: when the install
// then fails, the screen is gone, so it must not touch its context (that
// throws on an unmounted State); the failure, "already uninstalled"
// included, is logged instead.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/model_download_screen.dart';
import 'package:flutter_edge_ai_example/models/model.dart';
import 'package:flutter_edge_ai_example/services/catalog_install.dart';
import 'package:flutter_edge_ai_example/services/model_download_service.dart';
import 'package:flutter_edge_ai_example/universal_download_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// A service whose download waits for [result], and asks to replace a model
/// first when [askFirst] is set.
class _BlockedService extends ModelDownloadService {
  _BlockedService({this.askFirst = false})
    : super(
        modelUrl: 'https://example.com/m.task',
        modelFilename: 'm.task',
        licenseUrl: '',
        modelType: ModelType.gemma4,
      );

  final bool askFirst;
  final result = Completer<CatalogInstallResult>();

  /// When set, the token load waits for it.
  Completer<String?>? token;
  final asked = <bool>[];
  final started = Completer<void>();

  @override
  Future<String?> loadToken() async => token?.future;

  @override
  Future<bool> checkModelExistence(String token) async => false;

  @override
  Future<CatalogInstallResult> downloadModel({
    required String token,
    required Function(double) onProgress,
    required Future<bool> Function(ActiveModelInTheWay model, int bytes)
    confirmReplace,
  }) async {
    started.complete();
    final answer = await result.future;
    if (askFirst) {
      asked.add(
        await confirmReplace(
          ActiveModelInTheWay.of(
            StateError(
              'This install would write x over the file the active embedding '
              'model emb reads, and checks it only afterwards. Uninstall that '
              'model first (FlutterEdgeAi.uninstallEmbedder()), or install '
              'under another file name.',
            ),
          )!,
          1,
        ),
      );
    }
    return answer;
  }
}

void main() {
  /// What [body] says through `debugPrint`; restored before the test ends,
  /// which testWidgets checks.
  Future<List<String>> saying(Future<void> Function() body) async {
    final said = <String>[];
    final sink = debugPrint;
    debugPrint = (message, {wrapWidth}) => said.add(message ?? '');
    try {
      await body();
    } finally {
      debugPrint = sink;
    }
    return said;
  }

  /// The two download screens, each with the service the test drives.
  final screens = <String, Widget Function(_BlockedService)>{
    'ModelDownloadScreen': (service) => ModelDownloadScreen(
      model: Model.gemma4_E2B_web,
      downloadService: service,
    ),
    'UniversalDownloadScreen': (service) => UniversalDownloadScreen(
      model: Model.gemma4_E2B_web,
      inferenceDownloadService: service,
    ),
  };

  /// Opens [screen] over a home route, starts the download, and pops it.
  Future<void> openStartAndPop(
    WidgetTester tester,
    _BlockedService service,
    Widget Function(_BlockedService) screen,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => screen(service)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pump();
    await service.started.future;
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('Download'), findsNothing);
  }

  for (final MapEntry(key: name, value: screen) in screens.entries) {
    testWidgets('$name: a failure after the screen is gone is logged, not '
        'thrown', (tester) async {
      final service = _BlockedService();
      final said = await saying(() async {
        await openStartAndPop(tester, service, screen);
        service.result.completeError(
          const CatalogReplaceFailed(
            'emb was already uninstalled, but x did not',
          ),
        );
        await tester.pumpAndSettle();
      });
      expect(tester.takeException(), isNull);
      expect(
        said,
        contains(
          allOf(
            startsWith('Model install failed: '),
            contains('emb was already uninstalled'),
          ),
        ),
      );
    });

    testWidgets('$name: a screen already gone asks nobody, and keeps the old '
        'model', (tester) async {
      final service = _BlockedService(askFirst: true);
      await openStartAndPop(tester, service, screen);
      service.result.complete(const CatalogInstalled());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(service.asked, [false]);
    });
  }

  testWidgets('UniversalDownloadScreen: a token that loads after the screen '
      'is gone is not written to its disposed field', (tester) async {
    final service = _BlockedService()..token = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => screens['UniversalDownloadScreen']!(service),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    service.token!.complete('hf_token');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
