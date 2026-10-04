import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  const policy = PolicyCheck();

  test('clean narration has no flags', () {
    expect(
      policy.check(
        'At 60 months the payment is higher than your ceiling; here are two ways to bring it down.',
      ),
      isEmpty,
    );
  });

  test('flags urgency, guarantees, pressure, advice and compensation', () {
    final flags = policy.check(
      'Act now, this deal won\'t last. Approval is guaranteed. You should buy this one, it\'s a no-brainer. '
      'I recommend you finance through our partner lender.',
    );
    expect(flags.map((f) => f.category).toSet(), containsAll(PolicyCategory.values));
  });

  test('is case-insensitive and keeps an excerpt', () {
    final flags = policy.check('GUARANTEED approval today.');
    expect(flags, isNotEmpty);
    expect(flags.first.excerpt, contains('GUARANTEED'));
  });

  test('disclosures are complete and versioned', () {
    expect(Disclosures.all.map((d) => d.key).toSet(), {
      'not_advice',
      'not_lender_or_dealer',
      'no_compensation',
      'estimates_only',
      'illustrative_rates',
      'data_on_device',
      'browser_actions',
    });
    expect(Disclosures.gateVersion, Disclosures.all.length);
    expect(Disclosures.gateSummary, contains('not a lender'));
    expect(Disclosures.byKey('no_compensation').long, contains('No one pays'));
  });
}
