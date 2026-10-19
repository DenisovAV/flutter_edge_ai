import 'package:builtin_ai_codelab/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_local_ai/flutter_local_ai.dart' show debugLocalAiHost;
import 'package:flutter_local_ai/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late FakeLocalAiHost host;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await FlutterEdgeAi.initialize(inferenceEngines: const [BuiltInAiEngine()]);
  });

  setUp(() {
    host = FakeLocalAiHost();
    debugLocalAiHost = host;
    addTearDown(() async {
      debugLocalAiHost = null;
      await host.dispose();
    });
  });

  // Core's install reads preferences outside the fake clock, so let real
  // time pass.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('Start, then Ask shows the answer and closes the session', (
    tester,
  ) async {
    host.response = 'On-device AI runs on this device.';
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    await tester.tap(find.text('Start built-in AI'));
    await settle(tester);
    expect(find.text('Start built-in AI'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);

    await tester.tap(find.text('Ask'));
    await settle(tester);

    expect(find.text('On-device AI runs on this device.'), findsOneWidget);
    expect(host.sessions.single.closed, isTrue);
    expect(find.byKey(const Key('error')), findsNothing);
  });

  testWidgets('an empty answer asks for a rephrase', (tester) async {
    host.response = '';
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();
    await tester.tap(find.text('Start built-in AI'));
    await settle(tester);

    await tester.tap(find.text('Ask'));
    await settle(tester);

    expect(find.textContaining('Rephrase'), findsOneWidget);
  });
}
