import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

void main() {
  final names = AdvisorTools.all.map((t) => t.name).toSet();

  test('specs have unique names and object schemas, and the list is unmodifiable', () {
    expect(names.length, AdvisorTools.all.length);
    for (final t in AdvisorTools.all) {
      expect(t.parameters['type'], 'object', reason: t.name);
      expect(t.parameters['properties'], isA<Map>(), reason: t.name);
      expect(t.toJson().keys, ['name', 'description', 'parameters'], reason: t.name);
    }
    expect(AdvisorTools.all.clear, throwsUnsupportedError);
    expect(() => AdvisorTools.byName('nope'), throwsArgumentError);
  });

  test('every tool a component accepts, and every tool with a default card, is a real tool', () {
    for (final c in ComponentRegistry.all) {
      for (final tool in c.acceptsTools) {
        expect(names, contains(tool), reason: '${c.id} accepts $tool');
      }
    }
    final withDefault = <String>{};
    for (final name in names) {
      final component = ComponentRegistry.defaultFor(name);
      if (component == null) continue;
      withDefault.add(name);
      expect(component.acceptsTools, contains(name), reason: name);
    }
    expect(withDefault, {
      AdvisorTools.estimatePayment,
      AdvisorTools.maxAffordablePrice,
      AdvisorTools.tradeEquity,
      AdvisorTools.estimateLease,
      AdvisorTools.assessAffordability,
      AdvisorTools.ownershipCost,
      AdvisorTools.findVehicles,
      AdvisorTools.readPage,
    });
    expect(ComponentRegistry.defaultFor('book_test_drive'), isNull);
  });

  test('tools that change the screen are marked, and the mark stays out of the SDK payload', () {
    expect(AdvisorTools.changesUi(AdvisorTools.present), isTrue);
    expect(AdvisorTools.changesUi(AdvisorTools.updateSearch), isTrue);
    expect(AdvisorTools.changesUi(AdvisorTools.findVehicles), isFalse);
    expect(AdvisorTools.changesUi('nope'), isFalse);
    expect(AdvisorTools.byName(AdvisorTools.present).toJson().containsKey('changesUi'), isFalse);
  });

  test('enum value lists come from the enums the handlers parse against', () {
    Map<String, Object?> props(String tool) =>
        (AdvisorTools.byName(tool).parameters['properties'] as Map).cast<String, Object?>();
    List<Object?> values(Map<String, Object?> p, String field) => (p[field] as Map)['enum'] as List;
    expect(
      values(props(AdvisorTools.estimatePayment), 'credit_band'),
      CreditBand.values.map((b) => b.name),
    );
    final ownership = props(AdvisorTools.ownershipCost);
    expect(values(ownership, 'vehicle_class'), VehicleClass.values.map((c) => c.name));
    expect(values(ownership, 'fuel_type'), FuelType.values.map((f) => f.name));
    expect(values(ownership, 'insurance_band'), InsuranceBand.values.map((b) => b.name));
    expect(values(props(AdvisorTools.updateSearch), 'body_style'), [
      ...SearchQuery.bodyStyles,
      'any',
    ]);
  });

  test('update_profile offers every number the profile reads', () {
    final props = (AdvisorTools.byName(AdvisorTools.updateProfile).parameters['properties'] as Map)
        .keys
        .toSet();
    expect(
      props,
      containsAll([
        'payment_ceiling',
        'down_payment',
        'credit_band',
        'credit_score',
        'monthly_gross_income',
        'monthly_debt_payments',
        'trade_value',
        'trade_payoff',
        'shopping_mode',
        'items',
      ]),
    );
    expect(props, isNot(contains('prefer_new')));
  });
}
