import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  const guard = InputProvenanceGuard();
  final said = [
    {
      'user_text':
          'I can do about 450 a month. Good credit, 60 months, looking at a 22k car with 1000 down.',
    },
  ];

  test('arguments the user stated pass, including 22k for 22000 and rounding', () {
    final r = guard.check(
      args: {
        'price': 22000,
        'term_months': 60,
        'credit_band': 'good',
        'down_payment': 1000,
        'payment_ceiling': 450,
      },
      sources: said,
    );
    expect(r.passed, isTrue, reason: r.unsupported.toString());
  });

  test('a string argument that is a single number is checked like a number', () {
    expect(guard.check(args: {'price': '22k'}, sources: said).passed, isTrue);
    expect(guard.check(args: {'price': r'$22,000'}, sources: said).passed, isTrue);
    expect(guard.check(args: {'price': '31k'}, sources: said).unsupported, ['price']);
    // A sentence is not a figure; only the finance handler will complain.
    expect(guard.check(args: {'price': 'about 31k or so'}, sources: said).passed, isTrue);
  });

  test('an invented income is rejected by name', () {
    final r = guard.check(
      args: {'monthly_gross_income': 6000, 'proposed_payment': 433.99, 'term_months': 60},
      sources: [
        ...said,
        {
          'outputs': {'monthlyPayment': 433.99},
        },
      ],
    );
    expect(r.unsupported, ['monthly_gross_income']);
  });

  test('numbers from earlier tool outputs and the profile count as supported', () {
    final r = guard.check(
      args: {'proposed_payment': 434, 'monthly_gross_income': 5200, 'term_months': 60},
      sources: [
        ...said,
        {
          'outputs': {'monthlyPayment': 433.99},
        },
        const BuyerProfile(monthlyGrossIncome: 5200).toJson(),
      ],
    );
    expect(r.passed, isTrue, reason: r.unsupported.toString());
  });

  test('defaults the model may choose and zero are exempt', () {
    final r = guard.check(
      args: {'price': 22000, 'sales_tax_rate': 0.07, 'fees': 500, 'trade_payoff': 0},
      sources: said,
    );
    expect(r.passed, isTrue, reason: r.unsupported.toString());
  });

  test('shares the narration guard tolerance, so a 3% drift is rejected', () {
    expect(guard.check(args: {'price': 22400}, sources: said).passed, isTrue);
    expect(guard.check(args: {'price': 22700}, sources: said).unsupported, ['price']);
  });
}
