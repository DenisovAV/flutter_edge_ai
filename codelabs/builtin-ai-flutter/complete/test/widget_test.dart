import 'package:builtin_ai_codelab/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  Finder button(String label) => find.text(label);

  bool enabled(WidgetTester tester, String label) {
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    return button.onPressed != null;
  }

  bool composerEnabled(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).enabled ?? true;

  String? shownError() {
    final error = find.byKey(const Key('error'));
    if (error.evaluate().isEmpty) return null;
    return (error.evaluate().single.widget as Text).data;
  }

  // ensureReady polls every 200 ms and cancels a stream subscription when it
  // ends, and core's install reads preferences: both complete outside the fake
  // clock, so let real time pass. The progress bar never settles, so no
  // pumpAndSettle either.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  // Collects what the app reports instead of failing the test.
  List<FlutterErrorDetails> collectReports() {
    final reported = <FlutterErrorDetails>[];
    final onError = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = onError);
    return reported;
  }

  Future<void> startModel(WidgetTester tester) async {
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();
    await tester.tap(button('Start built-in AI'));
    await settle(tester);
    expect(button('Start built-in AI'), findsNothing);
  }

  Future<FakeLocalAiSession> ask(WidgetTester tester) async {
    await tester.tap(button('Ask'));
    await settle(tester);
    return host.sessions.last;
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
    expect(composerEnabled(tester), isFalse);
    expect(enabled(tester, 'Ask'), isFalse);
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

    final reported = collectReports();
    await tester.tap(button(prepareLabel));
    await settle(tester);

    expect(shownError(), contains('ML Kit refused'));
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
    expect(shownError(), startsWith('Preparing stopped'));
    expect(button(prepareLabel), findsNothing);
    expect(button('Check again'), findsOneWidget);
  });

  testWidgets('a prepared model is shown as ready at once', (tester) async {
    host.availability = BuiltInAiAvailability.downloading;
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();

    await tester.tap(button(prepareLabel));
    await tester.pump();
    host.availability = BuiltInAiAvailability.available;
    await settle(tester);

    expect(
      find.text(statusMessage(BuiltInAiAvailability.available)),
      findsOneWidget,
    );
    expect(shownError(), isNull);
    expect(button('Start built-in AI'), findsOneWidget);
  });

  testWidgets('Start opens the model and enables the composer', (tester) async {
    await startModel(tester);

    expect(host.calls, contains('createModel'));
    expect(composerEnabled(tester), isTrue);
    expect(enabled(tester, 'Ask'), isTrue);
    expect(shownError(), isNull);
  });

  testWidgets('Start after the OS began downloading says so', (tester) async {
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump();

    host.availability = BuiltInAiAvailability.downloading;
    await tester.tap(button('Start built-in AI'));
    await settle(tester);

    expect(shownError(), 'Could not start: the model is no longer ready.');
    expect(
      find.text(statusMessage(BuiltInAiAvailability.downloading)),
      findsOneWidget,
    );
    expect(button(prepareLabel), findsOneWidget);
    expect(host.calls, isNot(contains('createModel')));
  });

  testWidgets('Ask streams the answer chunk by chunk and closes the session', (
    tester,
  ) async {
    await startModel(tester);
    final session = await ask(tester);

    expect(session.transcript.toString(), contains('on-device AI'));
    expect(enabled(tester, 'Stop'), isTrue);
    expect(composerEnabled(tester), isFalse);

    host.emitToken(session.id, 'On-device ');
    await tester.pump();
    expect(find.text('On-device '), findsOneWidget);

    host.emitToken(session.id, 'AI runs here.');
    host.emitDone(session.id);
    await settle(tester);

    expect(find.text('On-device AI runs here.'), findsOneWidget);
    expect(session.closed, isTrue);
    expect(enabled(tester, 'Ask'), isTrue);
    expect(shownError(), isNull);
  });

  testWidgets('a failure mid-answer clears the partial answer', (tester) async {
    await startModel(tester);
    final session = await ask(tester);
    final reported = collectReports();

    host.emitToken(session.id, 'Half an ');
    await tester.pump();
    host.emitError(session.id, 'context window full');
    await settle(tester);

    expect(find.byKey(const Key('answer')), findsNothing);
    expect(shownError(), contains('context window full'));
    expect(reported, hasLength(1));
    expect(session.closed, isTrue);
    expect(enabled(tester, 'Ask'), isTrue);
  });

  testWidgets('a session that cannot open is shown', (tester) async {
    await startModel(tester);
    host.createSessionError = PlatformException(
      code: 'BUSY',
      message: 'quota exceeded',
    );
    final reported = collectReports();

    await tester.tap(button('Ask'));
    await settle(tester);

    expect(shownError(), contains('quota exceeded'));
    expect(reported, hasLength(1));
    expect(enabled(tester, 'Ask'), isTrue);
  });

  testWidgets('Stop ends an answer that never finishes', (tester) async {
    await startModel(tester);
    final session = await ask(tester);
    host.emitToken(session.id, 'And then');
    await tester.pump();

    await tester.tap(button('Stop'));
    await settle(tester);

    expect(host.calls, contains('stopGeneration'));
    expect(session.closed, isTrue);
    expect(find.text('And then'), findsOneWidget);
    expect(enabled(tester, 'Ask'), isTrue);
    expect(shownError(), isNull);
  });

  testWidgets('an empty prompt says what to do', (tester) async {
    await startModel(tester);
    await tester.enterText(find.byType(TextField), '   ');

    await tester.tap(button('Ask'));
    await tester.pump();

    expect(shownError(), 'Type a question first.');
    expect(host.calls, isNot(contains('createSession')));
  });

  testWidgets('resuming the app re-checks availability', (tester) async {
    await startModel(tester);
    expect(composerEnabled(tester), isTrue);

    host.availability = BuiltInAiAvailability.unavailableDisabled;
    // Leave for Settings and come back, one valid transition at a time.
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();

    expect(button('Check again'), findsOneWidget);
    expect(composerEnabled(tester), isFalse);
    expect(enabled(tester, 'Ask'), isFalse);
  });
}
