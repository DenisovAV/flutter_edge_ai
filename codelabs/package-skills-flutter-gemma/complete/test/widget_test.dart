import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_skills/download_page.dart';
import 'package:edge_ai_skills/model.dart';

void main() {
  // `isModelInstalled` is keyed by the file name. A name that drifts from its
  // URL does not re-download — it strands the app on the download screen.
  test(
    'each build of the model is installed under the file its URL fetches',
    () {
      const model = Models.gemma4;
      expect(model.nativeFileName, model.nativeUrl.split('/').last);
      expect(model.webFileName, model.webUrl.split('/').last);
    },
  );

  testWidgets('the download screen offers the model before any plugin call', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadPage(model: Models.gemma4, onInstalled: () {}),
      ),
    );
    expect(find.text('Gemma 4 E2B'), findsOneWidget);
    expect(find.text('Download model'), findsOneWidget);
  });
}
