import 'listing.dart';

/// Pulls vehicle listings out of a page's visible text with patterns, not
/// per-site scraping: a line that looks like "2021 Honda CR-V EX-L" followed
/// within a few lines by a price and, optionally, a mileage.
///
/// This is deliberately generic (Q31: user-initiated, one page at a time). A
/// curated site may later add a recipe that does better; the generic pass is
/// the floor every page gets.
class ListingExtractor {
  const ListingExtractor({this.maxListings = 25});

  final int maxListings;

  static final _yearMakeModel = RegExp(
    r'^(?:(?:New|Used|Certified|CPO)\s+)?((?:19|20)\d{2})\s+([A-Z][A-Za-z\-]+)\s+([A-Za-z0-9][^\n]{1,40})$',
  );
  static final _price = RegExp(r'\$\s?(\d{1,3}(?:,\d{3})+|\d{4,6})(?!\s*/\s*mo)');
  static final _mileage = RegExp(
    r'(\d{1,3}(?:,\d{3})+|\d{3,6})\s*(?:mi\b|miles)',
    caseSensitive: false,
  );
  static final _monthly = RegExp(r'\$\s?\d{2,4}\s*/\s*mo', caseSensitive: false);

  List<VehicleListing> extract(String text, {required String sourceUrl, required DateTime now}) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final out = <VehicleListing>[];
    final seen = <String>{};
    for (var i = 0; i < lines.length && out.length < maxListings; i++) {
      final m = _yearMakeModel.firstMatch(lines[i]);
      if (m == null) continue;
      final year = int.parse(m.group(1)!);
      final make = m.group(2)!;
      final model = m.group(3)!.trim();
      double? price;
      int? mileage;
      // Look ahead a few lines for a price (not a monthly figure) and a mileage.
      for (var j = i + 1; j < lines.length && j <= i + 8; j++) {
        final line = lines[j];
        if (_yearMakeModel.hasMatch(line)) break; // next listing
        if (price == null && !_monthly.hasMatch(line)) {
          final p = _price.firstMatch(line);
          if (p != null) price = double.parse(p.group(1)!.replaceAll(',', ''));
        }
        if (mileage == null) {
          final mi = _mileage.firstMatch(line);
          if (mi != null) mileage = int.parse(mi.group(1)!.replaceAll(',', ''));
        }
        if (price != null && mileage != null) break;
      }
      if (price == null) continue; // a title without a price is navigation, not a listing
      final title = '$year $make $model';
      final key = '$title|$price|$mileage';
      if (!seen.add(key)) continue;
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
  if (mi != null) facts['mileage'] = int.parse(mi.group(1)!.replaceAll(',', ''));
  final y = RegExp(r'\b(20[0-2]\d|19[89]\d)\b').firstMatch(text);
  if (y != null) facts['year'] = int.parse(y.group(1)!);
  return facts;
}
