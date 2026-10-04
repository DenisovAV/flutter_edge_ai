import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/download_page.dart';
import 'package:edge_ai_quickstart/model.dart';

void main() {
  test('every downloaded model id matches the last segment of its URL', () {
    for (final model in [Models.gemma3, Models.gemma4, Models.gemma4Web]) {
      expect(model.id, model.url!.split('/').last, reason: model.label);
    }
  });

  // `flutter test` pins `defaultTargetPlatform` to android (Flutter's own
  // `_platform_io.dart` does that whenever FLUTTER_TEST is set), so this only
  // ever exercises the Gemini Nano arm; the Apple and UnsupportedError arms of
  // `Models.builtIn` are covered by running the app, not by this suite.
  test('the built-in model has no file and routes to the built-in engine', () {
    final m = Models.builtIn;
    expect(m.url, isNull);
    expect(m.fileType, ModelFileType.builtIn);
    expect(m.isBuiltIn, isTrue);
  });

  testWidgets('the setup screen names the model before any plugin call', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadPage(
          model: Models.gemma4,
          onReady: () {},
          onSwitch: (_) {},
        ),
      ),
    );
    expect(find.text('Gemma 4 E2B'), findsOneWidget);
    expect(find.text('Download model'), findsOneWidget);
  });
}
