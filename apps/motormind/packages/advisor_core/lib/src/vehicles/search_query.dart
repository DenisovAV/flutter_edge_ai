import 'listing_parse.dart';

/// The live vehicle search: the standard questions every listing site asks,
/// owned by the app and applied to the site the moment a value changes
/// (no "go" button). The model may change it from free text through
/// `update_search`, and the app infers obvious cases itself ("sports car"
/// means a coupe) so the person is not asked what they already said.
class SearchQuery {
  /// Creates a query; a null field means no filter.
  const SearchQuery({
    this.bodyStyle,
    this.maxPrice,
    this.minPrice,
    this.make,
    this.model,
    this.maxMileage,
    this.minYear,
    this.keywords,
  });

  /// One of [bodyStyles], or null for any.
  final String? bodyStyle;

  /// Highest price in dollars, or null for no ceiling.
  final double? maxPrice;

  /// Lowest price in dollars, or null for no floor.
  final double? minPrice;

  /// Manufacturer as the person said it, or null for any.
  final String? make;

  /// Model name, or null for any.
  final String? model;

  /// Highest odometer reading in miles, or null for any.
  final int? maxMileage;

  /// Oldest acceptable model year, or null for any.
  final int? minYear;

  /// Free text for the site to search, or null for none.
  final String? keywords;

  /// Accepted [bodyStyle] values, in the order the filters card shows them.
  static const bodyStyles = [
    'suv',
    'sedan',
    'coupe',
    'convertible',
    'hatchback',
    'pickup',
    'van',
    'wagon',
  ];

  /// Person-facing label for each of [bodyStyles].
  static const bodyStyleLabels = {
    'suv': 'SUV',
    'sedan': 'Sedan',
    'coupe': 'Sports / coupe',
    'convertible': 'Convertible',
    'hatchback': 'Hatchback',
    'pickup': 'Pickup',
    'van': 'Van / minivan',
    'wagon': 'Wagon',
  };

  /// True when no filter is set.
  bool get isEmpty =>
      bodyStyle == null &&
      maxPrice == null &&
      minPrice == null &&
      make == null &&
      model == null &&
      maxMileage == null &&
      minYear == null &&
      (keywords == null || keywords!.isEmpty);

  /// Returns a copy with the given fields replaced. Passing null clears a
  /// field; omitting it keeps the current value.
  SearchQuery copyWith({
    Object? bodyStyle = _unset,
    Object? maxPrice = _unset,
    Object? minPrice = _unset,
    Object? make = _unset,
    Object? model = _unset,
    Object? maxMileage = _unset,
    Object? minYear = _unset,
    Object? keywords = _unset,
  }) => SearchQuery(
    bodyStyle: identical(bodyStyle, _unset) ? this.bodyStyle : bodyStyle as String?,
    maxPrice: identical(maxPrice, _unset) ? this.maxPrice : maxPrice as double?,
    minPrice: identical(minPrice, _unset) ? this.minPrice : minPrice as double?,
    make: identical(make, _unset) ? this.make : make as String?,
    model: identical(model, _unset) ? this.model : model as String?,
    maxMileage: identical(maxMileage, _unset) ? this.maxMileage : maxMileage as int?,
    minYear: identical(minYear, _unset) ? this.minYear : minYear as int?,
    keywords: identical(keywords, _unset) ? this.keywords : keywords as String?,
  );

  /// Applies `update_search` arguments (snake_case, strings or numbers).
  /// A null or "any" value clears a field; absent fields are untouched.
  /// Numbers may carry a dollar sign, commas and a trailing `k` ("50k",
  /// "$9,500", "100k" miles). A bare `max_price` below 1,000 is read as
  /// thousands ("50" means $50,000): models answer in the units the person
  /// spoke, and nobody shops for a car under $50.
  SearchQuery applyArgs(Map<String, Object?> args) {
    var q = this;
    if (args.containsKey('body_style')) {
      final b = _toText(args['body_style'])?.toLowerCase();
      q = q.copyWith(bodyStyle: b == null ? null : (normalizeBodyStyle(b) ?? b));
    }
    if (args.containsKey('max_price')) {
      var p = _toNumber(args['max_price']);
      if (p != null && p < _bareThousandsBelow) p *= 1000;
      q = q.copyWith(maxPrice: p);
    }
    if (args.containsKey('min_price')) q = q.copyWith(minPrice: _toNumber(args['min_price']));
    if (args.containsKey('make')) q = q.copyWith(make: _toText(args['make']));
    if (args.containsKey('model')) q = q.copyWith(model: _toText(args['model']));
    if (args.containsKey('max_mileage')) {
      q = q.copyWith(maxMileage: _toNumber(args['max_mileage'])?.round());
    }
    if (args.containsKey('min_year')) q = q.copyWith(minYear: _toNumber(args['min_year'])?.round());
    if (args.containsKey('keywords')) q = q.copyWith(keywords: _toText(args['keywords']));
    return q;
  }

  /// Serializes in the snake_case shape `update_search` uses; nulls are kept
  /// so a stored query round-trips through [applyArgs].
  Map<String, Object?> toJson() => {
    'body_style': bodyStyle,
    'max_price': maxPrice,
    'min_price': minPrice,
    'make': make,
    'model': model,
    'max_mileage': maxMileage,
    'min_year': minYear,
    'keywords': keywords,
  };

  /// One line for the filter summary and the prompt: "Toyota · SUV · under
  /// $50k". Round thousands are shortened to "k"; anything else is shown in
  /// exact dollars ("under $9,500", "under $500") so a figure is never
  /// rounded into a different one.
  String describe() {
    final parts = <String>[
      if (make != null || model != null) [make, model].whereType<String>().join(' '),
      if (bodyStyle != null) bodyStyleLabels[bodyStyle] ?? bodyStyle!,
      if (maxPrice != null) 'under ${_dollars(maxPrice!)}',
      if (minPrice != null) 'over ${_dollars(minPrice!)}',
      if (maxMileage != null) 'under ${_miles(maxMileage!)}',
      if (minYear != null) '$minYear or newer',
      if (keywords != null && keywords!.isNotEmpty) keywords!,
    ];
    return parts.isEmpty ? 'any vehicle' : parts.join(' · ');
  }

  /// Maps the words people use to a body style, or null when unknown.
  /// First match wins, so the styles are ordered from the words that name
  /// one style unambiguously (SUV, convertible, sports car) to the ones
  /// that also describe other styles: "truck" and "van" before "hatch"
  /// (a van has a hatch), "wagon" before "sedan", and sedan last because
  /// "four-door" is said of pickups and SUVs too.
  static String? normalizeBodyStyle(String s) {
    final t = s.toLowerCase();
    for (final (style, pattern) in _bodyStylePatterns) {
      if (pattern.hasMatch(t)) return style;
    }
    return null;
  }

  static final List<(String, RegExp)> _bodyStylePatterns = [
    ('suv', RegExp(r'\b(suv|crossover|cuv)\b')),
    ('convertible', RegExp(r'\b(convertible|cabrio(let)?|roadster|drop[- ]top)\b')),
    (
      'coupe',
      RegExp(r'\b(sports? ?cars?|sporty|coupe|coup[eé]|2[- ]door|two[- ]door|muscle car)\b'),
    ),
    ('pickup', RegExp(r'\b(pickup|truck)s?\b')),
    ('van', RegExp(r'\b(mini ?van|van)s?\b')),
    ('hatchback', RegExp(r'\b(hatch(back)?)s?\b')),
    ('wagon', RegExp(r'\b(wagon|estate)s?\b')),
    ('sedan', RegExp(r'\b(sedan|saloon|4[- ]door|four[- ]door)s?\b')),
  ];
}

/// Marks an omitted argument in [SearchQuery.copyWith], so that an explicit
/// null can mean "clear this field".
const _unset = Object();

/// A `max_price` below this is read as thousands; see [SearchQuery.applyArgs].
const _bareThousandsBelow = 1000;

/// A number from a tool argument: a `num` as is, or a string with an
/// optional dollar sign, commas, spaces and a trailing `k` for thousands
/// ("$9,500", "50k", "100K"). Null for anything else.
double? _toNumber(Object? v) {
  if (v is num) return v.toDouble();
  if (v is! String) return null;
  var s = v.replaceAll(RegExp(r'[\$,\s]'), '').toLowerCase();
  var scale = 1.0;
  if (s.endsWith('k')) {
    scale = 1000;
    s = s.substring(0, s.length - 1);
  }
  final n = double.tryParse(s);
  return n == null ? null : n * scale;
}

/// Trimmed text from a tool argument; null for empty, "any" and "null",
/// which the model sends to clear a filter.
String? _toText(Object? v) {
  final s = v?.toString().trim();
  if (s == null || s.isEmpty || s.toLowerCase() == 'any' || s.toLowerCase() == 'null') {
    return null;
  }
  return s;
}

/// "$50k" for round thousands, exact dollars ("$9,500", "$500") otherwise.
String _dollars(double v) =>
    v >= 1000 && v % 1000 == 0 ? '\$${(v / 1000).round()}k' : '\$${_grouped(v.round())}';

/// "100k mi" for round thousands, exact miles ("500 mi") otherwise.
String _miles(int v) => v >= 1000 && v % 1000 == 0 ? '${v ~/ 1000}k mi' : '${_grouped(v)} mi';

/// Thousands separators: 9500 → "9,500".
String _grouped(int n) =>
    n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

/// What the app can infer from a sentence without the model: a body style
/// (including "sports car"), a price ceiling, a make, a mileage cap, a year.
/// Returns only the fields it found; the model handles the rest. A key that
/// is present with a null value means "clear this filter" (`max_price` when
/// money is no object); an absent key means the sentence said nothing.
Map<String, Object?> inferSearchArgs(String text) {
  final t = text.toLowerCase();
  final body = SearchQuery.normalizeBodyStyle(t);
  final make = _inferMake(t);
  return {
    'body_style': ?body,
    if (_noBudget.hasMatch(t)) 'max_price': null else ..._inferPrice(t),
    'make': ?make,
    ..._inferMileage(t),
    ..._inferYear(t),
  };
}

/// A price ceiling: "under $9,500", "under 20000", "around 30k", "$25,000
/// budget", "under 40" (thousands). Not "$430/mo" (a payment), "under 100k
/// miles" or "under 500 miles" (an odometer), "about 2020 or newer" (a year).
final RegExp _priceCeiling = RegExp(
  r'(?:under|below|less than|max(?:imum)?|up to|around|about|budget of|\$)\s*\$?\s*'
  r'(\d{1,3}(?:,\d{3})+|\d{4,6}|\d{1,3}(?:\.\d)?\s*k|\d{2,3})\b'
  r'(?!\s*(?:mi\b|miles|/\s*mo|a month|per month|(?:or|and)\s+(?:newer|later)))',
  caseSensitive: false,
);

/// A budget that is no ceiling at all: "dream car", "money is no object",
/// "no budget". Not "a budget of 30k".
final RegExp _noBudget = RegExp(r'dream car|money (?:is|were) no object|no budget');

/// Lowest and highest ceilings worth setting: below, the figure was a
/// payment or a typo; above, no site Motormind reads lists such a car.
const _minCeiling = 2000.0;
const _maxCeiling = 500000.0;

Map<String, Object?> _inferPrice(String t) {
  final m = _priceCeiling.firstMatch(t);
  if (m == null) return const {};
  final v = m.group(1)!.replaceAll(',', '').replaceAll(' ', '').toLowerCase();
  var p = v.endsWith('k') ? double.parse(v.substring(0, v.length - 1)) * 1000 : double.parse(v);
  if (p < _bareThousandsBelow) p *= 1000; // "under 40" means $40,000
  return p >= _minCeiling && p <= _maxCeiling ? {'max_price': p} : const {};
}

/// "mini" the body style, not the make: "mini van", "mini-van", "minivans".
/// "mini cooper" and "a mini" still name the make.
final RegExp _miniVan = RegExp(r'\bmini[\s-]*vans?\b');

/// Word-bounded alias patterns, compiled once, longest alias first so
/// "land rover" is found before a one-word make could.
final List<(String, RegExp)> _makePatterns = [
  for (final alias in makeAliasesLongestFirst) (alias, RegExp('\\b${RegExp.escape(alias)}\\b')),
];

String? _inferMake(String t) {
  for (final (alias, pattern) in _makePatterns) {
    if (!pattern.hasMatch(t)) continue;
    if (alias == 'mini' && _miniVan.hasMatch(t)) continue;
    return vehicleMakes[alias];
  }
  return null;
}

/// A mileage cap: "under 100k miles" (100,000), "under 60,000 miles",
/// "under 500 miles" (500, no scaling without a k), "less than 80k mi".
/// Not "under $9,500" (no unit) or "100k miles" with no bound word.
final RegExp _mileageCap = RegExp(
  r'(?:under|below|less than|max(?:imum)?|up to)\s*(\d{1,3}(?:,\d{3})+|\d{1,6})\s*(k)?\s*(?:miles|mi\b)',
  caseSensitive: false,
);

Map<String, Object?> _inferMileage(String t) {
  final m = _mileageCap.firstMatch(t);
  if (m == null) return const {};
  final n = int.parse(m.group(1)!.replaceAll(',', ''));
  return {'max_mileage': m.group(2) == null ? n : n * 1000};
}

/// A model-year floor: "2020 or newer", "2018+", "2019 and newer", "2021 or
/// later". Not "2020 Toyota" (a year with no bound word).
final RegExp _yearFloor = RegExp(r'\b(20[0-3]\d)\s*(?:or newer|and newer|\+|or later)');

Map<String, Object?> _inferYear(String t) {
  final m = _yearFloor.firstMatch(t);
  return m == null ? const {} : {'min_year': int.parse(m.group(1)!)};
}
