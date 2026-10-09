import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  group('search URLs', () {
    test('EchoPark', () {
      expect(
        CuratedSites.echopark.search(maxPrice: 50000, bodyStyle: 'suv'),
        'https://www.echopark.com/used-cars?bodyStyle=SUV&maxPrice=50000',
      );
      expect(CuratedSites.echopark.search(), 'https://www.echopark.com/used-cars');
      expect(CuratedSites.echopark.search(bodyStyle: 'pickup'), contains('bodyStyle=Truck'));
    });

    test('Cars.com', () {
      expect(
        CuratedSites.carsDotCom.search(keywords: 'honda crv'),
        'https://www.cars.com/shopping/results/?stock_type=all&keyword=honda+crv',
      );
      expect(
        CuratedSites.carsDotCom.search(maxPrice: 20000, bodyStyle: 'sedan'),
        contains('list_price_max=20000&body_style_slugs[]=Sedan'),
      );
    });

    test('Autotrader', () {
      expect(
        CuratedSites.autotrader.search(
          maxPrice: 30000,
          bodyStyle: 'convertible',
          keywords: 'miata',
        ),
        'https://www.autotrader.com/cars-for-sale/all-cars'
        '?maxPrice=30000&vehicleStyleCodes=CONVERT&keywordPhrases=miata',
      );
      expect(CuratedSites.autotrader.search(), 'https://www.autotrader.com/cars-for-sale/all-cars');
    });

    test('every body style maps on every site; an unknown one passes through', () {
      for (final site in CuratedSites.all) {
        for (final style in SearchQuery.bodyStyles) {
          expect(site.search(bodyStyle: style), isNot(contains('=$style&')), reason: site.id);
        }
        expect(site.search(bodyStyle: 'spaceship'), contains('spaceship'));
      }
    });

    test('keywords are encoded', () {
      expect(CuratedSites.echopark.search(keywords: 'a&b c'), endsWith('search=a%26b+c'));
    });
  });

  group('urlFor', () {
    test('make, model and keywords share the keyword slot', () {
      const q = SearchQuery(bodyStyle: 'suv', maxPrice: 50000, make: 'Toyota');
      expect(
        CuratedSites.echopark.urlFor(q),
        'https://www.echopark.com/used-cars?bodyStyle=SUV&maxPrice=50000&search=Toyota',
      );
      expect(
        CuratedSites.carsDotCom.urlFor(
          const SearchQuery(make: 'Honda', model: 'CR-V', keywords: 'awd'),
        ),
        endsWith('keyword=Honda+CR-V+awd'),
      );
    });

    test('an empty query gives the plain results page', () {
      expect(
        CuratedSites.echopark.urlFor(const SearchQuery()),
        'https://www.echopark.com/used-cars',
      );
      expect(CuratedSites.autotrader.urlFor(const SearchQuery(keywords: '')), isNot(contains('?')));
    });
  });

  group('registry', () {
    test('byId and nameFor', () {
      expect(CuratedSites.byId('cars'), same(CuratedSites.carsDotCom));
      expect(CuratedSites.byId('craigslist'), isNull);
      expect(CuratedSites.nameFor('echopark'), 'EchoPark');
      expect(CuratedSites.nameFor('example.com'), 'example.com');
    });

    test('default site and picker order', () {
      expect(CuratedSites.defaultSite.id, 'echopark');
      expect(CuratedSites.all.map((s) => s.id), ['echopark', 'cars', 'autotrader']);
      expect(CuratedSites.all.clear, throwsUnsupportedError);
    });
  });
}
