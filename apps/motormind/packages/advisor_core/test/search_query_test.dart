import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  test('inference maps everyday words to filters', () {
    expect(inferSearchArgs('I want a sports car under 40k'), {
      'body_style': 'coupe',
      'max_price': 40000,
    });
    expect(inferSearchArgs('a dream car, money is no object'), containsPair('max_price', null));
    expect(
      inferSearchArgs('something for the family, a minivan around \$30,000')['body_style'],
      'van',
    );
    expect(inferSearchArgs('a Toyota SUV under 100k miles, 2020 or newer'), {
      'body_style': 'suv',
      'make': 'Toyota',
      'max_mileage': 100000,
      'min_year': 2020,
    });
    expect(inferSearchArgs('hello there'), isEmpty);
  });

  test('applyArgs sets, clears and normalizes', () {
    var q = const SearchQuery().applyArgs({
      'body_style': 'sporty',
      'max_price': '50k',
      'make': 'Honda',
    });
    expect(q.bodyStyle, 'coupe');
    expect(q.maxPrice, 50000);
    expect(q.make, 'Honda');
    q = q.applyArgs({'max_price': 'any', 'body_style': null});
    expect(q.maxPrice, isNull);
    expect(q.bodyStyle, isNull);
    expect(q.make, 'Honda');
    expect(q.describe(), 'Honda');
  });

  test('describe and site URL follow the query', () {
    const q = SearchQuery(bodyStyle: 'suv', maxPrice: 50000, make: 'Toyota');
    expect(q.describe(), 'Toyota · SUV · under \$50k');
    expect(
      CuratedSites.echopark.urlFor(q),
      'https://www.echopark.com/used-cars?bodyStyle=SUV&maxPrice=50000&search=Toyota',
    );
  });

  test('store searchQuery filters by price, year, mileage and make', () {
    final now = DateTime(2026, 10, 6);
    final store = ListingStore()
      ..addAll([
        VehicleListing(
          id: 'a',
          title: '2021 Honda CR-V EX',
          sourceUrl: 'u',
          readAt: now,
          price: 27995,
          mileage: 45000,
          year: 2021,
          make: 'Honda',
        ),
        VehicleListing(
          id: 'b',
          title: '2018 Toyota RAV4',
          sourceUrl: 'u',
          readAt: now,
          price: 18500,
          mileage: 90000,
          year: 2018,
          make: 'Toyota',
        ),
        VehicleListing(
          id: 'c',
          title: '2023 BMW X3',
          sourceUrl: 'u',
          readAt: now,
          price: 41000,
          mileage: 20000,
          year: 2023,
          make: 'BMW',
        ),
      ]);
    expect(store.searchQuery(const SearchQuery(maxPrice: 30000)).map((l) => l.id), ['b', 'a']);
    expect(store.searchQuery(const SearchQuery(minYear: 2021)).map((l) => l.id), ['a', 'c']);
    expect(store.searchQuery(const SearchQuery(make: 'toyota')).single.id, 'b');
    expect(store.searchQuery(const SearchQuery(maxMileage: 50000), limit: 1).single.id, 'a');
  });

  test('long option labels and too many options are coerced, not refused', () {
    final v = PresentRequest.validate({
      'component': 'choice',
      'props': {
        'question': 'Which?',
        'options': [
          for (var i = 0; i < 9; i++)
            {'id': 'o\$i', 'label': 'option number \$i with a very long label that goes on and on'},
        ],
      },
    }, resultTool: null);
    expect(v.errors, isEmpty);
    expect((v.request!.props['options'] as List).length, 6);
  });
}
