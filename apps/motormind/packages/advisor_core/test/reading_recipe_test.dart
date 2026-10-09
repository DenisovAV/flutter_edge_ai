import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:html/dom.dart' show Element;
import 'package:html/parser.dart' show parse;
import 'package:test/test.dart';

/// Reads a file by a path relative to the package root, which is where
/// `dart test` runs; the recipe assets live two directories up in the app.
String _read(String path) => File(path).readAsStringSync();

ReadingRecipe _recipe(String json) =>
    ReadingRecipe.fromJson((jsonDecode(json) as Map).cast<String, Object?>());

/// The first element of an HTML fragment, standing in for a card when a
/// [FieldRule] is exercised on its own (selectors match descendants only).
Element _element(String html) => parse(html).body!.children.first;

/// A Cars.com-shaped results page with the given card bodies.
String _page(List<String> cards, {String total = '3,412 matches'}) =>
    '<html><body><span class="total-entries">$total</span>'
    '${cards.map((c) => '<div class="vehicle-card">$c</div>').join()}</body></html>';

String _card(
  String title, {
  String? price = r'$20,000',
  String? mileage = '30,000 mi.',
  String? img = '<img class="vehicle-image" src="https://img.example.com/x.jpg">',
}) =>
    '<h2 class="title">$title</h2>'
    '${mileage == null ? '' : '<div class="mileage">$mileage</div>'}'
    '${price == null ? '' : '<span class="primary-price">$price</span>'}'
    '${img ?? ''}';

void main() {
  final now = DateTime(2026, 10, 6);
  final cars = _recipe(_read('../../assets/recipes/cars.json'));
  final html = _read('test/fixtures/cars_results_synthetic.html');
  const url = 'https://www.cars.com/shopping/results/';
  RecipeResult read(String html, {ReadingRecipe? recipe, int? max}) =>
      RecipeReader(maxListings: max ?? 40).read(html, recipe ?? cars, sourceUrl: url, now: now);

  group('reading cards', () {
    test('a recipe reads cards, prices, mileage, images and links from HTML', () {
      final r = read(html);
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
      // Lazy-loaded image attributes are read too.
      expect(r.listings[1].imageUrl, 'https://img.example.com/abc222.jpg');
      expect(r.listings[1].mileage, 52000);
      // "Not Priced" is no price.
      expect(r.listings[3].price, isNull);
      expect(r.check.ok, isTrue, reason: r.check.toString());
      expect(r.check.pageTotal, 3412);
      expect(r.check.withImage, 3);
    });

    test('srcset gives the largest candidate, the one worth a card', () {
      expect(read(html).listings[2].imageUrl, 'https://img.example.com/abc333-640.jpg');
      const rule = FieldRule(selector: 'img', attrs: ['srcset']);
      String? pick(String srcset) => rule.read(_element('<div><img srcset="$srcset"></div>'));
      expect(pick('/a-640.jpg 640w, /a-320.jpg 320w'), '/a-640.jpg');
      expect(pick('/a.jpg 1x, /a@2x.jpg 2x'), '/a.jpg');
      expect(pick('/one.jpg?w=1,h=2 100w, /two.jpg 200w'), '/two.jpg');
    });

    test('a price node that also shows a monthly figure gives the asking price', () {
      final r = read(_page([_card('2021 Honda Civic Si', price: r'$24,998 $430/mo est.')]));
      expect(r.listings.single.price, 24998);
    });

    test('a relative image src resolves against the page; no image is no image', () {
      final r = read(
        _page([
          _card('2021 Honda Civic Si', img: '<img class="vehicle-image" src="/img/a.jpg">'),
          _card('2020 Honda Civic LX', img: null),
        ]),
      );
      expect(r.listings[0].imageUrl, 'https://www.cars.com/img/a.jpg');
      expect(r.listings[1].imageUrl, isNull);
      expect(r.check.withImage, 1);
    });

    test('a FieldRule pattern keeps its first group, or the whole match', () {
      const grouped = FieldRule(selector: '.mileage', pattern: r'([\d,]+)\s*mi');
      const whole = FieldRule(selector: '.mileage', pattern: r'\d[\d,]*');
      final el = _element('<div><div class="mileage">Odometer: 30,000 mi.</div></div>');
      expect(grouped.read(el), '30,000');
      expect(whole.read(el), '30,000');
      expect(const FieldRule(selector: '.mileage', pattern: r'\d+ km').read(el), isNull);
    });

    test('a recipe year field wins over the title; a bad one falls back', () {
      final withYear = ReadingRecipe(
        siteId: 'x',
        version: 1,
        card: 'div.vehicle-card',
        fields: {
          ...cars.fields,
          'year': const FieldRule(selector: '.year'),
        },
      );
      final r = read(
        _page([
          '${_card('2021 Honda Civic Si')}<span class="year">2022</span>',
          '${_card('2021 Honda Civic LX')}<span class="year">soon</span>',
        ]),
        recipe: withYear,
      );
      expect(r.listings[0].year, 2022);
      expect(r.listings[1].year, 2021);
    });

    test('duplicate cards collapse and maxListings caps the read', () {
      final cards = [for (var i = 0; i < 6; i++) _card('2021 Honda Civic Si')];
      expect(read(_page(cards)).listings, hasLength(1));
      final distinct = [for (var i = 0; i < 6; i++) _card('2021 Honda Civic $i')];
      expect(read(_page(distinct), max: 4).listings, hasLength(4));
    });
  });

  group('self-check', () {
    test('fails loudly when the site changed its markup', () {
      final r = read(html.replaceAll('vehicle-card', 'listing-tile'));
      expect(r.listings, isEmpty);
      expect(r.check.ok, isFalse);
      expect(r.check.problems.single, contains('no elements match card selector'));
    });

    test('a half-working read (prices gone) is a failure, not a success', () {
      final r = read(html.replaceAll('primary-price', 'gone'));
      expect(r.listings, hasLength(4));
      expect(r.check.ok, isFalse);
      expect(r.check.problems.join(), contains('had a price'));
    });

    test('too few titled cards says so; a dedupe drop is not "no title"', () {
      final untitled = read(_page([_card('2021 Honda Civic Si'), '<p>ad</p>', '<p>ad</p>']));
      expect(untitled.check.problems, [
        'read 1 listings but the recipe expects at least 3',
        '3 cards matched but only 1 had a title',
      ]);
      final repeated = read(_page([_card('2021 Honda Civic Si'), _card('2021 Honda Civic Si')]));
      expect(repeated.check.problems, [
        'read 1 listings but the recipe expects at least 3',
        '1 cards repeated an earlier listing',
      ]);
    });

    test('minImageFraction', () {
      final r = read(_page([for (var i = 0; i < 4; i++) _card('2021 Honda Civic $i', img: null)]));
      expect(r.check.ok, isFalse);
      expect(r.check.problems.single, 'only 0 of 4 cards had an image');
    });

    test('reading more cards than the page claims is suspicious', () {
      final zero = read(html.replaceAll('3,412 matches', '0 matches'));
      expect(zero.check.ok, isFalse);
      expect(zero.check.problems.join(), contains('page says 0 results'));
      final two = read(html.replaceAll('3,412 matches', '2 matches'));
      expect(two.check.problems.single, 'read 4 cards but the page says 2 results');
    });

    test('maxTotalRatio allows a read above the page total within the ratio', () {
      final lenient = ReadingRecipe(
        siteId: 'x',
        version: 1,
        card: cars.card,
        fields: cars.fields,
        selfCheck: const SelfCheckRules(
          minPriceFraction: 0.7,
          totalPattern: r'([\d,]+)\s+matches',
          maxTotalRatio: 2.0,
        ),
      );
      final r = read(html.replaceAll('3,412 matches', '2 matches'), recipe: lenient);
      expect(r.check.ok, isTrue, reason: r.check.toString());
      expect(r.check.pageTotal, 2);
    });
  });

  group('JSON', () {
    test('recipes round-trip so a repaired one can be dropped in', () {
      final again = ReadingRecipe.fromJson(cars.toJson());
      expect(again.toJson(), cars.toJson());
      expect(again.status, RecipeStatus.unverified);
      expect(cars.toJson()['status'], 'unverified');
    });

    test('status names are the lowercase enum names; an unknown one is refused', () {
      expect(_recipe('{"siteId":"x","card":"a","fields":{}}').status, RecipeStatus.verified);
      expect(
        _recipe('{"siteId":"x","card":"a","fields":{},"status":"broken"}').status,
        RecipeStatus.broken,
      );
      expect(
        () => _recipe('{"siteId":"x","card":"a","fields":{},"status":"ok"}'),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('status'))),
      );
    });

    test('a malformed recipe names the field instead of throwing a TypeError', () {
      Matcher fails(String fragment) =>
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(fragment)));
      expect(() => _recipe('{"card":"a","fields":{}}'), fails('"siteId" is required'));
      expect(() => _recipe('{"siteId":"x","fields":{}}'), fails('"card" is required'));
      expect(() => _recipe('{"siteId":"x","card":"a"}'), fails('"fields" is required'));
      expect(
        () => _recipe('{"siteId":1,"card":"a","fields":{}}'),
        fails('"siteId" must be a String'),
      );
      expect(
        () => _recipe('{"siteId":"x","card":"a","fields":{"title":"h2"}}'),
        fails('recipe.fields.title must be an object'),
      );
      expect(
        () => _recipe('{"siteId":"x","card":"a","fields":{},"selfCheck":{"minCards":"many"}}'),
        fails('"minCards" must be a num'),
      );
    });

    test('a singular attr is accepted and written back as attrs', () {
      final rule = FieldRule.fromJson({
        'selector': 'img',
        'attr': 'src',
        'attrs': ['data-src'],
      });
      expect(rule.attrs, ['src', 'data-src']);
      expect(rule.toJson(), {
        'selector': 'img',
        'attrs': ['src', 'data-src'],
      });
      expect(const FieldRule().toJson(), {'selector': ''});
      expect(() => FieldRule.fromJson({'attrs': 'src'}), throwsFormatException);
    });

    test('SelfCheck round-trips and leaves an unknown page total out', () {
      const check = SelfCheck(
        ok: false,
        cardsFound: 2,
        withPrice: 1,
        withImage: 0,
        problems: ['x'],
      );
      expect(check.toJson().containsKey('pageTotal'), isFalse);
      expect(SelfCheck.fromJson(check.toJson()).toJson(), check.toJson());
      expect(check.toString(), 'failed: x');
    });
  });

  group('withStatus', () {
    test('replaces the status; the note is kept, replaced or cleared', () {
      final r = cars.withStatus(RecipeStatus.broken, note: 'prices gone');
      expect(r.status, RecipeStatus.broken);
      expect(r.note, 'prices gone');
      expect(r.withStatus(RecipeStatus.verified).note, 'prices gone');
      expect(r.withStatus(RecipeStatus.verified, note: null).note, isNull);
      expect(r.version, cars.version);
      expect(r.fields, same(cars.fields));
    });
  });
}
