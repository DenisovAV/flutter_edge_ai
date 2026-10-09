import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

void main() {
  group('creditBandForScore', () {
    test('maps a score to its band at the boundaries', () {
      expect(creditBandForScore(850), CreditBand.excellent);
      expect(creditBandForScore(781), CreditBand.excellent);
      expect(creditBandForScore(780), CreditBand.good);
      expect(creditBandForScore(661), CreditBand.good);
      expect(creditBandForScore(660), CreditBand.fair);
      expect(creditBandForScore(601), CreditBand.fair);
      expect(creditBandForScore(600), CreditBand.poor);
      expect(creditBandForScore(501), CreditBand.poor);
      expect(creditBandForScore(500), CreditBand.rebuilding);
    });

    test('clamps scores outside the bands into the end bands', () {
      expect(creditBandForScore(0), CreditBand.rebuilding);
      expect(creditBandForScore(299), CreditBand.rebuilding);
      expect(creditBandForScore(851), CreditBand.excellent);
      expect(creditBandForScore(999), CreditBand.excellent);
    });
  });

  group('CreditBand.parse', () {
    test('ignores case and whitespace', () {
      expect(CreditBand.parse(' Good '), CreditBand.good);
    });

    test('rejects an unknown band', () {
      expect(() => CreditBand.parse('prime'), throwsArgumentError);
    });
  });

  group('defaultAprTable', () {
    test('is labeled illustrative, sourced, and round-trips through JSON', () {
      expect(defaultAprTable.illustrative, isTrue);
      expect(defaultAprTable.source, contains('Experian'));
      final json = defaultAprTable.toJson();
      final back = AprTable.fromJson(json);
      expect(back.aprFor(CreditBand.fair, isNew: false), 0.1393);
      final a = back.assumptionFor(CreditBand.good, isNew: true);
      expect(a.key, 'apr.new.good');
      expect(a.value, '6.15%');
      expect(a.illustrative, isTrue);
    });

    test('covers every band', () {
      for (final band in CreditBand.values) {
        expect(defaultAprTable.rates, contains(band));
      }
    });

    test('used rates are never below new rates, and rates rise as credit falls', () {
      final bands = CreditBand.values;
      for (var i = 1; i < bands.length; i++) {
        expect(
          defaultAprTable.aprFor(bands[i], isNew: true),
          greaterThan(defaultAprTable.aprFor(bands[i - 1], isNew: true)),
        );
      }
      for (final r in defaultAprTable.rates.values) {
        expect(r.usedVehicle, greaterThanOrEqualTo(r.newVehicle));
      }
    });
  });

  group('AprTable.fromJson', () {
    test('rejects a table that is missing a band, naming it', () {
      final json = defaultAprTable.toJson();
      final rates = Map<String, Object?>.of(json['rates'] as Map<String, Object?>)..remove('poor');
      final incomplete = {...json, 'rates': rates};
      expect(
        () => AprTable.fromJson(incomplete),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('poor'))),
      );
    });
  });
}
