import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/app/app.dart';
import 'package:motormind/app/prefs.dart';
import 'package:motormind/features/advisor/display_agent.dart';
import 'package:motormind/features/advisor/stage.dart';
import 'package:motormind/features/advisor/stage_view.dart';
import 'package:motormind/features/browser/browser_service.dart';
import 'package:motormind/features/chat/chat_panel.dart';
import 'package:motormind/features/chat/chat_service.dart';
import 'package:motormind/features/chat/chat_strings.dart';
import 'package:motormind/features/disclosures/disclosures_notifier.dart';
import 'package:motormind/features/listings/listing_signals.dart';
import 'package:motormind/features/search/search_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

/// A model stand-in. Each branch is one behavior the tests need: a payment
/// turn that calls the real tool and narrates the computed figure (so the
/// guard passes), a plain reply, a choice prompt, and scripted misbehavior.
class ScriptedDriver implements ChatDriver {
  final List<String> systemInstructions = [];
  final List<String> prompts = [];

  /// Completes each time a turn's stream closes, so tests can wait for the
  /// turn instead of sleeping.
  Completer<void> _idle = Completer<void>();
  Future<void> get idle => _idle.future;

  /// Completed by [cancel]; the hanging branch waits on it, so an interrupt
  /// or the watchdog ends the turn the way the real engine would.
  Completer<void> _cancelled = Completer<void>();

  @override
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall}) {
    prompts.add(userText);
    _idle = Completer<void>();
    _cancelled = Completer<void>();
    return _reply(userText, onToolCall).asBroadcastStream()
      ..listen(null, onDone: _idle.complete, onError: (_) => _idle.complete());
  }

  Stream<DriverChunk> _reply(String userText, ToolCallHandler onToolCall) async* {
    if (userText.contains('just looking') || userText.contains('sports car')) {
      yield const DriverText('Take a look around; tap a filter or tell me more.');
    } else if (userText.contains('450')) {
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
    } else if (userText.contains('invent a number')) {
      yield const DriverText('You would pay about \$999 a month for that.');
    } else if (userText.contains('sell me')) {
      yield const DriverText('Act now, this deal will not last and you must buy today!');
    } else if (userText.contains('never answer')) {
      await _cancelled.future; // hangs until cancelled
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
  Future<void> cancel() async {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  @override
  Future<void> close() async {}
}

/// Two listings, so client-side filtering has something to filter. The URL
/// is ignored on purpose: the fake stands in for whatever page the search
/// opened, and the test asserts the app's own filtering.
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

final _crvKey = ListingSignalsNotifier.keyFor({'title': '2021 Honda CR-V EX', 'price': 27995.0});

/// The web pane minus the platform webview.
class WebPanePlaceholder extends StatelessWidget {
  const WebPanePlaceholder({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: Key('browser-pane'));
}

Future<Widget> _app(ScriptedDriver? driver, {Duration? idleLimit}) async {
  SharedPreferences.setMockInitialValues({
    DisclosuresAcknowledgedNotifier.ackKey: Disclosures.gateVersion,
  });
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      turnIdleLimitProvider.overrideWithValue(idleLimit),
      searchDebounceProvider.overrideWithValue(Duration.zero),
      webPaneBuilderProvider.overrideWithValue(() => const WebPanePlaceholder()),
      pageReaderProvider.overrideWithValue(fakeReader),
      if (driver != null)
        chatDriverFactoryProvider.overrideWithValue((instruction) async {
          driver.systemInstructions.add(instruction);
          return driver;
        }),
    ],
    child: const MotormindApp(),
  );
}

typedef Started = ({ScriptedDriver driver, ProviderContainer container});

/// Pumps the app at phone size, opens Motormind (docked, or fullscreen),
/// and starts the conversation with the scripted driver.
Future<Started> _start(WidgetTester tester, {bool fullscreen = true, Duration? idleLimit}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final driver = ScriptedDriver();
  await tester.pumpWidget(await _app(driver, idleLimit: idleLimit));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('surface-bubble')));
  await tester.pumpAndSettle();
  if (fullscreen) {
    await tester.tap(find.byKey(const Key('surface-toggle'))); // docked -> fullscreen
    await tester.pumpAndSettle();
  }
  // start() loads prompt assets (real async I/O), which pumpAndSettle cannot
  // wait for; the same goes for every scripted turn below.
  final container = ProviderScope.containerOf(tester.element(find.byKey(const Key('chat-start'))));
  await tester.runAsync(() => container.read(chatServiceProvider.notifier).start());
  await tester.pumpAndSettle();
  final state = container.read(chatServiceProvider);
  expect(state.ready, isTrue, reason: state.error);
  return (driver: driver, container: container);
}

/// Sends through the service and waits for the whole turn to finish: the
/// driver's stream closing, then the pipeline's guard and present steps.
Future<void> _turn(WidgetTester tester, Started s, Future<void> Function() act) async {
  await tester.runAsync(() async {
    await act();
    await s.driver.idle;
    while (s.container.read(chatServiceProvider).busy) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  await tester.pumpAndSettle();
}

Future<void> _chooseMode(WidgetTester tester, Started s, String mode) =>
    _turn(tester, s, () => tester.tap(find.byKey(Key('choice-mode-$mode'))));

Future<void> _tapFilter(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

String _hintOf(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('chat-input'))).decoration!.hintText!;

void main() {
  group('payment card', () {
    testWidgets('a payment question shows the card with the computed number', (tester) async {
      final s = await _start(tester);
      expect(s.driver.systemInstructions.single, contains('payment_summary'));
      // The app opens with the shopping-mode choice before any model turn.
      expect(find.byKey(const Key('choice-mode-practical')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('chat-input')),
        'I can do 450 a month on a 22000 car with 1000 down',
      );
      await _turn(tester, s, () => tester.tap(find.byKey(const Key('chat-send'))));

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
      final shown = tester.widget<Text>(find.byKey(const Key('out-monthlyPayment'))).data!;
      expect(shown, contains(expected.toStringAsFixed(2).split('.').last));
      expect(find.byKey(const Key('guard-note')), findsNothing);
      expect(find.byKey(const Key('policy-banner')), findsNothing);
    });

    testWidgets('while docked, a presented card lands on the stage above the conversation', (
      tester,
    ) async {
      final s = await _start(tester, fullscreen: false);
      expect(find.byKey(const Key('browser-pane')), findsOneWidget);
      await _chooseMode(tester, s, 'practical');
      // The live filters and the numbers form join the conversation (Q64);
      // the web pane stays in view.
      final chatList = find.byKey(const Key('chat-list'));
      expect(
        find.descendant(of: chatList, matching: find.byKey(const Key('card-search_filters'))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: chatList, matching: find.byKey(const Key('card-input_form'))),
        findsOneWidget,
      );
      expect(find.byKey(const Key('browser-pane')), findsOneWidget);
      await _turn(
        tester,
        s,
        () => s.container
            .read(chatServiceProvider.notifier)
            .send('I can do 450 a month on a 22000 car with 1000 down'),
      );
      // The computed card is focused on the stage, not in the conversation.
      final stage = find.byKey(const Key('stage'));
      expect(
        find.descendant(of: stage, matching: find.byKey(const Key('card-payment_summary'))),
        findsOneWidget,
      );
      expect(find.byKey(const Key('browser-pane')), findsNothing);
      expect(
        find.descendant(of: chatList, matching: find.byKey(const Key('card-payment_summary'))),
        findsNothing,
      );
    });
  });

  group('prompts and the escape', () {
    testWidgets('a choice prompt renders options and tapping one sends it', (tester) async {
      final s = await _start(tester);
      await _turn(tester, s, () => s.container.read(chatServiceProvider.notifier).send('hi'));
      // The opening mode prompt stays live (Q60) and the model's choice joins it.
      expect(find.byKey(const Key('card-choice')), findsNWidgets(2));
      expect(_hintOf(tester), ChatStrings.hintPending);
      await _turn(tester, s, () => tester.tap(find.byKey(const Key('choice-buying'))));
      expect(
        s.container.read(chatServiceProvider).messages.map((m) => m.text),
        contains('Buying now'),
      );
    });

    testWidgets('tapping an opening mode chip sets the mode and sends a sentence', (tester) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'practical');
      expect(s.container.read(chatServiceProvider.notifier).profile.mode, ShoppingMode.practical);
      expect(s.driver.prompts.single, startsWith('I want practical options'));
      expect(find.byKey(const Key('card-search_filters')), findsOneWidget);
    });

    testWidgets('a tap during a turn is refused rather than lost', (tester) async {
      final s = await _start(tester);
      await tester.runAsync(() async {
        // The 'never answer' turn hangs; the chip tap during it must not
        // retire the prompt.
        unawaited(s.container.read(chatServiceProvider.notifier).send('never answer'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await s.container
            .read(chatServiceProvider.notifier)
            .choose('mode-browsing', 'Just looking');
      });
      await tester.pump();
      expect(find.byKey(const Key('choice-mode-browsing')), findsOneWidget);
      expect(s.container.read(chatServiceProvider).busy, isTrue);
      await tester.runAsync(() => s.container.read(chatServiceProvider.notifier).interrupt());
    });
  });

  group('filters card', () {
    testWidgets('dream car says what it did, offers kinds, and a kind chip filters at once', (
      tester,
    ) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'dreaming');
      expect(find.textContaining('No price ceiling for a dream car'), findsOneWidget);
      // The one-time hint that the screen is negotiable (Q64).
      expect(find.textContaining('show, hide or change anything'), findsOneWidget);
      await _turn(tester, s, () => tester.tap(find.byKey(const Key('choice-kind-convertible'))));
      expect(s.container.read(searchProvider).query.bodyStyle, 'convertible');
    });

    testWidgets('chips apply at once and the model is told what is set', (tester) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'browsing');
      expect(_hintOf(tester), ChatStrings.hintDefault);
      await _tapFilter(tester, 'price-35000');
      expect(s.container.read(searchProvider).query.maxPrice, 35000);
      expect(_hintOf(tester), ChatStrings.hintFiltered);
      // The fake page had two listings; one is under 35k (filtered here, not
      // by the fake site).
      expect(s.container.read(searchProvider).lastCount, 1);
      expect(s.container.read(listingStoreProvider).all, hasLength(2));
      expect(find.text('1 matched'), findsOneWidget);
      // Site choice sticks: the search re-applies there.
      await _tapFilter(tester, 'site-autotrader');
      expect(s.container.read(searchProvider).siteId, 'autotrader');
      // Typing a description applies obvious filters before the model answers,
      // and the model is told the current search without it showing in the bubble.
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('a Honda sports car'),
      );
      final q = s.container.read(searchProvider).query;
      expect(q.bodyStyle, 'coupe');
      expect(q.make, 'Honda');
      expect(s.driver.prompts.last, contains('[Already set on the filter card: '));
      expect(s.driver.prompts.last, contains('Honda'));
      expect(find.text('a Honda sports car'), findsOneWidget);
      expect(find.textContaining('[Already set'), findsNothing);
    });

    testWidgets('search notes do not repeat, and the card collapses when docked', (tester) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'browsing');
      await _tapFilter(tester, 'price-35000');
      await _tapFilter(tester, 'price-25000');
      // Two searches in a row leave one note (Q65).
      expect(find.textContaining('Looking for'), findsOneWidget);
      expect(find.textContaining('under \$25k on EchoPark'), findsOneWidget);
      // Fullscreen keeps the full card; docked collapses it to a summary with
      // a funnel, and the notes go out of view.
      expect(find.byKey(const Key('filters-summary')), findsNothing);
      await tester.tap(find.byKey(const Key('surface-toggle'))); // fullscreen -> collapsed
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('surface-bubble')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filters-summary')), findsOneWidget);
      expect(find.textContaining('Looking for'), findsNothing);
      // The person can reopen it, and that choice sticks until a filter changes.
      await tester.tap(find.byKey(const Key('filters-summary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filters-summary')), findsNothing);
      expect(s.container.read(searchProvider).userExpanded, isTrue);
      await _tapFilter(tester, 'body-suv');
      expect(s.container.read(searchProvider).userExpanded, isNull);
      expect(find.byKey(const Key('filters-summary')), findsOneWidget);
    });
  });

  group('cards stage', () {
    testWidgets('a search brings the Cards stage forward with attributed, tappable tiles', (
      tester,
    ) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'browsing');
      expect(find.byKey(const Key('display-indicator')), findsOneWidget);
      expect(s.container.read(displayProvider).by, DecidedBy.rules);
      await _tapFilter(tester, 'body-suv');
      expect(s.container.read(stageProvider).mode, StageMode.cards);
      expect(s.container.read(displayProvider).split, StageSplit.twoThirds);
      await tester.tap(find.byKey(const Key('surface-toggle'))); // fullscreen -> collapsed
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('surface-bubble'))); // -> docked
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('browser-pane')), findsNothing);
      // Every tile names its source and its age.
      expect(find.textContaining('EchoPark · '), findsNWidgets(2));
      // Tapping a tile opens its detail in place and marks it viewed.
      await tester.tap(find.byKey(Key('listing-$_crvKey')));
      await tester.pumpAndSettle();
      expect(find.text('Open on EchoPark'), findsOneWidget);
      expect(s.container.read(listingSignalsProvider).viewed, hasLength(1));
      await tester.tap(find.byKey(Key('like-$_crvKey')));
      await tester.pumpAndSettle();
      expect(s.container.read(listingSignalsProvider).liked, hasLength(1));
      // "Not this one" hides the tile.
      await tester.tap(find.text('Not this one'));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('listing-$_crvKey')), findsNothing);
      // The person's flip to Web wins over the decision.
      await tester.tap(
        find.descendant(of: find.byKey(const Key('stage-mode')), matching: find.text('Web')),
      );
      await tester.pumpAndSettle();
      expect(s.container.read(stageProvider).mode, StageMode.web);
      expect(find.byKey(const Key('browser-pane')), findsOneWidget);
    });
  });

  group('guards and failures', () {
    testWidgets('a number the model invented is replaced and noted', (tester) async {
      final s = await _start(tester);
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('invent a number'),
      );
      expect(find.byKey(const Key('guard-note')), findsOneWidget);
      expect(find.textContaining('\$999'), findsNothing);
    });

    testWidgets('sales language raises a banner the person can dismiss', (tester) async {
      final s = await _start(tester);
      await _turn(tester, s, () => s.container.read(chatServiceProvider.notifier).send('sell me'));
      expect(find.byKey(const Key('policy-banner')), findsOneWidget);
      await tester.tap(find.byKey(const Key('policy-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('policy-banner')), findsNothing);
    });

    testWidgets('the idle watchdog stops a silent turn and says so', (tester) async {
      final s = await _start(tester, idleLimit: const Duration(milliseconds: 30));
      await tester.runAsync(() async {
        await s.container.read(chatServiceProvider.notifier).send('never answer');
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Stopped: Motormind went'), findsOneWidget);
      expect(s.container.read(chatServiceProvider).busy, isFalse);
    });

    testWidgets('without a model, starting explains what to do', (tester) async {
      await tester.pumpWidget(await _app(null));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('surface-bubble')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('chat-start'))),
      );
      await tester.runAsync(() => container.read(chatServiceProvider.notifier).start());
      await tester.pumpAndSettle();
      expect(find.text(ChatStrings.noModel), findsOneWidget);
    });
  });

  group('plain text', () {
    test('markdown markers and escaped dollars are stripped', () {
      expect(plainText(r'**Bold** and \$430'), r'Bold and $430');
      expect(plainText('- one\n- two'), '• one\n• two');
    });
  });
}
