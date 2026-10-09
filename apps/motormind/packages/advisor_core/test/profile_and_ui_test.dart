import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

// PresentRequest and ComponentRegistry have their own file,
// present_request_test.dart; this one covers the profile and the tool specs.
void main() {
  group('BuyerProfile', () {
    test('applies an update_profile call without inventing labels', () {
      const p = BuyerProfile();
      final updated = p.applyUpdate({
        'items': [
          {'label': 'seats 7', 'kind': 'need'},
          {'label': 'heated seats', 'kind': 'unlabeled'},
        ],
        'payment_ceiling': 450,
        'credit_score': 690,
        'trade_payoff': '8,000',
        'shopping_mode': 'practical',
      });
      expect(updated.needs.single.label, 'seats 7');
      expect(updated.unlabeled.single.label, 'heated seats');
      expect(updated.paymentCeiling, 450);
      expect(updated.creditBand, CreditBand.good);
      expect(updated.tradePayoff, 8000);
      expect(updated.mode, ShoppingMode.practical);
      expect(updated.toPromptSummary(), contains('mentioned (unlabeled): heated seats'));
    });

    test('relabeling replaces the item and JSON round-trips', () {
      final p = const BuyerProfile()
          .applyUpdate({
            'items': [
              {'label': 'Heated Seats', 'kind': 'unlabeled'},
            ],
          })
          .applyUpdate({
            'items': [
              {'label': 'heated seats', 'kind': 'need'},
            ],
          });
      expect(p.items, hasLength(1));
      expect(p.needs.single.kind, ItemKind.need);
      final back = BuyerProfile.fromJson(p.toJson());
      expect(back.needs.single.label, 'heated seats');
    });

    test('empty profile summarizes as nothing known', () {
      expect(const BuyerProfile().toPromptSummary(), 'nothing known yet');
    });
  });

  test('tool specs have unique names and object schemas', () {
    final names = AdvisorTools.all.map((t) => t.name).toList();
    expect(names.toSet().length, names.length);
    for (final t in AdvisorTools.all) {
      expect(t.parameters['type'], 'object', reason: t.name);
      expect(t.parameters['properties'], isA<Map>(), reason: t.name);
    }
    expect(AdvisorTools.byName('present').changesUi, isTrue);
  });
}
