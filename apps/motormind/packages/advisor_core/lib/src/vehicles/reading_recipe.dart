import 'package:html/dom.dart' show Document, Element;
import 'package:html/parser.dart' show parse;

import 'listing.dart';
import 'listing_parse.dart';

/// How far a [ReadingRecipe] has been trusted.
enum RecipeStatus {
  /// Read a real page and passed its self-check.
  verified,

  /// Written from documentation; not yet seen working on a real page.
  unverified,

  /// Failed its self-check on a real page; waiting for a repair.
  broken,
}

/// Marks an omitted `note` argument in [ReadingRecipe.withStatus], so that
/// an explicit null can mean "clear the note".
const _keepNote = Object();

/// A per-site reading recipe: data, not code . It names the
/// listing card element, where each field sits inside it, and how to tell
/// whether the read worked. Shipped as a JSON asset, replaceable at runtime,
/// so a repaired recipe (from a person today, a help service later)
/// is a drop-in. The on-device model never sees HTML.
class ReadingRecipe {
  /// Creates a recipe; see the fields for what each part means.
  const ReadingRecipe({
    required this.siteId,
    required this.version,
    required this.card,
    required this.fields,
    this.selfCheck = const SelfCheckRules(),
    this.status = RecipeStatus.verified,
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

  /// How to tell whether a read of a real page worked.
  final SelfCheckRules selfCheck;

  /// How far the recipe has been trusted; see [RecipeStatus].
  final RecipeStatus status;

  /// Free text about the recipe's origin or its last repair.
  final String? note;

  /// Restores a recipe from its JSON asset form; missing optional fields
  /// take their defaults. Throws a [FormatException] naming the field when
  /// a required one is missing or of the wrong type, so a hand-edited asset
  /// fails with a message a person can act on.
  factory ReadingRecipe.fromJson(Map<String, Object?> json) {
    final rawFields = _require<Map>(json, 'fields', 'recipe');
    final rawStatus = json['status'];
    final status = switch (rawStatus) {
      null => RecipeStatus.verified,
      String() => RecipeStatus.values.asNameMap()[rawStatus],
      _ => null,
    };
    if (status == null) {
      throw FormatException(
        'recipe: unknown status "$rawStatus"; expected one of '
        '${RecipeStatus.values.map((s) => s.name).join(', ')}',
      );
    }
    return ReadingRecipe(
      siteId: _require<String>(json, 'siteId', 'recipe'),
      version: _optional<num>(json, 'version', 'recipe')?.toInt() ?? 1,
      card: _require<String>(json, 'card', 'recipe'),
      fields: {
        for (final e in rawFields.entries)
          e.key.toString(): FieldRule.fromJson(_asMap(e.value, 'recipe.fields.${e.key}')),
      },
      selfCheck: json['selfCheck'] == null
          ? const SelfCheckRules()
          : SelfCheckRules.fromJson(_asMap(json['selfCheck'], 'recipe.selfCheck')),
      status: status,
      note: _optional<String>(json, 'note', 'recipe'),
    );
  }

  /// Serializes in the JSON asset form read by [ReadingRecipe.fromJson].
  /// Optional values are left out when unset, so a hand-written asset and a
  /// serialized one look the same.
  Map<String, Object?> toJson() => {
    'siteId': siteId,
    'version': version,
    'card': card,
    'fields': {for (final e in fields.entries) e.key: e.value.toJson()},
    'selfCheck': selfCheck.toJson(),
    'status': status.name,
    if (note != null) 'note': note,
  };

  /// Returns a copy with [status] replaced. [note] replaces the note when
  /// given, clears it when explicitly null, and is kept when omitted, so a
  /// repair can wipe a stale failure message.
  ReadingRecipe withStatus(RecipeStatus status, {Object? note = _keepNote}) => ReadingRecipe(
    siteId: siteId,
    version: version,
    card: card,
    fields: fields,
    selfCheck: selfCheck,
    status: status,
    note: identical(note, _keepNote) ? this.note : note as String?,
  );
}

T _require<T extends Object>(Map<String, Object?> json, String key, String where) {
  final v = json[key];
  if (v is T) return v;
  if (v == null) throw FormatException('$where: "$key" is required');
  throw FormatException('$where: "$key" must be a $T, not ${v.runtimeType}');
}

T? _optional<T extends Object>(Map<String, Object?> json, String key, String where) {
  final v = json[key];
  if (v == null || v is T) return v as T?;
  throw FormatException('$where: "$key" must be a $T, not ${v.runtimeType}');
}

Map<String, Object?> _asMap(Object? v, String where) {
  if (v is Map) return v.cast<String, Object?>();
  throw FormatException('$where must be an object, not ${v.runtimeType}');
}

/// Compiled field patterns by source, so a recipe read over forty cards
/// compiles each pattern once. [FieldRule] is const, which rules out a
/// late field on the instance.
final Map<String, RegExp> _patternCache = {};

/// Collapses runs of whitespace in a read value.
final RegExp _whitespace = RegExp(r'\s+');

/// Separates `srcset` candidates: a comma followed by a URL start, so a
/// comma inside a URL's query string does not split it.
final RegExp _srcsetSeparator = RegExp(r',\s*(?=https?:|/)');

/// Where a field lives inside a card: a selector (relative to the card; empty
/// means the card itself), an attribute to read instead of the text, and an
/// optional regex whose first group is the value. [attrs] lists attributes to
/// try in order (lazy-loaded images keep the real source in `data-src` or
/// `srcset` until scrolled into view).
class FieldRule {
  /// Creates a rule; an empty [selector] reads the card element itself.
  const FieldRule({this.selector = '', this.attrs = const [], this.pattern});

  /// CSS selector relative to the card; empty for the card itself.
  final String selector;

  /// Attributes to try in order; empty to read the element's text.
  final List<String> attrs;

  /// Case-insensitive regular expression applied to the raw value; the first
  /// group is the value when the pattern has one, the whole match otherwise.
  final String? pattern;

  /// Restores a rule from JSON. A singular `attr` key is accepted ahead of
  /// the `attrs` list because a hand-written recipe for one attribute reads
  /// better that way; [toJson] always writes `attrs`.
  factory FieldRule.fromJson(Map<String, Object?> json) {
    final attrs = json['attrs'];
    if (attrs != null && (attrs is! List || attrs.any((a) => a is! String))) {
      throw const FormatException('field rule: "attrs" must be a list of strings');
    }
    return FieldRule(
      selector: json['selector'] as String? ?? '',
      attrs: [if (json['attr'] is String) json['attr'] as String, ...?(attrs as List?)?.cast()],
      pattern: json['pattern'] as String?,
    );
  }

  /// Serializes the rule for the JSON asset; unset optionals are left out.
  Map<String, Object?> toJson() => {
    'selector': selector,
    if (attrs.isNotEmpty) 'attrs': attrs,
    if (pattern != null) 'pattern': pattern,
  };

  /// Reads the field from [card]; null when the element, attribute or
  /// pattern does not match. Whitespace is collapsed and a `srcset` value
  /// is reduced to its largest candidate, the one worth showing on a card.
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
          raw = a == 'srcset' ? _largestSrcsetCandidate(v) : v;
          break;
        }
      }
    }
    if (raw == null) return null;
    raw = raw.replaceAll(_whitespace, ' ').trim();
    if (pattern == null) return raw.isEmpty ? null : raw;
    final re = _patternCache.putIfAbsent(pattern!, () => RegExp(pattern!, caseSensitive: false));
    final m = re.firstMatch(raw);
    if (m == null) return null;
    return (m.groupCount >= 1 ? m.group(1) : m.group(0))?.trim();
  }

  /// The URL with the largest width descriptor ("640w"); a candidate without
  /// one counts as width zero, so the first such URL wins only when no
  /// candidate names a width.
  static String _largestSrcsetCandidate(String srcset) {
    String? best;
    var bestWidth = -1;
    for (final candidate in srcset.split(_srcsetSeparator)) {
      final parts = candidate.trim().split(_whitespace);
      if (parts.isEmpty || parts.first.isEmpty) continue;
      final descriptor = parts.length > 1 ? parts[1].toLowerCase() : '';
      final width = descriptor.endsWith('w')
          ? int.tryParse(descriptor.substring(0, descriptor.length - 1)) ?? 0
          : 0;
      if (width > bestWidth) {
        best = parts.first;
        bestWidth = width;
      }
    }
    return best ?? srcset;
  }
}

/// What a successful read must look like. A read that finds *some* cards but
/// not these is worse than none (a site change that half-works), so the rules
/// are about plausibility, not presence.
class SelfCheckRules {
  /// Creates rules; the defaults expect at least three cards, most of them
  /// priced, and do not require images.
  const SelfCheckRules({
    this.minCards = defaultMinCards,
    this.minPriceFraction = defaultMinPriceFraction,
    this.minImageFraction = defaultMinImageFraction,
    this.totalPattern,
    this.maxTotalRatio = defaultMaxTotalRatio,
  });

  /// Default for [minCards]: fewer than three cards is a missed selector,
  /// not a short page. [SelfCheckRules.fromJson] fills missing fields from
  /// these defaults.
  static const defaultMinCards = 3;

  /// Default for [minPriceFraction]: most cards carry a price.
  static const defaultMinPriceFraction = 0.8;

  /// Default for [minImageFraction]: images are not required.
  static const defaultMinImageFraction = 0.0;

  /// Default for [maxTotalRatio]: never more cards than the page's own total.
  static const defaultMaxTotalRatio = 1.0;

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

  /// Largest acceptable ratio of cards read to the page's own total; a read
  /// above it is implausible.
  final double maxTotalRatio;

  /// Restores rules from JSON; missing fields take their defaults.
  factory SelfCheckRules.fromJson(Map<String, Object?> json) => SelfCheckRules(
    minCards: _optional<num>(json, 'minCards', 'selfCheck')?.toInt() ?? 3,
    minPriceFraction: _optional<num>(json, 'minPriceFraction', 'selfCheck')?.toDouble() ?? 0.8,
    minImageFraction: _optional<num>(json, 'minImageFraction', 'selfCheck')?.toDouble() ?? 0.0,
    totalPattern: _optional<String>(json, 'totalPattern', 'selfCheck'),
    maxTotalRatio: _optional<num>(json, 'maxTotalRatio', 'selfCheck')?.toDouble() ?? 1.0,
  );

  /// Serializes the rules for the JSON asset; unset optionals are left out.
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
  /// Creates an outcome; [ok] is false whenever [problems] is non-empty.
  const SelfCheck({
    required this.ok,
    required this.cardsFound,
    required this.withPrice,
    required this.withImage,
    this.pageTotal,
    this.problems = const [],
  });

  /// True when the read passed every rule and found at least one listing.
  final bool ok;

  /// Listings read, after duplicates were dropped.
  final int cardsFound;

  /// How many of [cardsFound] carried a price.
  final int withPrice;

  /// How many of [cardsFound] carried an image.
  final int withImage;

  /// The page's own result count, when [SelfCheckRules.totalPattern] matched.
  final int? pageTotal;

  /// Each failed rule in words; empty when [ok].
  final List<String> problems;

  /// Restores a check from its [toJson] form (captures keep the verdict).
  factory SelfCheck.fromJson(Map<String, Object?> json) => SelfCheck(
    ok: json['ok'] == true,
    cardsFound: (json['cardsFound'] as num?)?.toInt() ?? 0,
    withPrice: (json['withPrice'] as num?)?.toInt() ?? 0,
    withImage: (json['withImage'] as num?)?.toInt() ?? 0,
    pageTotal: (json['pageTotal'] as num?)?.toInt(),
    problems: ((json['problems'] as List?) ?? const []).cast<String>(),
  );

  /// Serializes the verdict so a capture can keep it; unset optionals are
  /// left out.
  Map<String, Object?> toJson() => {
    'ok': ok,
    'cardsFound': cardsFound,
    'withPrice': withPrice,
    'withImage': withImage,
    if (pageTotal != null) 'pageTotal': pageTotal,
    'problems': problems,
  };

  @override
  String toString() => ok
      ? '$cardsFound cards, $withPrice priced, $withImage with image'
      : 'failed: ${problems.join('; ')}';
}

/// What [RecipeReader.read] produces: the listings, the self-check and the
/// recipe that was used.
class RecipeResult {
  /// Creates a result.
  const RecipeResult({required this.listings, required this.check, required this.recipe});

  /// Listings read from the page, at most [RecipeReader.maxListings].
  final List<VehicleListing> listings;

  /// Whether the read looked right, and if not, why.
  final SelfCheck check;

  /// The recipe the read used, so its version and status can be reported.
  final ReadingRecipe recipe;
}

/// What a pass over the cards counted, before the rules are applied.
typedef _CardCounts = ({
  List<VehicleListing> listings,
  int cards,
  int untitled,
  int duplicates,
  int withPrice,
  int withImage,
});

/// One generic reader for every recipe. Pure Dart over the page's HTML, so it
/// runs the same in a widget test over a captured page as on the phone.
class RecipeReader {
  /// Creates a reader that stops after [maxListings] listings.
  const RecipeReader({this.maxListings = defaultMaxListings});

  /// Upper bound on listings returned from one page.
  final int maxListings;

  /// Reads [html] with [recipe]. [sourceUrl] resolves relative image and
  /// detail links and is recorded on each listing; [now] is the read time.
  /// Year, make and model are parsed from the title when the recipe does not
  /// read them separately.
  RecipeResult read(
    String html,
    ReadingRecipe recipe, {
    required String sourceUrl,
    required DateTime now,
  }) {
    final Document doc = parse(html);
    final counts = _readCards(doc, recipe, sourceUrl: sourceUrl, now: now);
    return RecipeResult(
      listings: counts.listings,
      recipe: recipe,
      check: _check(counts, recipe, doc.body?.text ?? ''),
    );
  }

  _CardCounts _readCards(
    Document doc,
    ReadingRecipe recipe, {
    required String sourceUrl,
    required DateTime now,
  }) {
    final cards = doc.querySelectorAll(recipe.card);
    final out = <VehicleListing>[];
    final seen = <String>{};
    var untitled = 0;
    var duplicates = 0;
    var withPrice = 0;
    var withImage = 0;
    for (final card in cards) {
      if (out.length >= maxListings) break;
      final title = recipe.fields['title']?.read(card);
      if (title == null || title.isEmpty) {
        untitled++;
        continue;
      }
      final priceRaw = recipe.fields['price']?.read(card);
      final mileageRaw = recipe.fields['mileage']?.read(card);
      final yearRaw = recipe.fields['year']?.read(card);
      final heading = parseTitle(title);
      final listing = VehicleListing(
        id: 'v${out.length + 1}',
        title: title,
        sourceUrl: sourceUrl,
        readAt: now,
        price: priceRaw == null ? null : tryParsePrice(priceRaw),
        mileage: mileageRaw == null ? null : tryParseMiles(mileageRaw),
        year: (yearRaw == null ? null : int.tryParse(yearRaw)) ?? heading?.year,
        make: heading?.make,
        model: heading?.model,
        imageUrl: _absolute(recipe.fields['image']?.read(card), sourceUrl),
        detailUrl: _absolute(recipe.fields['link']?.read(card), sourceUrl),
      );
      if (!seen.add(listing.dedupeKey)) {
        duplicates++;
        continue;
      }
      if (listing.price != null) withPrice++;
      if (listing.imageUrl != null) withImage++;
      out.add(listing);
    }
    return (
      listings: out,
      cards: cards.length,
      untitled: untitled,
      duplicates: duplicates,
      withPrice: withPrice,
      withImage: withImage,
    );
  }

  SelfCheck _check(_CardCounts counts, ReadingRecipe recipe, String pageText) {
    final rules = recipe.selfCheck;
    final read = counts.listings.length;
    final problems = <String>[];
    int? pageTotal;
    if (rules.totalPattern != null) {
      final t = RegExp(rules.totalPattern!, caseSensitive: false).firstMatch(pageText);
      if (t != null) pageTotal = int.tryParse((t.group(1) ?? '').replaceAll(',', ''));
    }
    if (counts.cards == 0) {
      problems.add('no elements match card selector "${recipe.card}"');
    } else if (read < rules.minCards) {
      problems.add('read $read listings but the recipe expects at least ${rules.minCards}');
      if (counts.untitled > 0) {
        final titled = counts.cards - counts.untitled;
        problems.add('${counts.cards} cards matched but only $titled had a title');
      }
      if (counts.duplicates > 0) {
        problems.add('${counts.duplicates} cards repeated an earlier listing');
      }
    }
    if (read > 0 && counts.withPrice / read < rules.minPriceFraction) {
      problems.add('only ${counts.withPrice} of $read cards had a price');
    }
    if (read > 0 && counts.withImage / read < rules.minImageFraction) {
      problems.add('only ${counts.withImage} of $read cards had an image');
    }
    if (pageTotal != null && pageTotal == 0 && read > 0) {
      problems.add('page says 0 results but $read cards were read');
    }
    if (pageTotal != null && pageTotal > 0 && read > pageTotal * rules.maxTotalRatio) {
      problems.add('read $read cards but the page says $pageTotal results');
    }
    return SelfCheck(
      ok: problems.isEmpty && read > 0,
      cardsFound: read,
      withPrice: counts.withPrice,
      withImage: counts.withImage,
      pageTotal: pageTotal,
      problems: problems,
    );
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
