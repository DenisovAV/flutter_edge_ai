import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

void main() {
  test('a credit_score overrides a credit_band given in the same call', () {
    final p = const BuyerProfile().applyUpdate({'credit_band': 'poor', 'credit_score': 790});
    expect(p.creditBand, CreditBand.excellent);
    final q = p.applyUpdate({'credit_band': 'fair'});
    expect(q.creditBand, CreditBand.fair, reason: 'a band alone still updates');
  });

  test('an unknown credit band or mode keeps the previous value instead of throwing', () {
    const p = BuyerProfile(creditBand: CreditBand.good, mode: ShoppingMode.browsing);
    final q = p.applyUpdate({'credit_band': 'platinum', 'shopping_mode': 'serious'});
    expect(q.creditBand, CreditBand.good);
    expect(q.mode, ShoppingMode.browsing);
    expect(p.applyUpdate({'credit_band': ' Good '}).creditBand, CreditBand.good);
  });

  test('numbers arrive as the model writes them', () {
    final p = const BuyerProfile().applyUpdate({
      'payment_ceiling': r'$450',
      'down_payment': '2,000',
      'monthly_debt_payments': 300,
      'credit_score': '690',
    });
    expect(p.paymentCeiling, 450);
    expect(p.downPayment, 2000);
    expect(p.monthlyDebtPayments, 300);
    expect(p.creditBand, CreditBand.good);
  });

  test('the prompt summary puts a dollar sign on every amount', () {
    const p = BuyerProfile(
      paymentCeiling: 450,
      downPayment: 2000,
      monthlyGrossIncome: 5200,
      monthlyDebtPayments: 300,
      tradeValue: 6200,
      tradePayoff: 8000,
    );
    expect(
      p.toPromptSummary(),
      'payment ceiling: \$450/mo; down payment: \$2000; gross income: \$5200/mo; '
      'debt payments: \$300/mo; trade-in value: \$6200, payoff: \$8000',
    );
    expect(
      const BuyerProfile(tradePayoff: 8000).toPromptSummary(),
      'trade-in value: unknown, payoff: \$8000',
    );
  });

  test('fromJson tolerates unknown names, odd items and an unknown key', () {
    final p = BuyerProfile.fromJson({
      'items': [
        {'label': 'third row', 'kind': 'essential'},
        'not an item',
      ],
      'creditBand': 'platinum',
      'mode': 'serious',
      'paymentCeiling': '450',
      'preferNew': true,
    });
    expect(p.items.single.label, 'third row');
    expect(p.items.single.kind, ItemKind.unlabeled);
    expect(p.creditBand, isNull);
    expect(p.mode, isNull);
    expect(p.paymentCeiling, 450);
  });

  test('toJson round-trips every field', () {
    final p = const BuyerProfile().applyUpdate({
      'items': [
        {'label': 'seats 7', 'kind': 'need'},
      ],
      'payment_ceiling': 450,
      'down_payment': 1000,
      'credit_band': 'fair',
      'monthly_gross_income': 5200,
      'monthly_debt_payments': 300,
      'trade_value': 6200,
      'trade_payoff': 8000,
      'shopping_mode': 'buying',
    });
    final back = BuyerProfile.fromJson(p.toJson());
    expect(back.toJson(), p.toJson());
    expect(back.needs.single.label, 'seats 7');
    expect(back.mode, ShoppingMode.buying);
  });
}
