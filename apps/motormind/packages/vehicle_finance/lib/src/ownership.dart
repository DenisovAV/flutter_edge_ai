import 'assumption.dart';
import 'money.dart';
import 'vehicle_class.dart';

enum FuelType { gasoline, hybrid, electric }

enum InsuranceBand { low, average, high }

class OwnershipInputs {
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

  final VehicleClass vehicleClass;
  final double purchasePrice;
  final int milesPerYear;
  final FuelType fuelType;

  /// MPG for gasoline and hybrid; miles per kWh for electric.
  final double efficiency;
  final int years;

  /// Age at purchase; drives the depreciation curve start and maintenance.
  final int vehicleAgeYears;
  final double fuelPricePerGallon;
  final double electricityPerKwh;
  final InsuranceBand insuranceBand;
  final double salesTaxRate;
  final double annualRegistration;

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

/// ROUGH tables. Every number below is a placeholder in a plausible range and
/// is labeled illustrative in the result. Replace with sourced values (TQ13).
class OwnershipTables {
  const OwnershipTables();

  static const String source = 'PLACEHOLDER rough national averages; see TQ13';
  static const String asOf = '2026-10-04';

  /// Fraction of the *original* value lost by the end of each ownership year,
  /// cumulative, for a vehicle bought new. Used vehicles start partway along.
  static const List<double> cumulativeDepreciation = [0.20, 0.31, 0.40, 0.48, 0.55, 0.60, 0.65, 0.69, 0.72, 0.75];

  /// Annual maintenance and repairs by vehicle age in years.
  static const List<double> maintenanceByAge = [400, 500, 650, 850, 1050, 1250, 1450, 1650, 1850, 2000];

  static const Map<InsuranceBand, double> annualInsurance = {
    InsuranceBand.low: 1200,
    InsuranceBand.average: 1900,
    InsuranceBand.high: 2800,
  };

  static const Map<VehicleClass, double> classMaintenanceMultiplier = {
    VehicleClass.car: 1.0,
    VehicleClass.suv: 1.15,
    VehicleClass.pickup: 1.2,
    VehicleClass.van: 1.1,
  };
}

class OwnershipEstimate extends CalcResult {
  OwnershipEstimate({
    required OwnershipInputs input,
    required this.depreciation,
    required this.fuelOrEnergy,
    required this.insurance,
    required this.maintenance,
    required this.taxesAndFees,
    required super.assumptions,
  }) : super(inputs: input.toJson());

  final double depreciation;
  final double fuelOrEnergy;
  final double insurance;
  final double maintenance;
  final double taxesAndFees;

  double get total => roundCents(depreciation + fuelOrEnergy + insurance + maintenance + taxesAndFees);

  double perMonth(int years) => roundCents(total / (years * 12));

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

OwnershipEstimate estimateOwnership(OwnershipInputs input) {
  if (input.years <= 0) throw ArgumentError.value(input.years, 'years', 'must be positive');
  if (input.efficiency <= 0) throw ArgumentError.value(input.efficiency, 'efficiency', 'must be positive');

  // Depreciation: the share of today's price lost over the ownership window,
  // reading the cumulative curve from the vehicle's current age.
  final curve = OwnershipTables.cumulativeDepreciation;
  double lostAt(int age) => age <= 0 ? 0.0 : curve[_index(age - 1, curve.length)];
  final startLost = lostAt(input.vehicleAgeYears);
  final endLost = lostAt(input.vehicleAgeYears + input.years);
  // Today's price already reflects startLost; scale the remaining drop to it.
  final remainingShare = startLost >= 1 ? 0.0 : (endLost - startLost) / (1 - startLost);
  final depreciation = roundCents(input.purchasePrice * remainingShare);

  final totalMiles = input.milesPerYear * input.years;
  final fuel = switch (input.fuelType) {
    FuelType.electric => totalMiles / input.efficiency * input.electricityPerKwh,
    FuelType.gasoline || FuelType.hybrid => totalMiles / input.efficiency * input.fuelPricePerGallon,
  };

  final insurance = OwnershipTables.annualInsurance[input.insuranceBand]! * input.years;

  var maintenance = 0.0;
  final mult = OwnershipTables.classMaintenanceMultiplier[input.vehicleClass] ?? 1.0;
  for (var y = 0; y < input.years; y++) {
    final age = input.vehicleAgeYears + y;
    maintenance += OwnershipTables.maintenanceByAge[_index(age, OwnershipTables.maintenanceByAge.length)] * mult;
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
        description: 'Class-independent depreciation curve; real curves vary widely by model and market.',
        value: 'cumulative ${OwnershipTables.cumulativeDepreciation.join(', ')}',
        source: OwnershipTables.source,
        asOf: OwnershipTables.asOf,
      ),
      Assumption(
        key: 'tco.insurance',
        description: 'National-average annual premium for the ${input.insuranceBand.name} band; your quote will differ.',
        value: OwnershipTables.annualInsurance[input.insuranceBand]!.toStringAsFixed(0),
        source: OwnershipTables.source,
        asOf: OwnershipTables.asOf,
      ),
      Assumption(
        key: 'tco.maintenance',
        description: 'Average maintenance and repair cost by vehicle age, scaled by class.',
        value: 'by age ${OwnershipTables.maintenanceByAge.map((v) => v.toStringAsFixed(0)).join(', ')}',
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

/// Clamps [i] into `0..length-1` as an int (num.clamp returns num).
int _index(int i, int length) => i < 0 ? 0 : (i >= length ? length - 1 : i);
