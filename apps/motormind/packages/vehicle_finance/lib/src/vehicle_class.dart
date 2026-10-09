/// Personal-vehicle classes in scope for the first release.
///
/// Motorsport classes (motorcycle, ATV, personal watercraft) are deliberately
/// not here yet; they have different financing norms and will be added as a
/// separate story once the four below work end to end.
enum VehicleClass {
  /// Sedans, hatchbacks, coupes and wagons.
  car,

  /// Sport-utility vehicles and crossovers.
  suv,

  /// Pickup trucks of any size.
  pickup,

  /// Minivans and passenger vans.
  van;

  /// Parses a class name as written by a tool call or a stored profile,
  /// ignoring case and surrounding whitespace.
  ///
  /// Throws an [ArgumentError] for anything that is not one of [values].
  static VehicleClass parse(String value) => VehicleClass.values.firstWhere(
        (v) => v.name == value.toLowerCase().trim(),
        orElse: () => throw ArgumentError.value(value, 'value', 'unknown vehicle class'),
      );
}
