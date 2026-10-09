import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  test('disclosures are complete and keyed', () {
    expect(Disclosures.all.map((d) => d.key).toSet(), {
      'not_advice',
      'not_lender_or_dealer',
      'no_compensation',
      'estimates_only',
      'illustrative_rates',
      'data_on_device',
      'browser_actions',
    });
    expect(Disclosures.byKey('no_compensation').long, contains('No one pays'));
    expect(() => Disclosures.byKey('nope'), throwsArgumentError);
  });

  test('the gate version is the sum of versions and every version is at least 1', () {
    expect(Disclosures.all.every((d) => d.version >= 1), isTrue);
    expect(Disclosures.gateVersion, Disclosures.all.fold(0, (s, d) => s + d.version));
    expect(Disclosures.gateVersion, greaterThanOrEqualTo(Disclosures.all.length));
  });
}
