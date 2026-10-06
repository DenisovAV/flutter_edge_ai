import 'search_query.dart';

/// Sites the project tests page reading against (Q10, Q31). Each knows how
/// to build a search URL from the advisor's query, so `find_vehicles` can open
/// a results page when nothing has been read yet. User-initiated, one page at
/// a time; nothing is fetched in bulk.
class CuratedSite {
  const CuratedSite({
    required this.id,
    required this.name,
    required this.home,
    required this.search,
  });

  final String id;
  final String name;
  final String home;

  /// Builds a results URL. [maxPrice] in dollars; [bodyStyle] one of
  /// car/suv/pickup/van; [keywords] free text.
  final String Function({double? maxPrice, String? bodyStyle, String? keywords}) search;

  /// Results URL for a live [SearchQuery]. Make/model ride in the keyword
  /// slot; sites that ignore a parameter still list inventory, and the app
  /// filters what it reads.
  String urlFor(SearchQuery q) => search(
    maxPrice: q.maxPrice,
    bodyStyle: q.bodyStyle,
    keywords:
        [
          q.make,
          q.model,
          q.keywords,
        ].whereType<String>().where((s) => s.isNotEmpty).join(' ').trim().isEmpty
        ? null
        : [q.make, q.model, q.keywords].whereType<String>().where((s) => s.isNotEmpty).join(' '),
  );
}

String _q(String s) => Uri.encodeQueryComponent(s);

abstract final class CuratedSites {
  static final echopark = CuratedSite(
    id: 'echopark',
    name: 'EchoPark',
    home: 'https://www.echopark.com/',
    search: ({maxPrice, bodyStyle, keywords}) {
      final params = <String>[
        if (bodyStyle != null) 'bodyStyle=${_q(_body(bodyStyle))}',
        if (maxPrice != null) 'maxPrice=${maxPrice.round()}',
        if (keywords != null && keywords.isNotEmpty) 'search=${_q(keywords)}',
      ];
      return 'https://www.echopark.com/used-cars${params.isEmpty ? '' : '?${params.join('&')}'}';
    },
  );

  static final carsDotCom = CuratedSite(
    id: 'cars',
    name: 'Cars.com',
    home: 'https://www.cars.com/',
    search: ({maxPrice, bodyStyle, keywords}) {
      final params = <String>[
        'stock_type=all',
        if (maxPrice != null) 'list_price_max=${maxPrice.round()}',
        if (bodyStyle != null) 'body_style_slugs[]=${_q(_body(bodyStyle))}',
        if (keywords != null && keywords.isNotEmpty) 'keyword=${_q(keywords)}',
      ];
      return 'https://www.cars.com/shopping/results/?${params.join('&')}';
    },
  );

  static final autotrader = CuratedSite(
    id: 'autotrader',
    name: 'Autotrader',
    home: 'https://www.autotrader.com/',
    search: ({maxPrice, bodyStyle, keywords}) {
      final params = <String>[
        if (maxPrice != null) 'maxPrice=${maxPrice.round()}',
        if (bodyStyle != null) 'vehicleStyleCodes=${_q(_atStyle(bodyStyle))}',
        if (keywords != null && keywords.isNotEmpty) 'keywordPhrases=${_q(keywords)}',
      ];
      return 'https://www.autotrader.com/cars-for-sale/all-cars${params.isEmpty ? '' : '?${params.join('&')}'}';
    },
  );

  static final List<CuratedSite> all = [echopark, carsDotCom, autotrader];
  static CuratedSite get defaultSite => echopark;
  static CuratedSite? byId(String id) => all.where((s) => s.id == id).firstOrNull;

  static String _body(String b) => switch (b.toLowerCase()) {
    'suv' => 'SUV',
    'car' || 'sedan' => 'Sedan',
    'coupe' => 'Coupe',
    'convertible' => 'Convertible',
    'hatchback' => 'Hatchback',
    'pickup' => 'Truck',
    'van' => 'Van',
    'wagon' => 'Wagon',
    _ => b,
  };

  static String _atStyle(String b) => switch (b.toLowerCase()) {
    'suv' => 'SUVCROSS',
    'car' || 'sedan' => 'SEDAN',
    'coupe' => 'COUPE',
    'convertible' => 'CONVERT',
    'hatchback' => 'HATCH',
    'pickup' => 'TRUCKS',
    'van' => 'VANS',
    'wagon' => 'WAGON',
    _ => b,
  };
}
