import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

const sample = '''
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

void main() {
  final now = DateTime(2026, 10, 5);

  test('extracts title, price and mileage from a results page', () {
    final listings = const ListingExtractor().extract(
      sample,
      sourceUrl: 'https://example.com/r',
      now: now,
    );
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

  test('store searches by price, keywords and limit, cheapest first', () {
    final store = ListingStore()
      ..addAll(const ListingExtractor().extract(sample, sourceUrl: 'u', now: now));
    expect(store.search(maxPrice: 30000).map((l) => l.title), [
      '2019 Toyota RAV4 XLE',
      '2021 Honda CR-V EX-L',
    ]);
    expect(store.search(keywords: 'ford').single.title, '2020 Ford Explorer XLT');
    expect(store.search(limit: 1).single.price, 23450);
    store.addAll(const ListingExtractor().extract(sample, sourceUrl: 'u', now: now));
    expect(store.all, hasLength(3)); // no duplicates
  });

  test('facts from a single listing page', () {
    final f = extractFacts('2019 Honda Civic LX. Price \$16,990. 52,340 miles. Was \$17,500.');
    expect(f['prices'], [16990, 17500]);
    expect(f['mileage'], 52340);
    expect(f['year'], 2019);
  });

  test('curated search URLs are well formed', () {
    final u = CuratedSites.echopark.search(maxPrice: 50000, bodyStyle: 'suv');
    expect(u, 'https://www.echopark.com/used-cars?bodyStyle=SUV&maxPrice=50000');
    expect(CuratedSites.carsDotCom.search(keywords: 'honda crv'), contains('keyword=honda+crv'));
    expect(CuratedSites.defaultSite.id, 'echopark');
  });

  test('extracts EchoPark-style cards: year line, mileage, stock, title, price', () {
    const page = '''
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
    final listings = const ListingExtractor().extract(
      page,
      sourceUrl: 'https://www.echopark.com/used-cars',
      now: now,
    );
    expect(listings.map((l) => l.title), [
      '2023 BMW 5 Series 530i xDrive',
      '2025 Ford Mustang EcoBoost Premium',
      '2020 Honda CR-V Hybrid EX-L',
    ]);
    expect(listings[0].price, 34997);
    expect(listings[0].mileage, 35000);
    expect(listings[2].mileage, 114000);
    expect(listings[1].make, 'Ford');
    expect(listings[1].model, 'Mustang EcoBoost Premium');
  });
}
