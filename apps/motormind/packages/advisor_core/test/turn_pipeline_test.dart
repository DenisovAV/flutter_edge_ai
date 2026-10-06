import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

/// A scripted model: each `send` plays one script entry, which may call tools
/// (by name and args) and then emit text. The text may be a function of the
/// tool results so tests can produce correct or invented numbers.
class FakeDriver implements ChatDriver {
  FakeDriver(this.script);

  final List<FakeTurn> script;
  final List<String> sent = [];
  int _i = 0;

  @override
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall}) async* {
    sent.add(userText);
    final turn = script[_i < script.length ? _i : script.length - 1];
    _i++;
    final replies = <Map<String, Object?>>[];
    for (final call in turn.calls) {
      replies.add(await onToolCall(call.$1, call.$2));
    }
    for (final token in turn.text(replies).split(' ')) {
      yield DriverText('$token ');
    }
  }

  @override
  Future<void> updateSystemInstruction(String instruction) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> close() async {}
}

class FakeTurn {
  FakeTurn({this.calls = const [], required this.text});
  final List<(String, Map<String, Object?>)> calls;
  final String Function(List<Map<String, Object?>> toolReplies) text;
}

double _payment(Map<String, Object?> reply) =>
    ((reply['outputs'] as Map)['monthlyPayment'] as num).toDouble();

void main() {
  test('a finance call flows tool → present → narration with verified numbers', () async {
    final driver = FakeDriver([
      FakeTurn(
        calls: [
          (
            'update_profile',
            {'payment_ceiling': 450, 'credit_band': 'good', 'shopping_mode': 'practical'},
          ),
          (
            'estimate_payment',
            {'price': 22000, 'term_months': 60, 'credit_band': 'good', 'down_payment': 1000},
          ),
          (
            'present',
            {
              'component': 'payment_summary',
              'result_id': 'r1',
              'highlights': ['monthlyPayment'],
            },
          ),
        ],
        text: (r) => 'At 60 months that is about \$${_payment(r[1]).toStringAsFixed(0)} a month.',
      ),
    ]);
    var n = 0;
    final pipeline = TurnPipeline(
      driver: driver,
      finance: FinanceToolHandlers(nextId: () => 'r${++n}'),
    );
    final events = await pipeline
        .run('I can do 450 a month, good credit, looking at a 22k car with 1000 down')
        .toList();

    expect(events.whereType<ToolStarted>().map((e) => e.name), [
      'update_profile',
      'estimate_payment',
      'present',
    ]);
    expect(events.whereType<ProfileUpdated>().single.profile.mode, ShoppingMode.practical);
    final presented = events.whereType<Presented>().toList();
    expect(presented.map((p) => p.automatic), [true, false]);
    expect(presented.last.request.component.id, 'payment_summary');
    expect(presented.last.result!.id, 'r1');
    expect(presented.last.request.highlights, ['monthlyPayment']);
    expect(events.whereType<GuardTripped>(), isEmpty);
    expect(events.whereType<PolicyFlagged>(), isEmpty);
    final done = events.whereType<TurnDone>().single;
    expect(done.results.single.tool, 'estimate_payment');
    expect(done.narration, contains('a month'));
    expect(pipeline.profile.paymentCeiling, 450);
  });

  test('an invented number is caught, regenerated once, then templated', () async {
    final driver = FakeDriver([
      FakeTurn(
        calls: [
          ('estimate_payment', {'price': 22000, 'term_months': 60, 'credit_band': 'good'}),
        ],
        text: (_) => 'That will be \$512 a month, guaranteed approval.',
      ),
      FakeTurn(text: (_) => 'Still \$512 a month.'),
    ]);
    var n = 0;
    final pipeline = TurnPipeline(
      driver: driver,
      finance: FinanceToolHandlers(nextId: () => 'r${++n}'),
    );
    final events = await pipeline.run('what would a 22k car cost me').toList();

    final tripped = events.whereType<GuardTripped>().toList();
    expect(tripped, hasLength(2));
    expect(tripped.first.replaced, isFalse);
    expect(tripped.last.replaced, isTrue);
    expect(driver.sent, hasLength(2));
    expect(driver.sent.last, contains('did not come from a tool result'));
    final done = events.whereType<TurnDone>().single;
    expect(done.narration, contains('on the card'));
    // The first reply's "guaranteed" is gone with the replaced narration; no policy flag on the template.
    expect(events.whereType<PolicyFlagged>(), isEmpty);
    // The streamed text of the invented reply was emitted before the guard ran; the UI
    // replaces it on GuardTripped(replaced: true).
    expect(events.whereType<TextDelta>().map((e) => e.text).join(), contains('512'));
  });

  test('a regeneration that passes replaces the text once', () async {
    final driver = FakeDriver([
      FakeTurn(
        calls: [
          (
            'estimate_payment',
            {'price': 10000, 'term_months': 36, 'credit_band': 'excellent', 'apr': 0.05},
          ),
        ],
        text: (_) => 'About \$999 a month.',
      ),
      FakeTurn(
        text: (r) =>
            'About \$${_payment(r.isEmpty ? {
                    'outputs': {'monthlyPayment': 299.71},
                  } : r[0]).toStringAsFixed(2)} a month.',
      ),
    ]);
    var n = 0;
    final pipeline = TurnPipeline(
      driver: driver,
      finance: FinanceToolHandlers(nextId: () => 'r${++n}'),
    );
    final events = await pipeline.run('10k at 5% over 36').toList();
    final tripped = events.whereType<GuardTripped>().toList();
    expect(tripped, hasLength(1));
    expect(tripped.single.replaced, isFalse);
    final done = events.whereType<TurnDone>().single;
    expect(done.narration, contains('299.71'));
  });

  test('present with a bad component is rejected and the model is told why', () async {
    final driver = FakeDriver([
      FakeTurn(
        calls: [
          ('present', {'component': 'pie_chart', 'result_id': 'r9'}),
        ],
        text: (r) => 'ok',
      ),
    ]);
    final pipeline = TurnPipeline(driver: driver);
    final events = await pipeline.run('hi').toList();
    expect(events.whereType<PresentRejected>().single.errors.single, contains('unknown component'));
  });

  test('a choice prompt needs no result and carries its options', () async {
    final driver = FakeDriver([
      FakeTurn(
        calls: [
          (
            'present',
            {
              'component': 'choice',
              'props': {
                'question': 'How are you shopping today?',
                'options': [
                  {'id': 'browsing', 'label': 'Just looking'},
                  {'id': 'buying', 'label': 'Buying now'},
                ],
              },
            },
          ),
        ],
        text: (_) => 'Happy to help either way.',
      ),
    ]);
    final events = await TurnPipeline(driver: driver).run('hello').toList();
    final p = events.whereType<Presented>().single;
    expect(p.result, isNull);
    expect((p.request.props['options'] as List), hasLength(2));
  });

  test('unknown tools report unavailability; external handler is used when given', () async {
    final driver = FakeDriver([
      FakeTurn(
        calls: [
          ('find_vehicles', {'max_price': 20000}),
        ],
        text: (r) => r.single['error']?.toString() ?? 'found',
      ),
    ]);
    final events = await TurnPipeline(driver: driver).run('find me a car').toList();
    expect(events.whereType<TurnDone>().single.narration, contains('not available'));

    final driver2 = FakeDriver([
      FakeTurn(
        calls: [
          ('find_vehicles', {'max_price': 20000}),
        ],
        text: (r) => 'found ${(r.single['count'])}',
      ),
    ]);
    final pipeline = TurnPipeline(driver: driver2, external: (name, args) async => {'count': 2});
    final events2 = await pipeline.run('find me a car').toList();
    expect(events2.whereType<ToolFinished>().single.result.tool, 'find_vehicles');
    expect(events2.whereType<TurnDone>().single.narration, contains('found 2'));
  });

  test('system prompt carries vocabulary, mode guidance and the profile', () {
    const builder = SystemPromptBuilder(
      persona: 'You are Motormind.',
      policy: 'Never sell.',
      modeGuidance: {ShoppingMode.practical: 'Be concrete.'},
    );
    final prompt = builder.build(
      profile: const BuyerProfile(mode: ShoppingMode.practical, paymentCeiling: 450),
      viewport: const ViewportDescriptor(widthDp: 411, heightDp: 914, keyboardVisible: true),
    );
    expect(prompt, contains('You are Motormind.'));
    expect(prompt, contains('Never sell.'));
    expect(prompt, contains('payment_breakdown'));
    expect(prompt, contains('Be concrete.'));
    expect(prompt, contains('payment ceiling: \$450/mo'));
    expect(prompt, contains('keyboard up'));
    final noMode = builder.build(profile: const BuyerProfile());
    expect(noMode, contains('Shopping mode: unknown'));
  });

  test('a finance call with an invented input is refused and the model is told to ask', () async {
    final driver = FakeDriver([
      FakeTurn(
        calls: [
          (
            'assess_affordability',
            {'monthly_gross_income': 6000, 'proposed_payment': 434, 'term_months': 60},
          ),
        ],
        text: (r) => r.single['error']?.toString() ?? 'ran',
      ),
    ]);
    final events = await TurnPipeline(
      driver: driver,
    ).run('can I afford 434 a month over 60 months?').toList();
    final rejected = events.whereType<InputRejected>().single;
    expect(rejected.tool, 'assess_affordability');
    expect(rejected.arguments, ['monthly_gross_income']);
    expect(events.whereType<ToolFinished>(), isEmpty);
    expect(
      events.whereType<TurnDone>().single.narration,
      contains('did not provide monthly_gross_income'),
    );
  });

  test('a computed result the model never presented is auto-presented by the app', () async {
    final driver = FakeDriver([
      FakeTurn(
        calls: [
          ('trade_equity', {'estimated_value': 6200, 'payoff': 8000}),
        ],
        text: (_) => 'You are about 1,800 underwater.',
      ),
    ]);
    final events = await TurnPipeline(
      driver: driver,
    ).run('I owe 8000 on a car worth 6200').toList();
    final p = events.whereType<Presented>().single;
    expect(p.automatic, isTrue);
    expect(p.request.component.id, 'trade_equity_card');
    expect(p.result!.tool, 'trade_equity');
    // Immediate: the card event precedes the narration text.
    final presentedAt = events.indexOf(p);
    final firstText = events.indexWhere((e) => e is TextDelta);
    expect(presentedAt, lessThan(firstText));
  });

  test('leaked tool-call JSON is stripped from narration', () {
    const leaked =
        'What is your budget? {"role":"assistant","tool_calls":[{"type":"function","function":'
        '{"name":"update_profile","arguments":{"shopping_mode":"practical"}}}]}What is your '
        'approximate budget?';
    expect(stripLeakedToolCalls(leaked), 'What is your budget? What is your approximate budget?');
    expect(stripLeakedToolCalls('Plain {"price": 5} text'), 'Plain {"price": 5} text');
    expect(stripLeakedToolCalls('a <tool_call>x</tool_call> b'), 'a x b');
  });

  test('a prose option list becomes a real choice component', () async {
    final driver = FakeDriver([
      FakeTurn(
        text: (_) =>
            'Got it. What matters most to you in an SUV?\n\nchoice:\n option1: fuel economy\n option2: cargo space\n option3: safety features',
      ),
    ]);
    final events = await TurnPipeline(driver: driver).run('I want an SUV').toList();
    final p = events.whereType<Presented>().single;
    expect(p.request.component.id, 'choice');
    expect(p.request.props['question'], 'What matters most to you in an SUV?');
    expect((p.request.props['options'] as List).cast<Map>().map((o) => o['label']), [
      'fuel economy',
      'cargo space',
      'safety features',
    ]);
    expect(
      events.whereType<TurnDone>().single.narration,
      'Got it. What matters most to you in an SUV?',
    );
  });

  test('inline choice parsing edge cases', () {
    expect(extractInlineChoice('No list here at all.'), isNull);
    expect(extractInlineChoice('1. only one item'), isNull);
    final c = extractInlineChoice('Pick one:\n1. fuel economy\n2. cargo space\nThanks.');
    expect(c!.options.length, 2);
    expect(c.remainder, 'Pick one:\nThanks.');
    final d = extractInlineChoice(
      'Great! What kind of car? For example:\n* SUV\n* Sports car\nLet me know.',
    );
    expect(d!.question, 'What kind of car?');
  });
}
