import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  group('inferSearchArgs', () {
    test('maps everyday words to filters', () {
      expect(inferSearchArgs('I want a sports car under 40k'), {
        'body_style': 'coupe',
        'max_price': 40000,
      });
      expect(inferSearchArgs('something for the family, a minivan around \$30,000'), {
        'body_style': 'van',
        'max_price': 30000,
      });
      expect(inferSearchArgs('a Toyota SUV under 100k miles, 2020 or newer'), {
        'body_style': 'suv',
        'make': 'Toyota',
        'max_mileage': 100000,
        'min_year': 2020,
      });
      expect(inferSearchArgs('hello there'), isEmpty);
    });

    test('a present null means clear the filter; absent means nothing said', () {
      final noBudget = inferSearchArgs('a dream car, money is no object');
      expect(noBudget.containsKey('max_price'), isTrue);
      expect(noBudget['max_price'], isNull);
      expect(inferSearchArgs('a red one').containsKey('max_price'), isFalse);
    });

    test('price ceilings: exact dollars, bare thousands and plain numbers', () {
      expect(inferSearchArgs('under \$9,500')['max_price'], 9500);
      expect(inferSearchArgs('under 20000')['max_price'], 20000);
      expect(inferSearchArgs('under 40')['max_price'], 40000);
      expect(inferSearchArgs('around 25.5k')['max_price'], 25500);
      expect(inferSearchArgs('\$25,000 budget')['max_price'], 25000);
    });

    test('a monthly payment is not a price ceiling', () {
      expect(inferSearchArgs('I can do \$430/mo').containsKey('max_price'), isFalse);
      expect(inferSearchArgs('under \$500 a month').containsKey('max_price'), isFalse);
      expect(inferSearchArgs('max \$450 per month').containsKey('max_price'), isFalse);
    });

    test('a year with a bound word is not a price', () {
      expect(inferSearchArgs('about 2020 or newer'), {'min_year': 2020});
    });

    test('mileage scales only with a k', () {
      expect(inferSearchArgs('under 500 miles')['max_mileage'], 500);
      expect(inferSearchArgs('under 60,000 miles')['max_mileage'], 60000);
      expect(inferSearchArgs('less than 80k mi')['max_mileage'], 80000);
      expect(inferSearchArgs('under 100k miles').containsKey('max_price'), isFalse);
    });

    test('makes get their display names; two-word and nickname makes are found', () {
      expect(inferSearchArgs('a bmw')['make'], 'BMW');
      expect(inferSearchArgs('a used land rover')['make'], 'Land Rover');
      expect(inferSearchArgs('a chevy truck')['make'], 'Chevrolet');
      expect(inferSearchArgs('a vw golf')['make'], 'Volkswagen');
      expect(inferSearchArgs('a mini cooper')['make'], 'MINI');
    });

    test('"mini van" is a body style, not the make', () {
      expect(inferSearchArgs('a mini van for the kids'), {'body_style': 'van'});
      expect(inferSearchArgs('a mini-van'), {'body_style': 'van'});
    });
  });

  group('normalizeBodyStyle', () {
    test('known words and an unknown one', () {
      expect(SearchQuery.normalizeBodyStyle('sporty'), 'coupe');
      expect(SearchQuery.normalizeBodyStyle('a crossover'), 'suv');
      expect(SearchQuery.normalizeBodyStyle('Minivans'), 'van');
      expect(SearchQuery.normalizeBodyStyle('estate'), 'wagon');
      expect(SearchQuery.normalizeBodyStyle('four-door'), 'sedan');
      expect(SearchQuery.normalizeBodyStyle('spaceship'), isNull);
    });

    test('the more specific word wins', () {
      expect(SearchQuery.normalizeBodyStyle('convertible sports car'), 'convertible');
      expect(SearchQuery.normalizeBodyStyle('a 4-door pickup'), 'pickup');
      expect(SearchQuery.normalizeBodyStyle('a van with a hatch'), 'van');
    });
  });

  group('applyArgs', () {
    test('sets, clears and normalizes', () {
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

    test('a trailing k means thousands for every number', () {
      final q = const SearchQuery().applyArgs({
        'max_mileage': '100k',
        'min_price': '10k',
        'max_price': '\$9,500',
        'min_year': '2019',
      });
      expect(q.maxMileage, 100000);
      expect(q.minPrice, 10000);
      expect(q.maxPrice, 9500);
      expect(q.minYear, 2019);
    });

    test('only a bare max_price below 1,000 is read as thousands', () {
      expect(const SearchQuery().applyArgs({'max_price': '50'}).maxPrice, 50000);
      expect(const SearchQuery().applyArgs({'max_price': 50}).maxPrice, 50000);
      expect(const SearchQuery().applyArgs({'max_price': 50000}).maxPrice, 50000);
      expect(const SearchQuery().applyArgs({'min_price': '5'}).minPrice, 5);
      expect(const SearchQuery().applyArgs({'max_mileage': '500'}).maxMileage, 500);
    });

    test('toJson round-trips through applyArgs, nulls included', () {
      const q = SearchQuery(make: 'Kia', maxPrice: 9500, maxMileage: 500);
      final back = const SearchQuery(bodyStyle: 'van').applyArgs(q.toJson());
      expect(back.toJson(), q.toJson());
    });
  });

  group('copyWith', () {
    test('an omitted field is kept; an explicit null clears it', () {
      const q = SearchQuery(make: 'Kia', maxPrice: 20000);
      expect(q.copyWith(maxPrice: 30000.0).make, 'Kia');
      expect(q.copyWith(make: null).make, isNull);
      expect(q.copyWith(make: null).maxPrice, 20000);
      expect(q.copyWith().isEmpty, isFalse);
      expect(q.copyWith(make: null, maxPrice: null).isEmpty, isTrue);
    });
  });

  group('describe', () {
    test('round thousands are shortened, anything else is exact', () {
      expect(
        const SearchQuery(bodyStyle: 'suv', maxPrice: 50000, make: 'Toyota').describe(),
        'Toyota · SUV · under \$50k',
      );
      expect(const SearchQuery(maxPrice: 9500).describe(), 'under \$9,500');
      expect(const SearchQuery(maxPrice: 500).describe(), 'under \$500');
      expect(const SearchQuery(minPrice: 10000).describe(), 'over \$10k');
      expect(const SearchQuery(maxMileage: 100000).describe(), 'under 100k mi');
      expect(const SearchQuery(maxMileage: 500).describe(), 'under 500 mi');
      expect(const SearchQuery(maxMileage: 45210).describe(), 'under 45,210 mi');
      expect(const SearchQuery(minYear: 2020, keywords: 'awd').describe(), '2020 or newer · awd');
      expect(const SearchQuery().describe(), 'any vehicle');
    });
  });
}
