import 'listing.dart';
import 'search_query.dart';

/// Listings read during this session (Q45: session scope; saving across
/// conversations is a separate, explicit action). `find_vehicles` searches
/// here. Listings carry `readAt` so staleness can be shown later (DD-R15).
class ListingStore {
  final List<VehicleListing> _all = [];

  /// [VehicleListing.dedupeKey] of every stored listing, so a page read
  /// twice costs one lookup per card rather than a scan of the store.
  final Set<String> _keys = {};

  /// Every listing read so far, in read order; unmodifiable.
  List<VehicleListing> get all => List.unmodifiable(_all);

  /// True when nothing has been read yet.
  bool get isEmpty => _all.isEmpty;

  /// Adds [listings], skipping any whose [VehicleListing.dedupeKey] matches
  /// one already stored.
  void addAll(Iterable<VehicleListing> listings) {
    for (final l in listings) {
      if (_keys.add(l.dedupeKey)) _all.add(l);
    }
  }

  /// Forgets every listing.
  void clear() {
    _all.clear();
    _keys.clear();
  }

  /// Searches with the live query, cheapest first, at most [limit] results.
  /// Make and model must appear in the title; any word of
  /// [SearchQuery.keywords] may. Unpriced listings never match a price
  /// bound; listings without a mileage or a year pass those bounds, since
  /// the page may simply not show them. [SearchQuery.bodyStyle] is not
  /// applied: no reader fills [VehicleListing.bodyStyle] yet, so the site's
  /// own filter is what narrows the inventory to a style.
  List<VehicleListing> searchQuery(SearchQuery q, {int limit = 8}) {
    final words = (q.keywords ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final results = _all.where((l) {
      if (q.maxPrice != null && (l.price == null || l.price! > q.maxPrice!)) return false;
      if (q.minPrice != null && (l.price == null || l.price! < q.minPrice!)) return false;
      if (q.maxMileage != null && l.mileage != null && l.mileage! > q.maxMileage!) return false;
      if (q.minYear != null && l.year != null && l.year! < q.minYear!) return false;
      final hay = l.title.toLowerCase();
      if (q.make != null && !hay.contains(q.make!.toLowerCase())) return false;
      if (q.model != null && !hay.contains(q.model!.toLowerCase())) return false;
      if (words.isNotEmpty && !words.any(hay.contains)) return false;
      return true;
    }).toList()..sort((a, b) => (a.price ?? double.infinity).compareTo(b.price ?? double.infinity));
    return results.take(limit).toList();
  }
}
