import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/download_page.dart';
import 'package:edge_ai_quickstart/model.dart';

void main() {
  // `isModelInstalled` is keyed by file name. `install()` skips bytes it
  // already has, so a name that drifts from its URL does not re-download — it
  // strands the app on a download screen the gate is never satisfied by.
  test('the model id matches the last segment of its URL', () {
    const model = Models.functionGemma;
    expect(model.fileName, model.url.split('/').last, reason: model.label);
  });

  testWidgets('the download screen offers the model before any plugin call', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadPage(model: Models.functionGemma, onInstalled: () {}),
      ),
    );
    expect(find.text('FunctionGemma 270M'), findsOneWidget);
    expect(find.text('Download model'), findsOneWidget);
  });
}
