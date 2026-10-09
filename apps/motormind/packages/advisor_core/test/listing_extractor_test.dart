import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

const _resultsPage = '''
Filters
Sort by: Best match
Used 2021 Honda CR-V EX-L
45,210 mi
\$27,995
\$489/mo est.
Charlotte, NC
2019 Toyota RAV4 XLE
Great Price
\$23,450
61,002 miles
2020 Ford Explorer XLT
\$31,990
Monthly payment \$540/mo
Next page
Used 2018 Subaru Outback
No price listed
''';

const _echoParkPage = '''
334 used cars at EchoPark
Favorite Icon
2023
|
35K mi
|
Stock #: PPWY18150
BMW 5 Series 530i xDrive
Price
\$34,997
Document & other fees (if applicable)
\$799
Price drop
-\$4,000
Total Transparent Price
\$31,796
Pickup at
Charlotte (3 mi)
Schedule test drive
Favorite Icon
Just dropped \$2,200
2025
|
29K mi
|
Stock #: RS5120864
Ford Mustang EcoBoost Premium
Price
\$31,497
Favorite Icon
2020
|
114K mi
|
Stock #: CLE027433
Honda CR-V Hybrid EX-L
Price
\$21,997
''';

void main() {
  final now = DateTime(2026, 10, 5);
  List<VehicleListing> extract(String text, {int? max}) =>
      (max == null ? const ListingExtractor() : ListingExtractor(maxListings: max)).extract(
        text,
        sourceUrl: 'https://example.com/r',
        now: now,
      );

  group('title-first pages', () {
    test('extracts title, price and mileage; a monthly figure is never the price', () {
      final listings = extract(_resultsPage);
      expect(listings.map((l) => l.title), [
        '2021 Honda CR-V EX-L',
        '2019 Toyota RAV4 XLE',
        '2020 Ford Explorer XLT',
      ]);
      expect(listings[0].price, 27995);
      expect(listings[0].mileage, 45210);
      expect(listings[1].mileage, 61002);
      expect(listings[2].mileage, isNull);
      expect(listings[2].price, 31990); // not the \$540/mo figure
      expect(listings.every((l) => l.sourceUrl == 'https://example.com/r'), isTrue);
    });

    test('a card whose only figure is a monthly payment has no price and is skipped', () {
      expect(extract('2020 Kia Soul LX\n\$199/mo\n2021 Kia Soul S\n\$18,500\n'), hasLength(1));
    });

    test('an owner count before the odometer is not the mileage', () {
      final l = extract('2021 Honda Civic Si\n1 Owner, 34,210 mi\n\$24,998\n').single;
      expect(l.mileage, 34210);
    });

    test('a stock number is neither a price nor a mileage', () {
      final l = extract('2019 Mazda CX-5 Touring\nStock 18150\n\$19,450\n').single;
      expect(l.price, 19450);
      expect(l.mileage, isNull);
    });

    test('two-word makes split where the make ends; acronym makes keep their case', () {
      final listings = extract(
        '2022 Land Rover Range Rover Sport\n\$61,000\n2018 BMW 230i\n\$22,000\n2020 Chevy Bolt\n\$15,000\n',
      );
      expect(listings[0].make, 'Land Rover');
      expect(listings[0].model, 'Range Rover Sport');
      expect(listings[1].make, 'BMW');
      expect(listings[1].model, '230i');
      expect(listings[2].make, 'Chevrolet');
      expect(listings[2].title, '2020 Chevy Bolt');
    });

    test('the same card read twice is one listing; maxListings caps the rest', () {
      final twice = '$_resultsPage\n$_resultsPage';
      expect(extract(twice), hasLength(3));
      expect(extract(twice, max: 2), hasLength(2));
    });
  });

  group('year-first (EchoPark) cards', () {
    test('year line, mileage, stock, title, then the price after the label', () {
      final listings = extract(_echoParkPage);
      expect(listings.map((l) => l.title), [
        '2023 BMW 5 Series 530i xDrive',
        '2025 Ford Mustang EcoBoost Premium',
        '2020 Honda CR-V Hybrid EX-L',
      ]);
      expect(listings[0].price, 34997);
      expect(listings[0].mileage, 35000);
      expect(listings[0].make, 'BMW');
      expect(listings[2].mileage, 114000);
      expect(listings[1].make, 'Ford');
      expect(listings[1].model, 'Mustang EcoBoost Premium');
    });

    test('a two-word make on a yearless title line', () {
      final l = extract(
        '2021\n40K mi\nStock #: X1\nLand Rover Defender 110\nPrice\n\$55,000\n',
      ).single;
      expect(l.make, 'Land Rover');
      expect(l.model, 'Defender 110');
      expect(l.title, '2021 Land Rover Defender 110');
    });
  });

  group('extractListingFacts', () {
    test('prices in order, deduped; first mileage and year', () {
      final f = extractListingFacts(
        '2019 Honda Civic LX. Price \$16,990. 52,340 miles. Was \$17,500. Now \$16,990.',
      );
      expect(f.prices, [16990, 17500]);
      expect(f.mileage, 52340);
      expect(f.year, 2019);
      expect(f.toJson(), {
        'prices': [16990, 17500],
        'mileage': 52340,
        'year': 2019,
      });
    });

    test('fees, payments and VIN-sized figures are not prices; at most five are kept', () {
      final f = extractListingFacts(
        'Doc fee \$799. \$430/mo. \$1,200,000 house. '
        '\$10,000 \$11,000 \$12,000 \$13,000 \$14,000 \$15,000 \$16,000',
      );
      expect(f.prices, [10000, 11000, 12000, 13000, 14000]);
      expect(f.prices.length, PageFacts.maxPrices);
    });

    test('a page with nothing is empty', () {
      final f = extractListingFacts('Welcome to the dealership.');
      expect(f.isEmpty, isTrue);
      expect(f.toJson(), isEmpty);
    });
  });
}
