import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  const guard = NarrationGuard();

  final toolResult = {
    'inputs': {'price': 22700, 'apr': 0.06, 'termMonths': 60},
    'outputs': {'monthlyPayment': 438.86, 'financeCharge': 3631.6, 'amountFinanced': 22700},
  };

  test('extracts dollars, commas, decimals, percents and k-suffix', () {
    final m = guard.extract(
      r'About $438.86 a month, $22,700 financed at 6% APR, roughly 23k total over 5 years.',
    );
    expect(m.map((x) => x.value), containsAll([438.86, 22700, 0.06, 23000, 5]));
  });

  test('numbers glued to letters are names, not figures', () {
    expect(guard.extract('an Audi A4 with 2.0T'), isEmpty);
    expect(guard.extract('a V6 F150 with the 3.5L'), isEmpty);
    expect(guard.extract('a 2.0 liter engine').map((m) => m.value), [2.0]);
  });

  test('passes when every number is in the tool result', () {
    final r = guard.check(
      narration: r'Your payment would be $438.86 a month on $22,700 financed at 6% over 60 months.',
      sources: [toolResult],
    );
    expect(r.passed, isTrue, reason: r.unmatched.toString());
  });

  test('tolerates whole-dollar rounding and small spoken rounding', () {
    final r = guard.check(
      narration: r'That is about $439 a month, call it $440.',
      sources: [toolResult],
    );
    expect(r.passed, isTrue, reason: r.unmatched.toString());
  });

  test('the relative tolerance is a boundary: 2% passes, 3% fails', () {
    final sources = [
      {'price': 500},
    ];
    expect(guard.check(narration: r'about $510', sources: sources).passed, isTrue);
    expect(guard.check(narration: r'about $515', sources: sources).passed, isFalse);
  });

  test('fails on an invented number', () {
    final r = guard.check(narration: r'Your payment would be $512 a month.', sources: [toolResult]);
    expect(r.passed, isFalse);
    expect(r.unmatched.single.value, 512);
  });

  test('a small fraction never matches a value that merely rounds to zero', () {
    final sources = [
      {'fees': 0, 'apr': 0.06, 'down': 0.2},
    ];
    expect(guard.check(narration: 'a rate of 0.03', sources: sources).passed, isFalse);
    expect(guard.check(narration: 'a rate of 3%', sources: sources).passed, isFalse);
    expect(guard.check(narration: 'a rate of 5%', sources: sources).passed, isFalse);
    expect(guard.check(narration: 'a rate of 6%', sources: sources).passed, isTrue);
    expect(guard.matches(0.03, {0.0, 0.4}), isFalse);
  });

  test('allows years and small counts', () {
    final r = guard.check(narration: 'A 2019 Civic, here are 3 options.', sources: [toolResult]);
    expect(r.passed, isTrue);
  });

  test('allows numbers the user supplied', () {
    final r = guard.check(
      narration: r'You said you can do $450 a month and owe $8,000 on the Civic.',
      sources: [
        toolResult,
        {
          'user_inputs': {'payment_ceiling': 450, 'trade_payoff': '8000'},
        },
      ],
    );
    expect(r.passed, isTrue, reason: r.unmatched.toString());
  });

  test('percent in text matches a decimal in results, and a fraction may be said as a number', () {
    expect(guard.check(narration: 'at 6.0% APR', sources: [toolResult]).passed, isTrue);
    expect(guard.check(narration: 'at 6.0 percent', sources: [toolResult]).passed, isTrue);
  });

  test('a whole number in a source does not stand in for a percentage', () {
    final sources = [
      {'count': 45},
    ];
    expect(guard.check(narration: 'about 45% of buyers', sources: sources).passed, isFalse);
  });
}
