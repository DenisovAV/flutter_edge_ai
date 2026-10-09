/// Rounding helpers shared by every calculator in this package.
///
/// They are public, not private to each calculator, because code that
/// composes results (the tool handlers in advisor_core, derived figures in the
/// UI, tests) must round exactly the way the package does. Otherwise the
/// narration guard sees a mismatch between a number the model repeats and the
/// number the package produced, and a cent of drift reads as a hallucination.
library;

import 'dart:math' as math;

/// Rounds [value] to the nearest cent using half-away-from-zero rounding.
double roundCents(double value) => (value * 100).round() / 100;

/// Rounds [value] to [places] decimal places using half-away-from-zero
/// rounding; `roundTo(x, 2)` is [roundCents].
///
/// Used for ratios such as payment-to-income, where four places keep a
/// percentage accurate to a hundredth of a point.
double roundTo(double value, int places) {
  final scale = math.pow(10, places).toDouble();
  return (value * scale).round() / scale;
}
