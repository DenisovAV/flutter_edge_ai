import 'package:builtin_ai_codelab/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_local_ai/flutter_local_ai.dart' show debugLocalAiHost;
import 'package:flutter_local_ai/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeLocalAiHost host;

  setUp(() {
    host = FakeLocalAiHost();
    debugLocalAiHost = host;
    addTearDown(() async {
      debugLocalAiHost = null;
      await host.dispose();
    });
  });

  // ensureReady polls every 200 ms and cancels a stream subscription when it
  // ends, which completes outside the fake clock, so let real time pass.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('the card shows what the device answers', (tester) async {
    host.availability = BuiltInAiAvailability.unavailableDisabled;
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();

    expect(
      find.text(statusMessage(BuiltInAiAvailability.unavailableDisabled)),
      findsOneWidget,
    );
    expect(find.text('Check again'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  testWidgets('Prepare waits until the model is ready', (tester) async {
    host.availability = BuiltInAiAvailability.downloading;
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();

    await tester.tap(find.text(prepareLabel));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    host.availability = BuiltInAiAvailability.available;
    await settle(tester);

    expect(
      find.text(statusMessage(BuiltInAiAvailability.available)),
      findsOneWidget,
    );
    expect(find.text(prepareLabel), findsNothing);
    expect(find.text('Check again'), findsNothing);
    expect(find.byKey(const Key('error')), findsNothing);
  });

  testWidgets('a download that does not start says so', (tester) async {
    host.availability = BuiltInAiAvailability.downloadable;
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();

    // What the web reports when Chrome refuses to start without a tap.
    host.downloadFeatureError = BuiltInAiUnavailableException(
      BuiltInAiAvailability.downloadable,
      'NotAllowedError',
    );
    await tester.tap(find.text(prepareLabel));
    await settle(tester);

    expect(
      find.text('The download did not start. Choose Prepare again.'),
      findsOneWidget,
    );
    expect(find.text(prepareLabel), findsOneWidget);
  });
}
