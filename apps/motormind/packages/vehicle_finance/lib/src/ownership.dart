import 'assumption.dart';
import 'money.dart';
import 'vehicle_class.dart';

/// How the vehicle is powered, which decides how [OwnershipInputs.efficiency]
/// and the energy price are read.
enum FuelType {
  /// Gasoline engine; efficiency in miles per gallon.
  gasoline,

  /// Gasoline-electric hybrid; efficiency in miles per gallon, fueled like
  /// [gasoline].
  hybrid,

  /// Battery electric; efficiency in miles per kWh, charged at a price per kWh.
  electric,
}

/// Rough insurance cost tier, standing in for a real quote.
enum InsuranceBand {
  /// Cheaper than typical: older driver, clean record, modest vehicle.
  low,

  /// A national-average premium.
  average,

  /// Pricier than typical: young driver, claims history, high-value vehicle.
  high,
}

/// What a rough multi-year cost-of-ownership estimate needs.
///
/// Money is in dollars; the unit of [efficiency] depends on [fuelType]. The
/// defaults for energy prices, insurance and registration are placeholders
/// that the estimate labels as such.
class OwnershipInputs {
  /// Creates the inputs; the defaults describe a five-year window starting
  /// with a new vehicle.
  const OwnershipInputs({
    required this.vehicleClass,
    required this.purchasePrice,
    required this.milesPerYear,
    required this.fuelType,
    required this.efficiency,
    this.years = 5,
    this.vehicleAgeYears = 0,
    this.fuelPricePerGallon = 3.50,
    this.electricityPerKwh = 0.17,
    this.insuranceBand = InsuranceBand.average,
    this.salesTaxRate = 0,
    this.annualRegistration = 150,
  });

  /// Body class, which scales the maintenance table.
  final VehicleClass vehicleClass;

  /// Price paid today, in dollars; the base for depreciation and sales tax.
  final double purchasePrice;

  /// Expected annual mileage, which drives fuel or energy cost.
  final int milesPerYear;

  /// How the vehicle is powered.
  final FuelType fuelType;

  /// MPG for gasoline and hybrid; miles per kWh for electric.
  final double efficiency;

  /// Length of the ownership window in years.
  final int years;

  /// Age at purchase; drives the depreciation curve start and maintenance.
  final int vehicleAgeYears;

  /// Gasoline price in dollars per gallon; ignored for electric vehicles.
  final double fuelPricePerGallon;

  /// Electricity price in dollars per kWh; ignored for gasoline and hybrid.
  final double electricityPerKwh;

  /// Insurance tier used to pick an annual premium from the tables.
  final InsuranceBand insuranceBand;

  /// Sales tax on the purchase as a fraction, `0.07` for 7%; counted once.
  final double salesTaxRate;

  /// Registration and plate fees in dollars per year.
  final double annualRegistration;

  /// Serializes the inputs for the result's input record; enums by name.
  Map<String, Object?> toJson() => {
    'vehicleClass': vehicleClass.name,
    'purchasePrice': purchasePrice,
    'milesPerYear': milesPerYear,
    'fuelType': fuelType.name,
    'efficiency': efficiency,
    'years': years,
    'vehicleAgeYears': vehicleAgeYears,
    'fuelPricePerGallon': fuelPricePerGallon,
    'electricityPerKwh': electricityPerKwh,
    'insuranceBand': insuranceBand.name,
    'salesTaxRate': salesTaxRate,
    'annualRegistration': annualRegistration,
  };
}

/// Rough tables behind the ownership estimate.
///
/// Every number is a placeholder in a plausible range and is labeled
/// illustrative in the result; replace with sourced values before relying on
/// them. The class is a namespace: nothing here is an instance member.
abstract final class OwnershipTables {
  /// Source label attached to every assumption derived from these tables.
  static const String source = 'rough national averages, placeholder until sourced tables land';

  /// ISO-8601 date the tables were last reviewed.
  static const String asOf = assumptionsReviewedOn;

  /// Fraction of the *original* value lost by the end of each ownership year,
  /// cumulative, for a vehicle bought new. Used vehicles start partway along,
  /// and years past the end of the list reuse the last entry.
  ///
  /// Every entry must stay below 1.0: [estimateOwnership] divides by the
  /// value still remaining at the start of the window.
  static const List<double> cumulativeDepreciation = [
    0.20,
    0.31,
    0.40,
    0.48,
    0.55,
    0.60,
    0.65,
    0.69,
    0.72,
    0.75,
  ];

  /// Annual maintenance and repairs by vehicle age in years; ages past the
  /// end of the list reuse the last entry.
  static const List<double> maintenanceByAge = [
    400,
    500,
    650,
    850,
    1050,
    1250,
    1450,
    1650,
    1850,
    2000,
  ];

  /// Annual premium in dollars for [band].
  ///
  /// A switch rather than a map so adding an [InsuranceBand] without a premium
  /// is a compile error, not a null at runtime.
  static double annualInsuranceFor(InsuranceBand band) => switch (band) {
    InsuranceBand.low => 1200,
    InsuranceBand.average => 1900,
    InsuranceBand.high => 2800,
  };

  /// Scale applied to [maintenanceByAge] for [vehicleClass]; cars are the
  /// baseline.
  ///
  /// A switch rather than a map so adding a [VehicleClass] without a
  /// multiplier is a compile error, not a silent fallback to 1.0.
  static double maintenanceMultiplierFor(VehicleClass vehicleClass) => switch (vehicleClass) {
    VehicleClass.car => 1.0,
    VehicleClass.suv => 1.15,
    VehicleClass.pickup => 1.2,
    VehicleClass.van => 1.1,
  };
}

/// Cost of owning the vehicle over the input's window, split by category.
///
/// Every field is a dollar total for the whole window, not per year; see
/// [perMonth] for the spread.
class OwnershipEstimate extends CalcResult {
  /// Creates an estimate from already-computed figures; [estimateOwnership] is
  /// the usual way to get one. The [input] is serialized into [inputs] and
  /// its window length is kept as [years].
  OwnershipEstimate({
    required OwnershipInputs input,
    required this.depreciation,
    required this.fuelOrEnergy,
    required this.insurance,
    required this.maintenance,
    required this.taxesAndFees,
    required super.assumptions,
  }) : years = input.years,
       super(inputs: input.toJson());

  /// Length of the ownership window the totals cover, from the inputs.
  final int years;

  /// Value lost over the window, from the cumulative curve in
  /// [OwnershipTables.cumulativeDepreciation].
  final double depreciation;

  /// Gasoline or electricity cost over the window, by fuel type.
  final double fuelOrEnergy;

  /// Insurance premiums over the window, from the band table.
  final double insurance;

  /// Maintenance and repairs over the window, by age and scaled by class.
  final double maintenance;

  /// One-time sales tax plus registration for every year of the window.
  final double taxesAndFees;

  /// Sum of every category, in dollars.
  double get total =>
      roundCents(depreciation + fuelOrEnergy + insurance + maintenance + taxesAndFees);

  /// [total] spread evenly over the [years] of the window, in dollars per
  /// month.
  double get perMonth => roundCents(total / (years * 12));

  @override
  Map<String, Object?> outputsToJson() => {
    'depreciation': depreciation,
    'fuelOrEnergy': fuelOrEnergy,
    'insurance': insurance,
    'maintenance': maintenance,
    'taxesAndFees': taxesAndFees,
    'total': total,
  };
}

/// Estimates the cost of owning the vehicle described by [input] over its
/// window, using [OwnershipTables].
///
/// Depreciation reads the cumulative curve from the vehicle's current age and
/// scales the remaining drop to today's price, so a used vehicle loses less in
/// absolute terms than the same price new. Fuel is miles divided by
/// efficiency times the energy price; maintenance is summed year by year from
/// the age table. Windows that run past the end of the tables reuse the last
/// year's figures. Throws an [ArgumentError] for a non-positive window or
/// efficiency.
OwnershipEstimate estimateOwnership(OwnershipInputs input) {
  if (input.years <= 0) {
    throw ArgumentError.value(input.years, 'years', 'must be positive');
  }
  if (input.efficiency <= 0) {
    throw ArgumentError.value(input.efficiency, 'efficiency', 'must be positive');
  }

  // Depreciation: the share of today's price lost over the ownership window,
  // reading the cumulative curve from the vehicle's current age.
  final curve = OwnershipTables.cumulativeDepreciation;
  double lostAt(int age) => age <= 0 ? 0.0 : curve[_index(age - 1, curve.length)];
  final startLost = lostAt(input.vehicleAgeYears);
  final endLost = lostAt(input.vehicleAgeYears + input.years);
  // Today's price already reflects startLost; scale the remaining drop to it.
  // The curve tops out below 1.0, so the divisor is always positive.
  final remainingShare = (endLost - startLost) / (1 - startLost);
  final depreciation = roundCents(input.purchasePrice * remainingShare);

  final totalMiles = input.milesPerYear * input.years;
  final fuel = switch (input.fuelType) {
    FuelType.electric => totalMiles / input.efficiency * input.electricityPerKwh,
    FuelType.gasoline ||
    FuelType.hybrid => totalMiles / input.efficiency * input.fuelPricePerGallon,
  };

  final annualInsurance = OwnershipTables.annualInsuranceFor(input.insuranceBand);
  final insurance = annualInsurance * input.years;

  var maintenance = 0.0;
  final multiplier = OwnershipTables.maintenanceMultiplierFor(input.vehicleClass);
  final byAge = OwnershipTables.maintenanceByAge;
  for (var y = 0; y < input.years; y++) {
    final age = input.vehicleAgeYears + y;
    maintenance += byAge[_index(age, byAge.length)] * multiplier;
  }

  final taxes = input.purchasePrice * input.salesTaxRate + input.annualRegistration * input.years;

  return OwnershipEstimate(
    input: input,
    depreciation: depreciation,
    fuelOrEnergy: roundCents(fuel),
    insurance: roundCents(insurance),
    maintenance: roundCents(maintenance),
    taxesAndFees: roundCents(taxes),
    assumptions: [
      Assumption(
        key: 'tco.depreciation_curve',
        description:
            'Class-independent depreciation curve; real curves vary widely by model and market.',
        value: 'cumulative ${OwnershipTables.cumulativeDepreciation.join(', ')}',
        source: OwnershipTables.source,
        asOf: OwnershipTables.asOf,
      ),
      Assumption(
        key: 'tco.insurance',
        description:
            'National-average annual premium for the ${input.insuranceBand.name} band; your quote will differ.',
        value: annualInsurance.toStringAsFixed(0),
        source: OwnershipTables.source,
        asOf: OwnershipTables.asOf,
      ),
      Assumption(
        key: 'tco.maintenance',
        description: 'Average maintenance and repair cost by vehicle age, scaled by class.',
        value: 'by age ${byAge.map((v) => v.toStringAsFixed(0)).join(', ')}',
        source: OwnershipTables.source,
        asOf: OwnershipTables.asOf,
      ),
      Assumption(
        key: 'tco.energy_price',
        description: input.fuelType == FuelType.electric
            ? 'Electricity price per kWh.'
            : 'Fuel price per gallon.',
        value: input.fuelType == FuelType.electric
            ? input.electricityPerKwh.toStringAsFixed(2)
            : input.fuelPricePerGallon.toStringAsFixed(2),
        source: 'user or default',
        asOf: OwnershipTables.asOf,
      ),
    ],
  );
}

/// Clamps a year index into `0..length-1`.
///
/// The tables cover ten years; an index past the end reuses the last year, so
/// a long window or an old vehicle keeps paying the final year's figure rather
/// than throwing. `num.clamp` returns `num`, hence the hand-rolled version.
int _index(int i, int length) => i < 0 ? 0 : (i >= length ? length - 1 : i);
