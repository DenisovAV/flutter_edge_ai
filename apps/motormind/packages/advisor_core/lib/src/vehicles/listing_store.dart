import 'listing.dart';
import 'search_query.dart';

/// Listings read during this session (Q45: session scope; saving across
/// conversations is a separate, explicit action). `find_vehicles` searches
/// here. Listings carry `readAt` so staleness can be shown later (DD-R15).
class ListingStore {
  final List<VehicleListing> _all = [];

  /// Every listing read so far, in read order; unmodifiable.
  List<VehicleListing> get all => List.unmodifiable(_all);

  /// True when nothing has been read yet.
  bool get isEmpty => _all.isEmpty;

  /// Adds [listings], skipping any whose title, price and mileage all match
  /// one already stored.
  void addAll(Iterable<VehicleListing> listings) {
    for (final l in listings) {
      final dup = _all.any(
        (e) => e.title == l.title && e.price == l.price && e.mileage == l.mileage,
      );
      if (!dup) {
        _all.add(l);
      }
    }
  }

  /// Forgets every listing.
  void clear() => _all.clear();

  /// Searches with the live query, cheapest first, at most [limit] results.
  /// Listings carry no body style yet, so that filter is applied by the
  /// site, not here; unpriced listings never match a price bound.
  List<VehicleListing> searchQuery(SearchQuery q, {int limit = 8}) {
    final results = _all.where((l) {
      if (q.maxPrice != null && (l.price == null || l.price! > q.maxPrice!)) return false;
      if (q.minPrice != null && (l.price == null || l.price! < q.minPrice!)) return false;
      if (q.maxMileage != null && l.mileage != null && l.mileage! > q.maxMileage!) return false;
      if (q.minYear != null && l.year != null && l.year! < q.minYear!) return false;
      final hay = l.title.toLowerCase();
      if (q.make != null && !hay.contains(q.make!.toLowerCase())) return false;
      if (q.model != null && !hay.contains(q.model!.toLowerCase())) return false;
      return true;
    }).toList()..sort((a, b) => (a.price ?? double.infinity).compareTo(b.price ?? double.infinity));
    return results.take(limit).toList();
  }

  /// Searches with the loose `find_vehicles` arguments, cheapest first, at
  /// most [limit] results. [maxPrice] is in dollars, [maxMileage] in miles;
  /// any word of [keywords] may match the title.
  List<VehicleListing> search({
    double? maxPrice,
    String? bodyStyle,
    int? maxMileage,
    String? keywords,
    int limit = 5,
  }) {
    final words = (keywords ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final results = _all.where((l) {
      if (maxPrice != null && (l.price == null || l.price! > maxPrice)) {
        return false;
      }
      if (maxMileage != null && l.mileage != null && l.mileage! > maxMileage) {
        return false;
      }
      if (bodyStyle != null &&
          l.bodyStyle != null &&
          l.bodyStyle!.toLowerCase() != bodyStyle.toLowerCase()) {
        return false;
      }
      if (words.isNotEmpty) {
        final hay = l.title.toLowerCase();
        if (!words.any(hay.contains)) {
          return false;
        }
      }
      return true;
    }).toList()..sort((a, b) => (a.price ?? double.infinity).compareTo(b.price ?? double.infinity));
    return results.take(limit).toList();
  }
}
