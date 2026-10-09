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

  /// Accepted [bodyStyle] values, in the order the filter strip shows them.
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
  SearchQuery applyArgs(Map<String, Object?> args) {
    double? num_(Object? v) => v is num
        ? v.toDouble()
        : (v is String ? double.tryParse(v.replaceAll(RegExp(r'[\$,kK\s]'), '')) : null);
    String? str(Object? v) {
      final s = v?.toString().trim();
      if (s == null || s.isEmpty || s.toLowerCase() == 'any' || s.toLowerCase() == 'null') {
        return null;
      }
      return s;
    }

    var q = this;
    if (args.containsKey('body_style')) {
      final b = str(args['body_style'])?.toLowerCase();
      q = q.copyWith(bodyStyle: b == null ? null : (normalizeBodyStyle(b) ?? b));
    }
    if (args.containsKey('max_price')) {
      var p = num_(args['max_price']);
      if (p != null && p < 1000) p *= 1000; // "50" or "50k" meant thousands
      q = q.copyWith(maxPrice: p);
    }
    if (args.containsKey('min_price')) q = q.copyWith(minPrice: num_(args['min_price']));
    if (args.containsKey('make')) q = q.copyWith(make: str(args['make']));
    if (args.containsKey('model')) q = q.copyWith(model: str(args['model']));
    if (args.containsKey('max_mileage')) {
      q = q.copyWith(maxMileage: num_(args['max_mileage'])?.round());
    }
    if (args.containsKey('min_year')) q = q.copyWith(minYear: num_(args['min_year'])?.round());
    if (args.containsKey('keywords')) q = q.copyWith(keywords: str(args['keywords']));
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

  /// One line for the strip and the prompt.
  String describe() {
    final parts = <String>[
      if (make != null || model != null) [make, model].whereType<String>().join(' '),
      if (bodyStyle != null) bodyStyleLabels[bodyStyle] ?? bodyStyle!,
      if (maxPrice != null) 'under \$${(maxPrice! / 1000).round()}k',
      if (minPrice != null) 'over \$${(minPrice! / 1000).round()}k',
      if (maxMileage != null) 'under ${(maxMileage! / 1000).round()}k mi',
      if (minYear != null) '$minYear or newer',
      if (keywords != null && keywords!.isNotEmpty) keywords!,
    ];
    return parts.isEmpty ? 'any vehicle' : parts.join(' · ');
  }

  /// Maps the words people use to a body style, or null when unknown.
  static String? normalizeBodyStyle(String s) {
    final t = s.toLowerCase();
    if (RegExp(r'\b(suv|crossover|cuv)\b').hasMatch(t)) return 'suv';
    if (RegExp(
      r'\b(sports? ?cars?|sporty|coupe|coup[eé]|2[- ]door|two[- ]door|muscle car)\b',
    ).hasMatch(t)) {
      return 'coupe';
    }
    if (RegExp(r'\b(convertible|cabrio(let)?|roadster|drop[- ]top)\b').hasMatch(t)) {
      return 'convertible';
    }
    if (RegExp(r'\b(pickup|truck)s?\b').hasMatch(t)) return 'pickup';
    if (RegExp(r'\b(mini ?van|van)s?\b').hasMatch(t)) return 'van';
    if (RegExp(r'\b(hatch(back)?)s?\b').hasMatch(t)) return 'hatchback';
    if (RegExp(r'\b(wagon|estate)s?\b').hasMatch(t)) return 'wagon';
    if (RegExp(r'\b(sedan|saloon|4[- ]door|four[- ]door)s?\b').hasMatch(t)) return 'sedan';
    return null;
  }
}

const _unset = Object();

const _makes = [
  'acura',
  'audi',
  'bmw',
  'buick',
  'cadillac',
  'chevrolet',
  'chevy',
  'chrysler',
  'dodge',
  'ford',
  'genesis',
  'gmc',
  'honda',
  'hyundai',
  'infiniti',
  'jaguar',
  'jeep',
  'kia',
  'land rover',
  'lexus',
  'lincoln',
  'mazda',
  'mercedes',
  'mercedes-benz',
  'mini',
  'mitsubishi',
  'nissan',
  'porsche',
  'ram',
  'rivian',
  'subaru',
  'tesla',
  'toyota',
  'volkswagen',
  'vw',
  'volvo',
];

/// What the app can infer from a sentence without the model: a body style
/// (including "sports car"), a price ceiling, a make, a mileage cap, a year.
/// Returns only the fields it found; the model handles the rest.
Map<String, Object?> inferSearchArgs(String text) {
  final t = text.toLowerCase();
  final out = <String, Object?>{};
  final body = SearchQuery.normalizeBodyStyle(t);
  if (body != null) out['body_style'] = body;
  final price = RegExp(
    r'(?:under|below|less than|max(?:imum)?|up to|around|about|budget of|\$)\s*\$?\s*(\d{2,3}(?:,\d{3})?|\d{1,3}(?:\.\d)?\s*k)\b(?!\s*(?:mi\b|miles))',
    caseSensitive: false,
  ).firstMatch(t);
  if (price != null) {
    final v = price.group(1)!.replaceAll(',', '').replaceAll(' ', '');
    double p;
    if (v.endsWith('k')) {
      p = double.parse(v.substring(0, v.length - 1)) * 1000;
    } else {
      p = double.parse(v);
      if (p < 1000) p *= 1000;
    }
    if (p >= 2000 && p <= 500000) out['max_price'] = p;
  }
  for (final m in _makes) {
    if (RegExp('\\b${RegExp.escape(m)}\\b').hasMatch(t)) {
      out['make'] = switch (m) {
        'chevy' => 'Chevrolet',
        'vw' => 'Volkswagen',
        _ => m.split(' ').map((w) => w[0].toUpperCase() + w.substring(1)).join(' '),
      };
      break;
    }
  }
  final miles = RegExp(
    r'(?:under|below|less than|max)\s*(\d{1,3})\s*k?\s*(?:miles|mi\b)',
    caseSensitive: false,
  ).firstMatch(t);
  if (miles != null) out['max_mileage'] = int.parse(miles.group(1)!) * 1000;
  final year = RegExp(r'\b(20[12]\d)\s*(?:or newer|and newer|\+|or later)').firstMatch(t);
  if (year != null) out['min_year'] = int.parse(year.group(1)!);
  if (RegExp(r'dream car|money (?:is|were) no object|no budget').hasMatch(t)) {
    out['max_price'] = null;
  }
  return out;
}
