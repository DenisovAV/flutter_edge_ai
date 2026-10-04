import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/download_page.dart';
import 'package:edge_ai_quickstart/model.dart';
import 'package:edge_ai_quickstart/tools.dart';

void main() {
  // `isModelInstalled` is keyed by file name. `install()` skips bytes it
  // already has, so a name that drifts from its URL does not re-download — it
  // strands the app on a download screen the gate is never satisfied by.
  test('the model id matches the last segment of its URL', () {
    const model = Models.functionGemma;
    expect(model.fileName, model.url.split('/').last, reason: model.label);
  });

  // The declaration is the model's only description of the function, so its
  // shape is part of the app's behaviour and not a comment. A renamed
  // parameter here is a call the app cannot answer.
  test('the tool declares the two arguments the runner reads', () {
    expect(multiplyTool.name, 'multiply');
    final properties =
        multiplyTool.parameters['properties'] as Map<String, dynamic>;
    expect(properties.keys, containsAll(<String>['a', 'b']));
    expect(multiplyTool.parameters['required'], <String>['a', 'b']);
  });

  group('runMultiply answers whatever the model wrote', () {
    // The model is trained to emit arguments as strings, so this is the
    // ordinary case, not the exotic one.
    test('strings', () {
      expect(runMultiply({'a': '1234', 'b': '5678'}), {'result': 7006652});
    });

    test('numbers', () {
      expect(runMultiply({'a': 12, 'b': 13}), {'result': 156});
    });

    // An integer product that arrives as doubles must not be read back to the
    // user as "156.0".
    test('doubles that are whole numbers come back whole', () {
      expect(runMultiply({'a': 12.0, 'b': 13.0}), {'result': 156});
    });

    test('a genuine fraction stays one', () {
      expect(runMultiply({'a': 0.5, 'b': 3}), {'result': 1.5});
    });

    // Returned, not thrown: the model has to be able to read this and try
    // again, and an exception would end the turn instead.
    test('nonsense is an error map, not an exception', () {
      final answer = runMultiply({'a': 'twelve', 'b': 13});
      expect(answer.containsKey('error'), isTrue);
      expect(answer.containsKey('result'), isFalse);
    });
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
