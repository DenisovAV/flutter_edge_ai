/// A vehicle listing as read from a page. Facts only, with the page it came
/// from, so the person can open the source and so staleness can be shown.
class VehicleListing {
  /// Creates a listing; [readAt] is when its page was read.
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

  /// Identifier within one read (`v1`, `v2`, ...); the model refers to it.
  final String id;

  /// The listing heading as the page showed it, typically year, make and
  /// model.
  final String title;

  /// The page the listing was read from.
  final String sourceUrl;

  /// When the page was read, so staleness can be shown.
  final DateTime readAt;

  /// Asking price in dollars; null when the page showed none.
  final double? price;

  /// Odometer reading in miles; null when not shown.
  final int? mileage;

  /// Model year; null when it could not be read.
  final int? year;

  /// Manufacturer, when parsed from the title.
  final String? make;

  /// Model name and trim, when parsed from the title.
  final String? model;

  /// Body style when the page states it; the current readers leave it null.
  final String? bodyStyle;

  /// Main photo URL, when a recipe reads one.
  final String? imageUrl;

  /// URL of the listing's own page, when a recipe reads one.
  final String? detailUrl;

  /// Full form for the UI and the store; see [toModelJson] for the model's
  /// view.
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
  /// Creates an extract for the page at [url].
  const PageExtract({
    required this.url,
    required this.title,
    required this.text,
    required this.listings,
    this.imageUrl,
  });

  /// The page that was read.
  final String url;

  /// The page title.
  final String title;

  /// Cleaned visible text; the app caps it before it reaches the model.
  final String text;

  /// Listings found on the page; empty for a page without any.
  final List<VehicleListing> listings;

  /// A representative image from the page, when one was found.
  final String? imageUrl;

  /// Full form for the UI, with every listing serialized.
  Map<String, Object?> toJson() => {
    'url': url,
    'title': title,
    'text': text,
    'imageUrl': imageUrl,
    'listings': [for (final l in listings) l.toJson()],
  };
}
