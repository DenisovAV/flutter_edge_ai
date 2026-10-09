import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

final _now = DateTime(2026, 10, 6);

VehicleListing _listing(
  String id,
  String title, {
  double? price,
  int? mileage,
  int? year,
  String? bodyStyle,
}) => VehicleListing(
  id: id,
  title: title,
  sourceUrl: 'u',
  readAt: _now,
  price: price,
  mileage: mileage,
  year: year,
  bodyStyle: bodyStyle,
);

void main() {
  late ListingStore store;
  setUp(() {
    store = ListingStore()
      ..addAll([
        _listing('a', '2021 Honda CR-V EX', price: 27995, mileage: 45000, year: 2021),
        _listing('b', '2018 Toyota RAV4', price: 18500, mileage: 90000, year: 2018),
        _listing('c', '2023 BMW X3', price: 41000, mileage: 20000, year: 2023, bodyStyle: 'suv'),
        _listing('d', '2020 Ford Mustang GT', year: 2020),
      ]);
  });

  group('searchQuery', () {
    test('filters by price, cheapest first; unpriced listings never match a bound', () {
      expect(store.searchQuery(const SearchQuery(maxPrice: 30000)).map((l) => l.id), ['b', 'a']);
      expect(store.searchQuery(const SearchQuery(minPrice: 20000)).map((l) => l.id), ['a', 'c']);
      expect(store.searchQuery(const SearchQuery()).map((l) => l.id), ['b', 'a', 'c', 'd']);
    });

    test('filters by year and mileage; a listing without them passes', () {
      expect(store.searchQuery(const SearchQuery(minYear: 2021)).map((l) => l.id), ['a', 'c']);
      expect(store.searchQuery(const SearchQuery(maxMileage: 50000)).map((l) => l.id), [
        'a',
        'c',
        'd',
      ]);
      expect(store.searchQuery(const SearchQuery(maxMileage: 50000), limit: 1).single.id, 'a');
    });

    test('make and model must be in the title; any keyword may', () {
      expect(store.searchQuery(const SearchQuery(make: 'toyota')).single.id, 'b');
      expect(store.searchQuery(const SearchQuery(make: 'Honda', model: 'Civic')), isEmpty);
      expect(store.searchQuery(const SearchQuery(keywords: 'mustang rav4')).map((l) => l.id), [
        'b',
        'd',
      ]);
      expect(store.searchQuery(const SearchQuery(keywords: 'tesla')), isEmpty);
    });

    test('body style is not applied: the site filters it, the readers do not read it', () {
      expect(store.searchQuery(const SearchQuery(bodyStyle: 'coupe')), hasLength(4));
    });
  });

  group('addAll', () {
    test('drops a listing whose dedupe key is already stored', () {
      store.addAll([
        _listing('x', '2021 Honda CR-V EX', price: 27995, mileage: 45000),
        _listing('y', '2021 Honda CR-V EX', price: 26995, mileage: 45000),
      ]);
      expect(store.all.map((l) => l.id), ['a', 'b', 'c', 'd', 'y']);
    });

    test('clear forgets the keys as well as the listings', () {
      store.clear();
      expect(store.isEmpty, isTrue);
      store.addAll([_listing('a', '2021 Honda CR-V EX', price: 27995, mileage: 45000)]);
      expect(store.all, hasLength(1));
    });

    test('all is a snapshot that cannot change the store', () {
      expect(() => store.all.clear(), throwsUnsupportedError);
      expect(store.all, hasLength(4));
    });
  });

  test('dedupeKey is title, price and mileage, not id, URL or read time', () {
    final a = _listing('a', '2021 Honda CR-V EX', price: 27995, mileage: 45000);
    final b = VehicleListing(
      id: 'b',
      title: '2021 Honda CR-V EX',
      sourceUrl: 'elsewhere',
      readAt: DateTime(2030),
      price: 27995,
      mileage: 45000,
    );
    expect(a.dedupeKey, b.dedupeKey);
    expect(a.dedupeKey, isNot(_listing('a', '2021 Honda CR-V EX', price: 27995).dedupeKey));
  });
}
