/// A vehicle listing as read from a page. Facts only, with the page it came
/// from, so the person can open the source and so staleness can be shown.
class VehicleListing {
  const VehicleListing({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.readAt,
    this.price,
    this.mileage,
    this.year,
    this.make,
    this.model,
    this.bodyStyle,
    this.imageUrl,
    this.detailUrl,
  });

  final String id;
  final String title;
  final String sourceUrl;
  final DateTime readAt;
  final double? price;
  final int? mileage;
  final int? year;
  final String? make;
  final String? model;
  final String? bodyStyle;
  final String? imageUrl;
  final String? detailUrl;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'price': price,
    'mileage': mileage,
    'year': year,
    'make': make,
    'model': model,
    'bodyStyle': bodyStyle,
    'imageUrl': imageUrl,
    'detailUrl': detailUrl,
    'sourceUrl': sourceUrl,
    'readAt': readAt.toIso8601String(),
  };

  /// Compact form for the model: no URLs, no timestamps.
  Map<String, Object?> toModelJson() => {
    'id': id,
    'title': title,
    'price': ?price,
    'mileage': ?mileage,
    'year': ?year,
  };
}

/// What `read_page` returns: cleaned text plus whatever listings the page
/// yielded. The text is capped before it reaches the model.
class PageExtract {
  const PageExtract({
    required this.url,
    required this.title,
    required this.text,
    required this.listings,
    this.imageUrl,
  });

  final String url;
  final String title;
  final String text;
  final List<VehicleListing> listings;
  final String? imageUrl;

  Map<String, Object?> toJson() => {
    'url': url,
    'title': title,
    'text': text,
    'imageUrl': imageUrl,
    'listings': [for (final l in listings) l.toJson()],
  };
}
