import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/app/app.dart';
import 'package:motormind/app/prefs.dart';
import 'package:motormind/features/chat/chat_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

/// Scripted driver: calls estimate_payment and present, then narrates using
/// the real computed payment, so the guard passes.
class ScriptedDriver implements ChatDriver {
  final List<String> systemInstructions = [];

  @override
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall}) async* {
    if (userText.contains('450')) {
      final r = await onToolCall('estimate_payment', {
        'price': 22000,
        'term_months': 60,
        'credit_band': 'good',
        'down_payment': 1000,
      });
      await onToolCall('present', {
        'component': 'payment_summary',
        'result_id': r['result_id'],
        'highlights': ['monthlyPayment'],
      });
      final p = ((r['outputs'] as Map)['monthlyPayment'] as num).toStringAsFixed(2);
      yield DriverText('That comes to \$$p a month over 60 months.');
    } else {
      await onToolCall('present', {
        'component': 'choice',
        'props': {
          'question': 'How are you shopping today?',
          'options': [
            {'id': 'browsing', 'label': 'Just looking'},
            {'id': 'buying', 'label': 'Buying now'},
          ],
        },
      });
      yield const DriverText('Happy to help.');
    }
  }

  @override
  Future<void> updateSystemInstruction(String instruction) async {}

  @override
  Future<void> close() async {}
}

Future<Widget> _app(ScriptedDriver driver) async {
  SharedPreferences.setMockInitialValues({
    'disclosures.acknowledgedVersion': Disclosures.gateVersion,
  });
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      chatDriverFactoryProvider.overrideWithValue((instruction) async {
        driver.systemInstructions.add(instruction);
        return driver;
      }),
    ],
    child: const MotormindApp(),
  );
}

Future<void> _openFullscreenAdvisor(WidgetTester tester, ScriptedDriver driver) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(await _app(driver));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('surface-bubble')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('surface-toggle'))); // docked -> fullscreen
  await tester.pumpAndSettle();
  // start() loads prompt assets (real async I/O), which pumpAndSettle cannot wait for.
  final container = ProviderScope.containerOf(tester.element(find.byKey(const Key('chat-start'))));
  await tester.runAsync(() => container.read(chatServiceProvider.notifier).start());
  await tester.pumpAndSettle();
  expect(container.read(chatServiceProvider).ready, isTrue);
}

void main() {
  testWidgets('start, ask for a payment, see the card with the computed number', (tester) async {
    final driver = ScriptedDriver();
    await _openFullscreenAdvisor(tester, driver);
    expect(driver.systemInstructions.single, contains('payment_summary'));
    expect(driver.systemInstructions.single, contains('Never urge'));

    await tester.enterText(find.byKey(const Key('chat-input')), 'I can do 450 a month');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('card-payment_summary')), findsOneWidget);
    final expected = monthlyPayment(
      principal: 20000,
      apr: defaultAprTable.aprFor(CreditBand.good, isNew: false),
      termMonths: 60,
    );
    final shownPayment = tester.widget<Text>(find.byKey(const Key('out-monthlyPayment'))).data!;
    expect(shownPayment, contains(expected.toStringAsFixed(2).split('.').last));
    expect(find.textContaining('a month over 60 months'), findsOneWidget);
    expect(find.byKey(const Key('guard-note')), findsNothing);
    expect(find.byKey(const Key('policy-banner')), findsNothing);
  });

  testWidgets('a choice prompt renders options plus the escape, and tapping one sends it', (
    tester,
  ) async {
    final driver = ScriptedDriver();
    await tester.pumpWidget(await _app(driver));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('surface-bubble')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-start')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-input')), 'hi');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('card-choice')), findsOneWidget);
    expect(find.byKey(const Key('choice-escape')), findsOneWidget);
    await tester.tap(find.byKey(const Key('choice-buying')));
    await tester.pumpAndSettle();
    expect(find.text('Buying now'), findsWidgets);
  });
}
