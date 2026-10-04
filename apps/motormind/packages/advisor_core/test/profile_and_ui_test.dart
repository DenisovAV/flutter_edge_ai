import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

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
        'tone': 'practical',
      });
      expect(updated.needs.single.label, 'seats 7');
      expect(updated.unlabeled.single.label, 'heated seats');
      expect(updated.paymentCeiling, 450);
      expect(updated.creditBand, CreditBand.good);
      expect(updated.tradePayoff, 8000);
      expect(updated.tone, ConversationTone.practical);
      expect(updated.toPromptSummary(), contains('mentioned (unlabeled): heated seats'));
    });

    test('relabeling replaces the item and JSON round-trips', () {
      final p = const BuyerProfile().applyUpdate({
        'items': [
          {'label': 'Heated Seats', 'kind': 'unlabeled'},
        ],
      }).applyUpdate({
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

  group('PresentRequest', () {
    test('valid request uses the component default surface', () {
      final v = PresentRequest.validate({'component': 'payment_breakdown', 'result_id': 'r1'}, resultTool: 'estimate_payment');
      expect(v.errors, isEmpty);
      expect(v.request!.surface, SurfaceState.fullscreen);
    });

    test('rejects unknown components, mismatched tools and collapsed surface', () {
      expect(PresentRequest.validate({'component': 'pie_chart', 'result_id': 'r1'}, resultTool: 'estimate_payment').errors, isNotEmpty);
      expect(PresentRequest.validate({'component': 'ownership_cost', 'result_id': 'r1'}, resultTool: 'estimate_payment').errors.single, contains('cannot render'));
      expect(PresentRequest.validate({'component': 'payment_summary', 'result_id': 'r1', 'surface': 'collapsed'}, resultTool: 'estimate_payment').errors.single, contains('surface'));
      expect(PresentRequest.validate({'component': 'payment_summary', 'result_id': 'r9'}, resultTool: null).errors.single, contains('does not match'));
    });

    test('question_chips needs no result', () {
      final v = PresentRequest.validate({'component': 'question_chips'}, resultTool: null);
      expect(v.errors, isEmpty);
    });

    test('registry prompt text lists every component', () {
      final text = ComponentRegistry.describeForPrompt();
      for (final c in ComponentRegistry.all) {
        expect(text, contains(c.id));
      }
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
