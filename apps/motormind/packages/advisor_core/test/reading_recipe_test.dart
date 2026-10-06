import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

ReadingRecipe _load(String path) =>
    ReadingRecipe.fromJson((jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>());

void main() {
  final now = DateTime(2026, 10, 6);
  final cars = _load('../../assets/recipes/cars.json');
  final html = File('test/fixtures/cars_results_synthetic.html').readAsStringSync();

  test('a recipe reads cards, prices, mileage, images and links from HTML', () {
    final r = const RecipeReader().read(html, cars, sourceUrl: 'https://www.cars.com/shopping/results/', now: now);
    expect(r.listings, hasLength(4));
    final civic = r.listings.first;
    expect(civic.title, '2021 Honda Civic Si');
    expect(civic.year, 2021);
    expect(civic.make, 'Honda');
    expect(civic.model, 'Civic Si');
    expect(civic.price, 24998);
    expect(civic.mileage, 34210);
    expect(civic.imageUrl, 'https://img.example.com/abc111.jpg');
    expect(civic.detailUrl, 'https://www.cars.com/vehicledetail/abc111/');
    // Lazy-loaded image attributes and srcset are read too.
    expect(r.listings[1].imageUrl, 'https://img.example.com/abc222.jpg');
    expect(r.listings[1].mileage, 52000);
    expect(r.listings[2].imageUrl, 'https://img.example.com/abc333-320.jpg');
    // "Not Priced" is no price.
    expect(r.listings[3].price, isNull);
    expect(r.check.ok, isTrue, reason: r.check.toString());
    expect(r.check.pageTotal, 3412);
    expect(r.check.withImage, 3);
  });

  test('the self-check fails loudly when the site changed its markup', () {
    final changed = html.replaceAll('vehicle-card', 'listing-tile');
    final r = const RecipeReader().read(changed, cars, sourceUrl: 'https://www.cars.com/', now: now);
    expect(r.listings, isEmpty);
    expect(r.check.ok, isFalse);
    expect(r.check.problems.single, contains('no elements match card selector'));
  });

  test('a half-working read (prices gone) is a failure, not a success', () {
    final noPrices = html.replaceAll('primary-price', 'gone');
    final r = const RecipeReader().read(noPrices, cars, sourceUrl: 'https://www.cars.com/', now: now);
    expect(r.listings, hasLength(4));
    expect(r.check.ok, isFalse);
    expect(r.check.problems.join(), contains('had a price'));
  });

  test('reading more cards than the page claims is suspicious', () {
    final zero = html.replaceAll('3,412 matches', '0 matches');
    final r = const RecipeReader().read(zero, cars, sourceUrl: 'https://www.cars.com/', now: now);
    expect(r.check.ok, isFalse);
    expect(r.check.problems.join(), contains('page says 0 results'));
  });

  test('recipes round-trip through JSON so a repaired one can be dropped in', () {
    final again = ReadingRecipe.fromJson(cars.toJson());
    expect(again.card, cars.card);
    expect(again.fields.keys, cars.fields.keys);
    expect(again.selfCheck.totalPattern, cars.selfCheck.totalPattern);
    expect(again.status, 'unverified');
  });
}
