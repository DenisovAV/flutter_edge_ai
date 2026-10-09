import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  const builder = SystemPromptBuilder(
    persona: 'You are Motormind.',
    policy: 'Never sell.',
    modeGuidance: {ShoppingMode.practical: 'Be concrete.'},
  );

  test('carries the editable sections, mode guidance, the profile and the viewport', () {
    final prompt = builder.build(
      profile: const BuyerProfile(mode: ShoppingMode.practical, paymentCeiling: 450),
      viewport: const ViewportDescriptor(widthDp: 411, heightDp: 914, keyboardVisible: true),
    );
    expect(prompt, startsWith('You are Motormind.'));
    expect(prompt, contains('# Rules\nNever sell.'));
    expect(prompt, contains('# Current shopping mode: practical\nBe concrete.'));
    expect(
      prompt,
      contains('# Known about this person: shopping mode: practical; payment ceiling: \$450/mo'),
    );
    expect(prompt, contains('# Viewport: 411x914 dp, phone, keyboard up'));
  });

  test('the fixed contract sections are always present, in order', () {
    final prompt = builder.build(profile: const BuyerProfile());
    final numbers = prompt.indexOf('# Numbers');
    final replying = prompt.indexOf('# Replying');
    final screen = prompt.indexOf('# Screen');
    expect(numbers, greaterThan(0));
    expect(replying, greaterThan(numbers));
    expect(screen, greaterThan(replying));
    expect(prompt, contains('Never compute or guess'));
    expect(prompt, contains('present(choice)'));
  });

  test('lists every component the model may present and none it may not', () {
    final prompt = builder.build(profile: const BuyerProfile());
    for (final c in ComponentRegistry.forModel) {
      expect(prompt, contains(c.id), reason: c.id);
    }
    for (final c in ComponentRegistry.all.where((c) => c.appOwned)) {
      expect(prompt, isNot(contains(c.id)), reason: c.id);
    }
    expect(prompt, isNot(contains('search_filters')));
  });

  test('an unknown mode asks the model to infer one; no viewport line without a viewport', () {
    final prompt = builder.build(profile: const BuyerProfile());
    expect(prompt, contains('Shopping mode: unknown'));
    expect(prompt, isNot(contains('# Viewport')));
    expect(prompt, contains('nothing known yet'));
  });
}
