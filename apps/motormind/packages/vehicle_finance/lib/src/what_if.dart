import 'assumption.dart';
import 'deal.dart';
import 'money.dart';

/// A labeled alternative to a deal, changing one input.
class WhatIfVariant {
  /// Creates a variant from its label, the one changed input and the full
  /// estimate with that change applied.
  const WhatIfVariant({required this.label, required this.changed, required this.estimate});

  /// Short user-facing name for the change, e.g. `48-month term`.
  final String label;

  /// The input that changed and its new value, for the UI and the guard.
  final Map<String, Object?> changed;

  /// The complete [DealEstimate] with the one change applied.
  final DealEstimate estimate;

  /// Serializes the variant with its estimate nested in full, so every number
  /// in it can be verified.
  Map<String, Object?> toJson() => {
    'label': label,
    'changed': changed,
    'estimate': estimate.toJson(),
  };
}

/// Three one-variable alternatives: a shorter term, more money down, a lower
/// price. Each is a real [DealEstimate], so its numbers are verifiable.
///
/// [termStep] is in months, [extraDown] in dollars and [priceCut] a fraction
/// of the price. The shorter-term variant is omitted when it would drop the
/// term below 12 months, so the list has two or three entries.
List<WhatIfVariant> whatIfVariants(
  DealInputs base, {
  required Assumption aprAssumption,
  int termStep = 12,
  double extraDown = 1000,
  double priceCut = 0.10,
}) {
  final variants = <WhatIfVariant>[];

  if (base.termMonths - termStep >= 12) {
    final term = base.termMonths - termStep;
    variants.add(
      WhatIfVariant(
        label: '$term-month term',
        changed: {'termMonths': term},
        estimate: estimateDeal(base.copyWith(termMonths: term), aprAssumption: aprAssumption),
      ),
    );
  }

  final down = roundCents(base.downPayment + extraDown);
  variants.add(
    WhatIfVariant(
      label: '${extraDown.toStringAsFixed(0)} more down',
      changed: {'downPayment': down},
      estimate: estimateDeal(base.copyWith(downPayment: down), aprAssumption: aprAssumption),
    ),
  );

  final price = roundCents(base.price * (1 - priceCut));
  variants.add(
    WhatIfVariant(
      label: '${(priceCut * 100).toStringAsFixed(0)}% lower price',
      changed: {'price': price},
      estimate: estimateDeal(base.copyWith(price: price), aprAssumption: aprAssumption),
    ),
  );

  return variants;
}
