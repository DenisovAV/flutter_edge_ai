import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/download_page.dart';
import 'package:edge_ai_quickstart/model.dart';
import 'package:edge_ai_quickstart/tools.dart';

void main() {
  // `isModelInstalled` is keyed by file name. `install()` skips bytes it
  // already has, so a name that drifts from its URL does not re-download — it
  // strands the app on a download screen the gate is never satisfied by. At
  // 2.59 GB that is not a small mistake.
  test('every downloadable model id matches the last segment of its URL', () {
    for (final model in Models.downloadable) {
      expect(model.fileName, model.url!.split('/').last, reason: model.label);
    }
  });

  // The two halves of the toolbox are the two things that can drift apart: a
  // declaration with no runner is a call the app answers with an error
  // forever, and a runner with no declaration is code the model is never told
  // about.
  test('every declared tool has a runner, and no runner is undeclared', () {
    expect(
      toolbox.map((t) => t.name).toSet(),
      toolRunners.keys.toSet(),
      reason: 'toolbox and toolRunners must name the same tools',
    );
  });

  // The declaration is the model's only description of a function, so its
  // shape is part of the app's behaviour and not a comment.
  test('multiply declares the two arguments its runner reads', () {
    final properties =
        multiplyTool.parameters['properties'] as Map<String, dynamic>;
    expect(properties.keys, containsAll(<String>['a', 'b']));
    expect(multiplyTool.parameters['required'], <String>['a', 'b']);
  });

  group('change_background_color', () {
    test('a colour in the list repaints and names itself back', () {
      final result = runChangeBackground({'color': 'blue'});
      expect(result['color'], 'blue');
      expect(backgroundFrom(result), backgroundColors['blue']);
    });

    // The model writes prose, not enum values. "Blue" and " blue " are the
    // same request, and a tool that rejects them teaches the model nothing.
    test('case and spacing are the model writing English', () {
      expect(runChangeBackground({'color': ' Blue '})['color'], 'blue');
    });

    // The one the base model actually produces: ask for teal and it calls with
    // teal. The answer has to say which colours exist, or the model apologises
    // for a failure it cannot explain.
    test('an unavailable colour comes back with the list', () {
      final result = runChangeBackground({'color': 'teal'});
      expect(result['error'], contains('teal'));
      expect(result['error'], contains('purple'));
      expect(backgroundFrom(result), isNull);
    });

    test('a result from another tool paints nothing', () {
      expect(backgroundFrom(runClock({})), isNull);
      expect(backgroundFrom(runMultiply({'a': 2, 'b': 3})), isNull);
    });
  });

  test('the no-argument tools declare a type and no properties', () {
    for (final tool in [clockTool, deviceTool]) {
      expect(tool.parameters['type'], 'object', reason: tool.name);
      expect(
        tool.parameters.containsKey('properties'),
        isFalse,
        reason: tool.name,
      );
    }
  });

  group('runMultiply answers whatever the model wrote', () {
    // The runtime's tool path hands numbers over as doubles, but a call read
    // back from text — the web arm, or an artifact exported without the
    // function_gemma model type — still arrives with string arguments.
    test('strings', () {
      expect(runMultiply({'a': '1234', 'b': '5678'}), {'result': 7006652});
    });

    test('numbers', () {
      expect(runMultiply({'a': 47, 'b': 89}), {'result': 4183});
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

  test('an undeclared name is answered, not thrown', () {
    final answer = runTool(
      const FunctionCallResponse(name: 'launch_rocket', args: {}),
    );
    expect(answer['error'], contains('launch_rocket'));
  });

  test('the clock answers in a shape a person can check', () {
    final now = runClock(const {});
    expect(now['time'], matches(RegExp(r'^\d{2}:\d{2}$')));
    expect(now['date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(DateTime.parse(now['iso8601'] as String), isA<DateTime>());
  });

  group('ModelChoice', () {
    // The whole point of Step 4: what comes out of `litetune convert` is a
    // `.litertlm` like any other, and the only thing that differs is where the
    // bytes are.
    test('a model from disk carries a path and no URL', () {
      final tuned = ModelChoice.fromDisk('/tmp/artifacts/my-model.litertlm');
      expect(tuned.path, '/tmp/artifacts/my-model.litertlm');
      expect(tuned.url, isNull);
      // The id is the basename, because that is what the install registers it
      // under and what `isModelInstalled` will be asked about later.
      expect(tuned.fileName, 'my-model.litertlm');
    });

    test('a downloadable model carries a URL and no path', () {
      expect(Models.gemma4.path, isNull);
      expect(Models.gemma4.url, isNotNull);
    });

    // The two capabilities the chat reads before it offers a control.
    test('only Gemma 4 reasons out loud', () {
      expect(Models.gemma4.supportsThinking, isTrue);
      expect(Models.functionGemma.supportsThinking, isFalse);
    });

    // Neither, and that is the point of recording it per checkpoint rather
    // than assuming the larger model can do more. FunctionGemma's prompt
    // format cannot express "you must call"; Gemma 4's declarations reach the
    // runtime as `tools_json`, which carries no `tool_choice` at all. A model
    // whose format did express it would set this true — none here does.
    test('neither model can be forced to call a tool', () {
      expect(Models.gemma4.supportsRequiredToolChoice, isFalse);
      expect(Models.functionGemma.supportsRequiredToolChoice, isFalse);
    });
  });

  testWidgets('the install screen offers the model before any plugin call', (
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

  testWidgets('a model from disk is offered as a file, not a download', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadPage(
          model: ModelChoice.fromDisk('/tmp/artifacts/my-model.litertlm'),
          onInstalled: () {},
        ),
      ),
    );
    expect(find.text('Open it'), findsOneWidget);
    expect(find.text('Download model'), findsNothing);
  });
}
