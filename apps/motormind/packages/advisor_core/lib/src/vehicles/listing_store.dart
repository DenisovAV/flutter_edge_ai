import 'listing.dart';
import 'search_query.dart';

/// Listings read during this session (Q45: session scope; saving across
/// conversations is a separate, explicit action). `find_vehicles` searches
/// here. Listings carry `readAt` so staleness can be shown later (DD-R15).
class ListingStore {
  final List<VehicleListing> _all = [];

  List<VehicleListing> get all => List.unmodifiable(_all);
  bool get isEmpty => _all.isEmpty;

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

  void clear() => _all.clear();

  /// Search with the live query; listings carry no body style yet, so that
  /// filter is applied by the site, not here.
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
