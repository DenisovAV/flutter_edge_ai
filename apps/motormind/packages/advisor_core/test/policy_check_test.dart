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

  test('is case-insensitive and keeps an excerpt with context', () {
    final flags = policy.check('GUARANTEED approval today.');
    expect(flags, isNotEmpty);
    expect(flags.first.excerpt, contains('GUARANTEED'));
    expect(flags.first.excerpt, contains('approval'));
  });

  test('the excerpt window clamps to the text at both ends', () {
    final flags = policy.check('hurry');
    expect(flags.single.excerpt, 'hurry');
  });

  test('"best deal of the three" is a comparison, not a sales pitch', () {
    expect(policy.check('The second listing is the best deal of the three on the card.'), isEmpty);
    expect(
      policy.check('This is the best deal, grab it.').single.category,
      PolicyCategory.pressure,
    );
    expect(policy.check('A great deal of the cost is tax.'), isEmpty);
  });
}
