import 'listing.dart';

/// Pulls vehicle listings out of a page's visible text with patterns, not
/// per-site scraping. Two shapes are recognized:
///
/// - A: "2021 Honda CR-V EX-L" on one line, with a price and optional mileage
///   within a few lines below (common results pages).
/// - B: a bare year line, then mileage ("35K mi") and stock lines, a title line
///   ("Toyota RAV4 XLE"), then a "Price" label and the price (EchoPark-style
///   cards).
///
/// Deliberately generic (Q31: user-initiated, one page at a time). A curated
/// site may later add a recipe that does better; this is the floor every page
/// gets.
class ListingExtractor {
  /// Creates an extractor that stops after [maxListings] listings.
  const ListingExtractor({this.maxListings = 25});

  /// Upper bound on listings returned from one page.
  final int maxListings;

  static final _yearMakeModel = RegExp(
    r'^(?:(?:New|Used|Certified|CPO)\s+)?((?:19|20)\d{2})\s+([A-Z][A-Za-z\-]+)\s+([A-Za-z0-9][^\n]{1,40})$',
  );
  static final _yearOnly = RegExp(r'^(?:(?:New|Used|Certified|CPO)\s+)?((?:19|20)\d{2})$');
  static final _titleLine = RegExp(
    r'^[A-Z][A-Za-z0-9\-]+(?:\s+[A-Za-z0-9][A-Za-z0-9\-\./&]*){1,7}$',
  );
  static final _price = RegExp(r'\$\s?(\d{1,3}(?:,\d{3})+|\d{4,6})(?!\s*/\s*mo)');
  static final _mileage = RegExp(
    r'(\d{1,3}(?:,\d{3})+|\d{3,6}|\d{1,3}(?:\.\d)?[kK])\s*(?:mi\b|miles)',
    caseSensitive: false,
  );
  static final _monthly = RegExp(r'\$\s?\d{2,4}\s*/\s*mo', caseSensitive: false);
  static const _labels = {
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

  /// Parses an odometer figure such as `35,000` or `35K` into miles; throws
  /// [FormatException] for anything else.
  static int parseMiles(String raw) {
    final v = raw.toLowerCase();
    if (v.endsWith('k')) return (double.parse(v.substring(0, v.length - 1)) * 1000).round();
    return int.parse(v.replaceAll(',', ''));
  }

  /// Reads listings from the visible [text] of the page at [sourceUrl];
  /// [now] is recorded as each listing's read time. Listings without a
  /// price are skipped.
  List<VehicleListing> extract(String text, {required String sourceUrl, required DateTime now}) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final out = <VehicleListing>[];
    final seen = <String>{};

    void add(int year, String make, String model, double? price, int? mileage) {
      if (price == null || out.length >= maxListings) return;
      final title = '$year $make $model'.trim();
      if (!seen.add('$title|$price|$mileage')) return;
      out.add(
        VehicleListing(
          id: 'v${out.length + 1}',
          title: title,
          sourceUrl: sourceUrl,
          readAt: now,
          price: price,
          mileage: mileage,
          year: year,
          make: make,
          model: model,
        ),
      );
    }

    for (var i = 0; i < lines.length && out.length < maxListings; i++) {
      final m = _yearMakeModel.firstMatch(lines[i]);
      if (m != null) {
        double? price;
        int? mileage;
        for (var j = i + 1; j < lines.length && j <= i + 8; j++) {
          final line = lines[j];
          if (_yearMakeModel.hasMatch(line) || _yearOnly.hasMatch(line)) break;
          if (price == null && !_monthly.hasMatch(line)) {
            final p = _price.firstMatch(line);
            if (p != null) price = double.parse(p.group(1)!.replaceAll(',', ''));
          }
          if (mileage == null) {
            final mi = _mileage.firstMatch(line);
            if (mi != null) mileage = parseMiles(mi.group(1)!);
          }
          if (price != null && mileage != null) break;
        }
        add(int.parse(m.group(1)!), m.group(2)!, m.group(3)!.trim(), price, mileage);
        continue;
      }
      final y = _yearOnly.firstMatch(lines[i]);
      if (y == null) continue;
      int? mileage;
      String? title;
      double? price;
      for (var j = i + 1; j < lines.length && j <= i + 12; j++) {
        final line = lines[j];
        if (_yearOnly.hasMatch(line)) break;
        final lower = line.toLowerCase();
        if (mileage == null) {
          final mi = _mileage.firstMatch(line);
          if (mi != null) {
            mileage = parseMiles(mi.group(1)!);
            continue;
          }
        }
        if (title == null) {
          if (line == '|' ||
              lower.startsWith('stock') ||
              _labels.any(lower.startsWith) ||
              _price.hasMatch(line)) {
            continue;
          }
          if (_titleLine.hasMatch(line)) title = line;
        } else if (price == null && !_monthly.hasMatch(line)) {
          final p = _price.firstMatch(line);
          if (p != null) {
            price = double.parse(p.group(1)!.replaceAll(',', ''));
            break;
          }
        }
      }
      if (title != null) {
        final parts = title.split(RegExp(r'\s+'));
        add(int.parse(y.group(1)!), parts.first, parts.skip(1).join(' '), price, mileage);
      }
    }
    return out;
  }
}

/// Finds price, mileage and year facts in free text (a single listing page).
Map<String, Object?> extractFacts(String text) {
  final facts = <String, Object?>{};
  final p = ListingExtractor._price
      .allMatches(text)
      .map((m) => double.parse(m.group(1)!.replaceAll(',', '')))
      .where((v) => v >= 1000 && v <= 500000)
      .toList();
  if (p.isNotEmpty) facts['prices'] = p.take(5).toList();
  final mi = ListingExtractor._mileage.firstMatch(text);
  if (mi != null) facts['mileage'] = ListingExtractor.parseMiles(mi.group(1)!);
  final y = RegExp(r'\b(20[0-2]\d|19[89]\d)\b').firstMatch(text);
  if (y != null) facts['year'] = int.parse(y.group(1)!);
  return facts;
}
