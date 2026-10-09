import 'listing.dart';
import 'listing_parse.dart';

/// Pulls vehicle listings out of a page's visible text with patterns, not
/// per-site scraping. Two shapes are recognized:
///
/// - title first: "2021 Honda CR-V EX-L" on one line, with a price and an
///   optional mileage within a few lines below (common results pages);
/// - year first: a bare year line, then mileage ("35K mi") and stock lines,
///   a title line ("Toyota RAV4 XLE"), then a "Price" label and the price
///   (EchoPark-style cards).
///
/// Deliberately generic (Q31: user-initiated, one page at a time). A curated
/// site may add a recipe that does better; this is the floor every page gets.
class ListingExtractor {
  /// Creates an extractor that stops after [maxListings] listings.
  const ListingExtractor({this.maxListings = defaultMaxListings});

  /// Upper bound on listings returned from one page.
  final int maxListings;

  /// A bare year line, optionally led by a condition word: "2023",
  /// "Used 2020". Not "2023 BMW X3", which is a title line.
  static final _yearOnly = RegExp(
    r'^(?:(?:New|Used|Certified|CPO|Pre-Owned)\s+)?((?:19|20)\d{2})$',
  );

  /// A yearless title line of two to eight words, the first capitalized:
  /// "BMW 5 Series 530i xDrive", "Honda CR-V Hybrid EX-L". Not "|", not
  /// "Stock #: PPWY18150", not "$34,997".
  static final _titleLine = RegExp(
    r'^[A-Z][A-Za-z0-9\-]+(?:\s+[A-Za-z0-9][A-Za-z0-9\-\./&]*){1,7}$',
  );

  /// Lines below a title line searched for its price and mileage: a results
  /// row keeps its facts right under the heading, so a longer look would
  /// read the next row's price into this one.
  static const _factsWindow = 8;

  /// Lines below a bare year line that may hold one EchoPark-style card's
  /// mileage, stock number, title, "Price" label and price. Longer than
  /// [_factsWindow] because the card carries more chrome than a results row.
  static const _cardWindow = 12;

  /// Card chrome seen on EchoPark that would otherwise pass for a title line
  /// (compared lower-cased, by prefix). A growing list: each entry is a line
  /// that once became a listing title on a real page. Lines that look like a
  /// price or a stock number are excluded separately.
  static const _nonTitleLabels = {
    'price',
    'favorite icon',
    'pickup at',
    'schedule test drive',
    'price drop',
    'total transparent price',
    'document & other fees',
    'just dropped',
    'sort by',
    'filters',
  };

  /// Reads listings from the visible [text] of the page at [sourceUrl];
  /// [now] is recorded as each listing's read time. Listings without a
  /// price are skipped, and a card read twice (a page repeats its cards in
  /// a sticky header or a "recently viewed" strip) is kept once.
  List<VehicleListing> extract(String text, {required String sourceUrl, required DateTime now}) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final out = <VehicleListing>[];
    final seen = <String>{};
    for (var i = 0; i < lines.length && out.length < maxListings; i++) {
      final found = _extractTitleFirst(lines, i) ?? _extractYearFirst(lines, i);
      if (found == null || found.price == null) continue;
      final listing = VehicleListing(
        id: 'v${out.length + 1}',
        title: found.title,
        sourceUrl: sourceUrl,
        readAt: now,
        price: found.price,
        mileage: found.mileage,
        year: found.year,
        make: found.make,
        model: found.model,
      );
      if (seen.add(listing.dedupeKey)) out.add(listing);
    }
    return out;
  }

  /// Reads a card whose heading at [lines][start] carries the year, make
  /// and model, with the price and mileage in the lines below it.
  _Card? _extractTitleFirst(List<String> lines, int start) {
    final heading = parseTitle(lines[start]);
    if (heading == null) return null;
    double? price;
    int? mileage;
    for (var j = start + 1; j < lines.length && j <= start + _factsWindow; j++) {
      final line = lines[j];
      if (parseTitle(line) != null || _yearOnly.hasMatch(line)) break;
      price ??= tryParsePrice(line);
      mileage ??= tryParseMiles(line, requireUnit: true);
      if (price != null && mileage != null) break;
    }
    return (
      title: heading.title,
      year: heading.year,
      make: heading.make,
      model: heading.model,
      price: price,
      mileage: mileage,
    );
  }

  /// Reads an EchoPark-style card: a bare year at [lines][start], then the
  /// mileage, the stock number, a yearless title line and, after the "Price"
  /// label, the price. The price must follow the title: the mileage and the
  /// fees above it carry figures of their own.
  _Card? _extractYearFirst(List<String> lines, int start) {
    final y = _yearOnly.firstMatch(lines[start]);
    if (y == null) return null;
    int? mileage;
    String? title;
    double? price;
    for (var j = start + 1; j < lines.length && j <= start + _cardWindow; j++) {
      final line = lines[j];
      if (_yearOnly.hasMatch(line)) break;
      if (mileage == null) {
        mileage = tryParseMiles(line, requireUnit: true);
        if (mileage != null) continue;
      }
      if (title == null) {
        final lower = line.toLowerCase();
        final chrome =
            line == '|' ||
            lower.startsWith('stock') ||
            _nonTitleLabels.any(lower.startsWith) ||
            tryParsePrice(line) != null;
        if (!chrome && _titleLine.hasMatch(line)) title = line;
      } else {
        price = tryParsePrice(line);
        if (price != null) break;
      }
    }
    if (title == null) return null;
    final year = int.parse(y.group(1)!);
    final parts = splitMakeModel(title);
    return (
      title: '$year $title',
      year: year,
      make: parts.make,
      model: parts.model,
      price: price,
      mileage: mileage,
    );
  }
}

/// What one card yielded before it becomes a [VehicleListing].
typedef _Card = ({String title, int year, String make, String model, double? price, int? mileage});

/// Price, mileage and year facts found in the free text of one listing page
/// by [extractListingFacts].
class PageFacts {
  /// Creates facts; every field is optional because a page may show none.
  const PageFacts({this.prices = const [], this.mileage, this.year});

  /// Distinct dollar figures in reading order, at most [maxPrices], each
  /// within [minPrice] and [maxPrice]. The asking price is usually first and
  /// a crossed-out "was" price follows it.
  final List<double> prices;

  /// The first odometer figure on the page, in miles.
  final int? mileage;

  /// The first model year on the page.
  final int? year;

  /// Prices kept from one page: the first few figures of a listing page are
  /// the asking price and its history; past that they are fees, payment
  /// examples and other cars.
  static const maxPrices = 5;

  /// Figures below this are fees and monthly payments, not a vehicle price.
  static const minPrice = 1000.0;

  /// Figures above this are not a used-vehicle price on the sites Motormind
  /// reads; a VIN fragment or a phone number can look like one.
  static const maxPrice = 500000.0;

  /// True when the page yielded nothing.
  bool get isEmpty => prices.isEmpty && mileage == null && year == null;

  /// The model/UI hand-off form; absent facts are left out.
  Map<String, Object?> toJson() => {
    if (prices.isNotEmpty) 'prices': prices,
    if (mileage != null) 'mileage': mileage,
    if (year != null) 'year': year,
  };
}

/// A model year on a listing page: "2019", "1998". Not "1950" or "2040".
final _modelYear = RegExp(r'\b(20[0-3]\d|19[89]\d)\b');

/// Finds price, mileage and year facts in the free [text] of a single
/// listing page; see [PageFacts] for what is kept.
PageFacts extractListingFacts(String text) {
  final prices = <double>{};
  for (final p in parseAllPrices(text)) {
    if (p < PageFacts.minPrice || p > PageFacts.maxPrice) continue;
    prices.add(p);
    if (prices.length == PageFacts.maxPrices) break;
  }
  final year = _modelYear.firstMatch(text);
  return PageFacts(
    prices: prices.toList(),
    mileage: tryParseMiles(text, requireUnit: true),
    year: year == null ? null : int.parse(year.group(1)!),
  );
}
