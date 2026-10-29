import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/download_page.dart';
import 'package:edge_ai_quickstart/model.dart';

void main() {
  // `isModelInstalled` is keyed by file name. `install()` skips bytes it
  // already has, so a name that drifts from its URL does not re-download — it
  // strands the app on a download screen the gate is never satisfied by. It is
  // a cheap mistake to make here and an expensive one to carry into Step 3,
  // where the same gate stands in front of 2.59 GB. Checked for both builds
  // directly — `kIsWeb` is false in this VM test, so `model.url`/`model.fileName`
  // alone would never exercise the web pair.
  test(
    'each build of the model is installed under the file its URL fetches',
    () {
      const model = Models.smolVlm2;
      expect(model.nativeFileName, model.nativeUrl.split('/').last);
      expect(model.webFileName, model.webUrl.split('/').last);
    },
  );

  testWidgets('the download screen offers the model before any plugin call', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadPage(model: Models.smolVlm2, onInstalled: () {}),
      ),
    );
    expect(find.text('SmolVLM2 500M'), findsOneWidget);
    expect(find.text('Download model'), findsOneWidget);
  });
}
