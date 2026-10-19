import 'package:builtin_ai_codelab/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  Finder button(String label) => find.text(label);

  // ensureReady polls every 200 ms and cancels a stream subscription when it
  // ends, which completes outside the fake clock, so let real time pass. The
  // progress bar never settles, so no pumpAndSettle either.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('starts with the device status card', (tester) async {
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();

    expect(find.text('Device status'), findsOneWidget);
    expect(
      find.text(statusMessage(BuiltInAiAvailability.available)),
      findsOneWidget,
    );
    expect(button('Start built-in AI'), findsOneWidget);
    expect(button('Check again'), findsNothing);
  });

  testWidgets('a download that fails to start is shown and reported', (
    tester,
  ) async {
    host.availability = BuiltInAiAvailability.downloadable;
    host.downloadFeatureError = PlatformException(
      code: 'DOWNLOAD_FAILED',
      message: 'ML Kit refused',
    );
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();

    // The app reports the failure; collect it instead of failing the test.
    final reported = <FlutterErrorDetails>[];
    final onError = FlutterError.onError;
    FlutterError.onError = reported.add;
    await tester.tap(button(prepareLabel));
    await settle(tester);
    FlutterError.onError = onError;

    expect(find.textContaining('ML Kit refused'), findsOneWidget);
    expect(reported, hasLength(1));
    expect(button(prepareLabel), findsOneWidget);
    expect(button('Check again'), findsOneWidget);
  });

  testWidgets('a model that becomes unavailable mid-download shows why', (
    tester,
  ) async {
    host.availability = BuiltInAiAvailability.downloading;
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();

    await tester.tap(button(prepareLabel));
    await tester.pump();
    host.availability = BuiltInAiAvailability.unavailableDisabled;
    await settle(tester);

    expect(
      find.text(statusMessage(BuiltInAiAvailability.unavailableDisabled)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('error')), findsNothing);
    expect(button(prepareLabel), findsNothing);
    expect(button('Check again'), findsOneWidget);
  });

  testWidgets('resuming the app re-checks availability', (tester) async {
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();
    expect(button('Start built-in AI'), findsOneWidget);

    host.availability = BuiltInAiAvailability.unavailableDisabled;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(button('Start built-in AI'), findsNothing);
    expect(button('Check again'), findsOneWidget);
  });
}
