/// Rounds [value] to the nearest cent using half-away-from-zero rounding.
double roundCents(double value) => (value * 100).round() / 100;

/// Rounds [value] to the nearest whole dollar.
double roundDollars(double value) => value.roundToDouble();

/// True when two money values are equal to the cent.
bool sameCents(double a, double b) => (a - b).abs() < 0.005;
