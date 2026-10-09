import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

void main() {
  group('estimateOwnership', () {
    test('five-year estimate is the sum of its parts and carries assumptions', () {
      final e = estimateOwnership(
        const OwnershipInputs(
          vehicleClass: VehicleClass.suv,
          purchasePrice: 28000,
          milesPerYear: 12000,
          fuelType: FuelType.gasoline,
          efficiency: 25,
          salesTaxRate: 0.07,
        ),
      );
      expect(e.years, 5);
      expect(e.fuelOrEnergy, 8400); // 60000 miles / 25 mpg * 3.50
      expect(e.insurance, 9500);
      expect(e.depreciation, closeTo(28000 * 0.55, 0.01));
      expect(e.taxesAndFees, closeTo(28000 * 0.07 + 750, 0.01));
      expect(
        e.total,
        closeTo(
          e.depreciation + e.fuelOrEnergy + e.insurance + e.maintenance + e.taxesAndFees,
          0.01,
        ),
      );
      expect(e.perMonth, closeTo(e.total / 60, 0.01));
      expect(e.assumptions.every((a) => a.illustrative), isTrue);
    });

    test('a used vehicle depreciates less in absolute terms than the same price new', () {
      const base = OwnershipInputs(
        vehicleClass: VehicleClass.car,
        purchasePrice: 20000,
        milesPerYear: 10000,
        fuelType: FuelType.hybrid,
        efficiency: 45,
      );
      final newer = estimateOwnership(base);
      final older = estimateOwnership(
        const OwnershipInputs(
          vehicleClass: VehicleClass.car,
          purchasePrice: 20000,
          milesPerYear: 10000,
          fuelType: FuelType.hybrid,
          efficiency: 45,
          vehicleAgeYears: 4,
        ),
      );
      expect(older.depreciation, lessThan(newer.depreciation));
      expect(older.maintenance, greaterThan(newer.maintenance));
    });

    test('electric uses miles per kWh and electricity price', () {
      final e = estimateOwnership(
        const OwnershipInputs(
          vehicleClass: VehicleClass.car,
          purchasePrice: 35000,
          milesPerYear: 10000,
          fuelType: FuelType.electric,
          efficiency: 4,
          years: 1,
          electricityPerKwh: 0.20,
        ),
      );
      expect(e.fuelOrEnergy, 500); // 10000 / 4 * 0.20
      expect(e.perMonth, closeTo(e.total / 12, 0.01));
    });

    test('a window past the tables reuses the last year rather than throwing', () {
      final e = estimateOwnership(
        const OwnershipInputs(
          vehicleClass: VehicleClass.car,
          purchasePrice: 20000,
          milesPerYear: 10000,
          fuelType: FuelType.gasoline,
          efficiency: 30,
          years: 12,
        ),
      );
      expect(e.years, 12);
      // The curve ends at 0.75; years 11 and 12 add nothing more.
      expect(e.depreciation, closeTo(20000 * 0.75, 0.01));
      // Ages 10 and 11 reuse the 2000 final-year maintenance figure.
      expect(
        e.maintenance,
        closeTo(OwnershipTables.maintenanceByAge.fold<double>(0, (s, v) => s + v) + 2000 * 2, 0.01),
      );
      expect(e.insurance, 1900 * 12);
      expect(e.perMonth, closeTo(e.total / 144, 0.01));
    });

    test('rejects a non-positive window', () {
      expect(
        () => estimateOwnership(
          const OwnershipInputs(
            vehicleClass: VehicleClass.car,
            purchasePrice: 20000,
            milesPerYear: 10000,
            fuelType: FuelType.gasoline,
            efficiency: 30,
            years: 0,
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
