import 'package:html/dom.dart' show Document, Element;
import 'package:html/parser.dart' show parse;

import 'listing.dart';
import 'listing_extractor.dart' show ListingExtractor;

/// A per-site reading recipe: data, not code (TQ71, DD-R26). It names the
/// listing card element, where each field sits inside it, and how to tell
/// whether the read worked. Shipped as a JSON asset, replaceable at runtime,
/// so a repaired recipe (from a person today, a help service later, DD-R27)
/// is a drop-in. The on-device model never sees HTML.
class ReadingRecipe {
  const ReadingRecipe({
    required this.siteId,
    required this.version,
    required this.card,
    required this.fields,
    this.selfCheck = const SelfCheckRules(),
    this.status = 'verified',
    this.note,
  });

  /// Matches `CuratedSite.id`.
  final String siteId;

  /// Bumped on every repair; the app keeps the highest version that passes.
  final int version;

  /// CSS selector for one listing card.
  final String card;

  /// Field name → how to find it inside a card. Known names: title, price,
  /// mileage, year, image, link.
  final Map<String, FieldRule> fields;
  final SelfCheckRules selfCheck;

  /// `verified` (read a real page), `unverified` (written from documentation,
  /// not yet seen working), `broken` (failed its self-check on a real page).
  final String status;
  final String? note;

  factory ReadingRecipe.fromJson(Map<String, Object?> json) => ReadingRecipe(
    siteId: json['siteId'] as String,
    version: (json['version'] as num?)?.toInt() ?? 1,
    card: json['card'] as String,
    fields: {
      for (final e in (json['fields'] as Map).entries)
        e.key as String: FieldRule.fromJson((e.value as Map).cast<String, Object?>()),
    },
    selfCheck: json['selfCheck'] is Map
        ? SelfCheckRules.fromJson((json['selfCheck'] as Map).cast<String, Object?>())
        : const SelfCheckRules(),
    status: json['status'] as String? ?? 'verified',
    note: json['note'] as String?,
  );

  Map<String, Object?> toJson() => {
    'siteId': siteId,
    'version': version,
    'card': card,
    'fields': {for (final e in fields.entries) e.key: e.value.toJson()},
    'selfCheck': selfCheck.toJson(),
    'status': status,
    if (note != null) 'note': note,
  };

  ReadingRecipe copyWith({String? status, String? note}) => ReadingRecipe(
    siteId: siteId,
    version: version,
    card: card,
    fields: fields,
    selfCheck: selfCheck,
    status: status ?? this.status,
    note: note ?? this.note,
  );
}

/// Where a field lives inside a card: a selector (relative to the card; empty
/// means the card itself), an attribute to read instead of the text, and an
/// optional regex whose first group is the value. [attrs] lists attributes to
/// try in order (lazy-loaded images keep the real source in `data-src` or
/// `srcset` until scrolled into view).
class FieldRule {
  const FieldRule({this.selector = '', this.attrs = const [], this.pattern});

  final String selector;
  final List<String> attrs;
  final String? pattern;

  factory FieldRule.fromJson(Map<String, Object?> json) => FieldRule(
    selector: json['selector'] as String? ?? '',
    attrs: [
      if (json['attr'] is String) json['attr'] as String,
      ...?(json['attrs'] as List?)?.cast<String>(),
    ],
    pattern: json['pattern'] as String?,
  );

  Map<String, Object?> toJson() => {
    'selector': selector,
    if (attrs.isNotEmpty) 'attrs': attrs,
    if (pattern != null) 'pattern': pattern,
  };

  String? read(Element card) {
    final el = selector.isEmpty ? card : card.querySelector(selector);
    if (el == null) return null;
    String? raw;
    if (attrs.isEmpty) {
      raw = el.text;
    } else {
      for (final a in attrs) {
        final v = el.attributes[a];
        if (v != null && v.trim().isNotEmpty) {
          raw = a == 'srcset' ? v.split(',').first.trim().split(' ').first : v;
          break;
        }
      }
    }
    if (raw == null) return null;
    raw = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (pattern == null) return raw.isEmpty ? null : raw;
    final m = RegExp(pattern!, caseSensitive: false).firstMatch(raw);
    if (m == null) return null;
    return (m.groupCount >= 1 ? m.group(1) : m.group(0))?.trim();
  }
}

/// What a successful read must look like. A read that finds *some* cards but
/// not these is worse than none (a site change that half-works), so the rules
/// are about plausibility, not presence.
class SelfCheckRules {
  const SelfCheckRules({
    this.minCards = 3,
    this.minPriceFraction = 0.8,
    this.minImageFraction = 0.0,
    this.totalPattern,
    this.maxTotalRatio = 1.0,
  });

  /// Fewer cards than this on a results page means the recipe missed them.
  final int minCards;

  /// Fraction of cards that must carry a price.
  final double minPriceFraction;

  /// Fraction of cards that must carry an image (0 when images are not read).
  final double minImageFraction;

  /// Regex (first group = number) run over the page's visible text to find the
  /// site's own total ("334 used cars at EchoPark"). When present, the cards
  /// read must not exceed that total.
  final String? totalPattern;
  final double maxTotalRatio;

  factory SelfCheckRules.fromJson(Map<String, Object?> json) => SelfCheckRules(
    minCards: (json['minCards'] as num?)?.toInt() ?? 3,
    minPriceFraction: (json['minPriceFraction'] as num?)?.toDouble() ?? 0.8,
    minImageFraction: (json['minImageFraction'] as num?)?.toDouble() ?? 0.0,
    totalPattern: json['totalPattern'] as String?,
    maxTotalRatio: (json['maxTotalRatio'] as num?)?.toDouble() ?? 1.0,
  );

  Map<String, Object?> toJson() => {
    'minCards': minCards,
    'minPriceFraction': minPriceFraction,
    'minImageFraction': minImageFraction,
    if (totalPattern != null) 'totalPattern': totalPattern,
    'maxTotalRatio': maxTotalRatio,
  };
}

/// The outcome of a self-check: what was counted and why it failed, in words
/// a person (or a repair service) can act on.
class SelfCheck {
  const SelfCheck({
    required this.ok,
    required this.cardsFound,
    required this.withPrice,
    required this.withImage,
    this.pageTotal,
    this.problems = const [],
  });

  final bool ok;
  final int cardsFound;
  final int withPrice;
  final int withImage;
  final int? pageTotal;
  final List<String> problems;

  Map<String, Object?> toJson() => {
    'ok': ok,
    'cardsFound': cardsFound,
    'withPrice': withPrice,
    'withImage': withImage,
    'pageTotal': pageTotal,
    'problems': problems,
  };

  @override
  String toString() => ok
      ? '$cardsFound cards, $withPrice priced, $withImage with image'
      : 'failed: ${problems.join('; ')}';
}

class RecipeResult {
  const RecipeResult({required this.listings, required this.check, required this.recipe});
  final List<VehicleListing> listings;
  final SelfCheck check;
  final ReadingRecipe recipe;
}

/// One generic reader for every recipe. Pure Dart over the page's HTML, so it
/// runs the same in a widget test over a captured page as on the phone.
class RecipeReader {
  const RecipeReader({this.maxListings = 40});

  final int maxListings;

  static final _yearMakeModel = RegExp(
    r'^(?:(?:New|Used|Certified|CPO|Pre-Owned)\s+)?((?:19|20)\d{2})\s+([A-Z][A-Za-z\-]+)\s+(.{1,60})$',
  );
  static final _money = RegExp(r'\$?\s?(\d{1,3}(?:,\d{3})+|\d{4,6})');

  RecipeResult read(
    String html,
    ReadingRecipe recipe, {
    required String sourceUrl,
    required DateTime now,
  }) {
    final Document doc = parse(html);
    final cards = doc.querySelectorAll(recipe.card);
    final out = <VehicleListing>[];
    var withPrice = 0;
    var withImage = 0;
    final seen = <String>{};
    for (final card in cards) {
      if (out.length >= maxListings) break;
      final title = recipe.fields['title']?.read(card);
      if (title == null || title.isEmpty) continue;
      final priceRaw = recipe.fields['price']?.read(card);
      final price = priceRaw == null ? null : _parseMoney(priceRaw);
      final mileageRaw = recipe.fields['mileage']?.read(card);
      final mileage = mileageRaw == null ? null : _parseMiles(mileageRaw);
      final image = _absolute(recipe.fields['image']?.read(card), sourceUrl);
      final link = _absolute(recipe.fields['link']?.read(card), sourceUrl);
      final yearRaw = recipe.fields['year']?.read(card);
      int? year = yearRaw == null ? null : int.tryParse(yearRaw);
      String? make;
      String? model;
      final m = _yearMakeModel.firstMatch(title);
      if (m != null) {
        year ??= int.tryParse(m.group(1)!);
        make = m.group(2);
        model = m.group(3)!.trim();
      }
      final key = '$title|$price|$mileage';
      if (!seen.add(key)) continue;
      if (price != null) withPrice++;
      if (image != null) withImage++;
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
          imageUrl: image,
          detailUrl: link,
        ),
      );
    }

    final rules = recipe.selfCheck;
    final problems = <String>[];
    int? pageTotal;
    if (rules.totalPattern != null) {
      final t = RegExp(rules.totalPattern!, caseSensitive: false).firstMatch(doc.body?.text ?? '');
      if (t != null) pageTotal = int.tryParse((t.group(1) ?? '').replaceAll(',', ''));
    }
    if (cards.isEmpty) {
      problems.add('no elements match card selector "${recipe.card}"');
    } else if (out.length < rules.minCards) {
      problems.add('${cards.length} cards matched but only ${out.length} had a title');
    }
    if (out.isNotEmpty && withPrice / out.length < rules.minPriceFraction) {
      problems.add('only $withPrice of ${out.length} cards had a price');
    }
    if (out.isNotEmpty && withImage / out.length < rules.minImageFraction) {
      problems.add('only $withImage of ${out.length} cards had an image');
    }
    if (pageTotal != null && pageTotal == 0 && out.isNotEmpty) {
      problems.add('page says 0 results but ${out.length} cards were read');
    }
    if (pageTotal != null && pageTotal > 0 && out.length > pageTotal * rules.maxTotalRatio) {
      problems.add('read ${out.length} cards but the page says $pageTotal results');
    }
    return RecipeResult(
      listings: out,
      recipe: recipe,
      check: SelfCheck(
        ok: problems.isEmpty && out.isNotEmpty,
        cardsFound: out.length,
        withPrice: withPrice,
        withImage: withImage,
        pageTotal: pageTotal,
        problems: problems,
      ),
    );
  }

  static double? _parseMoney(String raw) {
    if (RegExp(r'/\s*mo', caseSensitive: false).hasMatch(raw)) return null;
    final m = _money.firstMatch(raw);
    return m == null ? null : double.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  static int? _parseMiles(String raw) {
    final m = RegExp(
      r'(\d{1,3}(?:,\d{3})+|\d{1,6}(?:\.\d)?[kK]?)',
    ).firstMatch(raw.replaceAll(RegExp(r'\s'), ''));
    if (m == null) return null;
    try {
      return ListingExtractor.parseMiles(m.group(1)!);
    } on FormatException {
      return null;
    }
  }

  static String? _absolute(String? url, String base) {
    if (url == null || url.isEmpty) return null;
    final u = Uri.tryParse(url);
    if (u == null) return null;
    if (u.hasScheme) return url;
    final b = Uri.tryParse(base);
    return b == null ? url : b.resolveUri(u).toString();
  }
}
