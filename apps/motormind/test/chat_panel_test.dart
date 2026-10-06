import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/app/app.dart';
import 'package:motormind/app/prefs.dart';
import 'package:motormind/features/advisor/stage_view.dart';
import 'package:motormind/features/browser/browser_service.dart';
import 'package:motormind/features/chat/chat_service.dart';
import 'package:motormind/features/search/search_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

/// Scripted driver: calls estimate_payment and present, then narrates using
/// the real computed payment, so the guard passes.
class ScriptedDriver implements ChatDriver {
  final List<String> systemInstructions = [];
  final List<String> prompts = [];

  @override
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall}) async* {
    prompts.add(userText);
    if (userText.contains('just looking') || userText.contains('sports car')) {
      // A plain reply: nothing pending, so the input hint reflects the search.
      yield const DriverText('Take a look around; tap a filter or tell me more.');
      return;
    }
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
  Future<void> cancel() async {}

  @override
  Future<void> close() async {}
}

/// A page reader that returns two listings for any URL, so the live search
/// can be exercised without a webview.
Future<PageExtract> fakeReader(String url) async {
  final now = DateTime(2026, 10, 6);
  return PageExtract(
    url: url,
    title: 'Fake results',
    text: '',
    listings: [
      VehicleListing(
        id: 'f1',
        title: '2021 Honda CR-V EX',
        sourceUrl: url,
        readAt: now,
        price: 27995,
        mileage: 45000,
        year: 2021,
        make: 'Honda',
      ),
      VehicleListing(
        id: 'f2',
        title: '2023 BMW X3',
        sourceUrl: url,
        readAt: now,
        price: 41000,
        mileage: 20000,
        year: 2023,
        make: 'BMW',
      ),
    ],
  );
}

/// The web pane minus the platform webview.
class WebPanePlaceholder extends StatelessWidget {
  const WebPanePlaceholder({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: Key('browser-pane'));
}

Future<Widget> _app(ScriptedDriver driver) async {
  SharedPreferences.setMockInitialValues({
    'disclosures.acknowledgedVersion': Disclosures.gateVersion,
  });
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      turnIdleLimitProvider.overrideWithValue(null),
      webPaneBuilderProvider.overrideWithValue(() => const WebPanePlaceholder()),
      pageReaderProvider.overrideWithValue(fakeReader),
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
  expect(
    container.read(chatServiceProvider).ready,
    isTrue,
    reason: container.read(chatServiceProvider).error,
  );
}

void main() {
  testWidgets('start, ask for a payment, see the card with the computed number', (tester) async {
    final driver = ScriptedDriver();
    await _openFullscreenAdvisor(tester, driver);
    expect(driver.systemInstructions.single, contains('payment_summary'));
    expect(driver.systemInstructions.single, contains('No urgency'));
    // The app opens with the shopping-mode choice before any model turn.
    expect(find.byKey(const Key('choice-mode-practical')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('chat-input')),
      'I can do 450 a month on a 22000 car with 1000 down',
    );
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('card-payment_summary')), findsOneWidget);
    // Cards sit above the narration that comments on them.
    final cardY = tester.getTopLeft(find.byKey(const Key('card-payment_summary'))).dy;
    final replyY = tester.getTopLeft(find.textContaining('a month over 60 months')).dy;
    expect(cardY, lessThan(replyY));
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

  testWidgets('a choice prompt renders options and tapping one sends it; the input is the escape', (
    tester,
  ) async {
    final driver = ScriptedDriver();
    await _openFullscreenAdvisor(tester, driver);
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('chat-input'))),
    );
    // Drive the service directly (the input path is covered above); the
    // scripted driver's stream needs a real event loop, hence runAsync.
    await tester.runAsync(() => container.read(chatServiceProvider.notifier).send('hi'));
    await tester.pumpAndSettle();
    // The opening mode prompt stays live (Q60) and the model's choice joins it.
    expect(find.byKey(const Key('card-choice')), findsNWidgets(2));
    expect(find.byKey(const Key('choice-buying')), findsOneWidget);
    expect(find.byKey(const Key('choice-escape')), findsNothing);
    expect(_hintOf(tester), startsWith('Something else'));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('choice-buying')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(container.read(chatServiceProvider).messages.map((m) => m.text), contains('Buying now'));
  });

  testWidgets('tapping an opening mode chip sets the mode and sends a sentence', (tester) async {
    final driver = ScriptedDriver();
    await _openFullscreenAdvisor(tester, driver);
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('chat-input'))),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('choice-mode-practical')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    final svc = container.read(chatServiceProvider.notifier);
    expect(svc.profile.mode, ShoppingMode.practical);
    expect(container.read(chatServiceProvider).messages.first.text, contains('practical options'));
    // The opening chips are retired, not deleted.
    expect(find.byKey(const Key('choice-mode-practical')), findsNothing);
    expect(find.textContaining('How are you shopping today?'), findsAtLeastNWidgets(1));
  });

  testWidgets('while docked, a presented card lands on the stage above the conversation', (
    tester,
  ) async {
    final driver = ScriptedDriver();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(await _app(driver));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('browser-pane')), findsOneWidget);
    await tester.tap(find.byKey(const Key('surface-bubble')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('chat-start'))),
    );
    await tester.runAsync(() => container.read(chatServiceProvider.notifier).start());
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('choice-mode-practical')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    // The live filters join the conversation; the web pane stays in view.
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-list')),
        matching: find.byKey(const Key('card-search_filters')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('browser-pane')), findsOneWidget);
    await tester.runAsync(
      () => container
          .read(chatServiceProvider.notifier)
          .send('I can do 450 a month on a 22000 car with 1000 down'),
    );
    await tester.pumpAndSettle();
    // The computed card is focused on the stage, not in the conversation.
    final stage = find.byKey(const Key('stage'));
    expect(
      find.descendant(of: stage, matching: find.byKey(const Key('card-payment_summary'))),
      findsOneWidget,
    );
    expect(find.byKey(const Key('browser-pane')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-list')),
        matching: find.byKey(const Key('card-payment_summary')),
      ),
      findsNothing,
    );
  });

  testWidgets('filter chips live in the conversation and apply at once', (tester) async {
    final driver = ScriptedDriver();
    await _openFullscreenAdvisor(tester, driver);
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('chat-input'))),
    );
    expect(find.byKey(const Key('card-search_filters')), findsNothing);
    expect(_hintOf(tester), startsWith('Something else')); // the mode choice is pending
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('choice-mode-browsing')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    // The filters card joins the conversation once a mode is chosen.
    expect(find.byKey(const Key('card-search_filters')), findsOneWidget);
    expect(_hintOf(tester), startsWith('Tell me about'));
    await tester.tap(find.byKey(const Key('price-35000')));
    await tester.pump(const Duration(milliseconds: 600)); // debounce
    await tester.pumpAndSettle();
    expect(container.read(searchProvider).query.maxPrice, 35000);
    expect(_hintOf(tester), startsWith('Tell me more'));
    // The fake page had two listings; one is under 35k.
    expect(container.read(searchProvider).lastCount, 1);
    expect(container.read(listingStoreProvider).all, hasLength(2));
    expect(find.text('1 read'), findsOneWidget);
    // The applied search is a line in the transcript.
    expect(
      find.textContaining('Looking for under \$35k on EchoPark: 1 listings read'),
      findsOneWidget,
    );
    // Site choice sticks: the search re-applies there.
    await tester.tap(find.byKey(const Key('site-autotrader')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(container.read(searchProvider).siteId, 'autotrader');
    expect(find.textContaining('on Autotrader'), findsOneWidget);
    // Typing a description applies obvious filters before the model answers,
    // and the model is told the current search without it showing in the bubble.
    await tester.runAsync(
      () => container.read(chatServiceProvider.notifier).send('a Honda sports car'),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final q = container.read(searchProvider).query;
    expect(q.bodyStyle, 'coupe');
    expect(q.make, 'Honda');
    expect(driver.prompts.last, contains('[Already set on the filter card: '));
    expect(driver.prompts.last, contains('Honda'));
    expect(find.text('a Honda sports car'), findsOneWidget);
    expect(find.textContaining('[Already set'), findsNothing);
  });
}

String _hintOf(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('chat-input'))).decoration!.hintText!;
