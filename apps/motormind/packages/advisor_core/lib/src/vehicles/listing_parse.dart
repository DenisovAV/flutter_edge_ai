/// Text parsing shared by the listing readers. Private to the package: the
/// pattern extractor, the recipe reader and the search inference must agree
/// on what a price, an odometer figure and a "year make model" heading look
/// like, so each lives here once and a fix lands in all three.
library;

/// Listings one page read may yield, for every reader. Results pages show
/// 20 to 40 cards, so this keeps a whole page while bounding what the store
/// and the model are handed from a page that scrolls forever.
const int defaultMaxListings = 40;

/// Make aliases people and pages use, lower-cased, mapped to the display
/// name Motormind shows. Acronym makes are listed so "bmw" never becomes
/// "Bmw"; two-word makes so "Land Rover Range Rover" splits at the right
/// place; nicknames so "chevy" and "vw" find the right inventory.
const Map<String, String> vehicleMakes = {
  'acura': 'Acura',
  'alfa romeo': 'Alfa Romeo',
  'aston martin': 'Aston Martin',
  'audi': 'Audi',
  'bmw': 'BMW',
  'buick': 'Buick',
  'cadillac': 'Cadillac',
  'chevrolet': 'Chevrolet',
  'chevy': 'Chevrolet',
  'chrysler': 'Chrysler',
  'dodge': 'Dodge',
  'fiat': 'Fiat',
  'ford': 'Ford',
  'genesis': 'Genesis',
  'gmc': 'GMC',
  'honda': 'Honda',
  'hyundai': 'Hyundai',
  'infiniti': 'Infiniti',
  'jaguar': 'Jaguar',
  'jeep': 'Jeep',
  'kia': 'Kia',
  'land rover': 'Land Rover',
  'lexus': 'Lexus',
  'lincoln': 'Lincoln',
  'lucid': 'Lucid',
  'maserati': 'Maserati',
  'mazda': 'Mazda',
  'mercedes': 'Mercedes-Benz',
  'mercedes-benz': 'Mercedes-Benz',
  'mini': 'MINI',
  'mitsubishi': 'Mitsubishi',
  'nissan': 'Nissan',
  'polestar': 'Polestar',
  'porsche': 'Porsche',
  'ram': 'Ram',
  'rivian': 'Rivian',
  'rolls-royce': 'Rolls-Royce',
  'rolls royce': 'Rolls-Royce',
  'subaru': 'Subaru',
  'tesla': 'Tesla',
  'toyota': 'Toyota',
  'volkswagen': 'Volkswagen',
  'vw': 'Volkswagen',
  'volvo': 'Volvo',
};

/// The keys of [vehicleMakes] longest first, so "land rover" is tried before
/// any one-word make could claim "Land" and leave "Rover" in the model.
final List<String> makeAliasesLongestFirst = List.unmodifiable(
  vehicleMakes.keys.toList()..sort((a, b) => b.length.compareTo(a.length)),
);

/// The display name for a make as a page or person wrote it ("bmw" gives
/// "BMW", "Chevy" gives "Chevrolet"); the trimmed input when it is unknown.
String displayMake(String raw) => vehicleMakes[raw.trim().toLowerCase()] ?? raw.trim();

/// A listing heading: "2021 Honda CR-V EX-L", "Used 2019 Ford Mustang GT",
/// "2022 Land Rover Range Rover". Group 1 is the year, group 2 the make and
/// model text, which [splitMakeModel] divides. Not "2023" alone (a bare year
/// line) and not "2020 models in stock" (the make must be capitalized).
final RegExp yearMakeModelPattern = RegExp(
  r'^(?:(?:New|Used|Certified|CPO|Pre-Owned)\s+)?((?:19|20)\d{2})\s+([A-Z][A-Za-z\-]+\s+[A-Za-z0-9][^\n]{0,60})$',
);

/// Year, make, model and the heading without its condition word, or null
/// when [line] is not a heading [yearMakeModelPattern] recognizes.
({int year, String make, String model, String title})? parseTitle(String line) {
  final m = yearMakeModelPattern.firstMatch(line.trim());
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final rest = m.group(2)!.trim();
  final parts = splitMakeModel(rest);
  return (year: year, make: parts.make, model: parts.model, title: '$year $rest');
}

/// Splits "Land Rover Range Rover" into make "Land Rover" and model
/// "Range Rover", and "bmw X3" into "BMW" and "X3". An unknown make is the
/// first word as written; the model is empty when nothing follows it.
({String make, String model}) splitMakeModel(String text) {
  final t = text.trim();
  final lower = t.toLowerCase();
  for (final alias in makeAliasesLongestFirst) {
    if (!lower.startsWith(alias)) continue;
    final boundary = lower.length == alias.length || lower[alias.length].trim().isEmpty;
    if (boundary) return (make: vehicleMakes[alias]!, model: t.substring(alias.length).trim());
  }
  final space = t.indexOf(RegExp(r'\s'));
  if (space < 0) return (make: t, model: '');
  return (make: t.substring(0, space), model: t.substring(space + 1).trim());
}

/// An asking price: "$27,995", "$ 27995", "27,995" and "$24,998 $430/mo"
/// (the first figure). Not "$430/mo" (a monthly payment), "45,210 mi" (an
/// odometer) or "Stock #: PPWY18150" (a stock number has neither a dollar
/// sign nor comma groups). Group 1 holds a figure led by a dollar sign,
/// group 2 a bare comma-grouped figure.
final RegExp pricePattern = RegExp(
  r'(?:\$\s?(\d{1,3}(?:,\d{3})+|\d{4,6})|\b(\d{1,3}(?:,\d{3})+))(?!\d)'
  r'(?!\s*(?:/\s*mo|per\s+month|a\s+month|mi\b|miles))',
  caseSensitive: false,
);

/// The first price in [text], in dollars, or null when there is none.
double? tryParsePrice(String text) => parseAllPrices(text).firstOrNull;

/// Every price in [text] in reading order; see [pricePattern] for what
/// counts as one.
Iterable<double> parseAllPrices(String text) => pricePattern
    .allMatches(text)
    .map((m) => double.parse((m.group(1) ?? m.group(2)!).replaceAll(',', '')));

/// An odometer figure with its unit: "45,210 mi", "35K mi", "61,002 miles",
/// "1 Owner, 34,210 mi" (the figure before the unit, not the owner count).
/// Not "3 mi" (a distance to a store needs a comma group, 3+ digits or a k).
final RegExp _milesWithUnit = RegExp(
  r'(\d{1,3}(?:,\d{3})+|\d{3,6}|\d{1,3}(?:\.\d)?[kK])\s*(?:mi\b|miles)',
  caseSensitive: false,
);

/// A bare odometer figure from a field that holds only the number: "52K",
/// "34,210", "Mileage: 52,000". Only tried when no unit was found.
final RegExp _milesBare = RegExp(r'(\d{1,3}(?:,\d{3})+|\d{1,6}(?:\.\d)?[kK]?)\b');

/// Miles from [text]: a figure next to "mi" or "miles" first, then, unless
/// [requireUnit], a bare number. Null when neither is there. [requireUnit]
/// is for free page text, where a bare number is a stock number or a year.
int? tryParseMiles(String text, {bool requireUnit = false}) {
  final withUnit = _milesWithUnit.firstMatch(text);
  if (withUnit != null) return _miles(withUnit.group(1)!);
  if (requireUnit) return null;
  final bare = _milesBare.firstMatch(text);
  return bare == null ? null : _miles(bare.group(1)!);
}

int? _miles(String figure) {
  final v = figure.replaceAll(',', '').toLowerCase();
  if (v.endsWith('k')) {
    final n = double.tryParse(v.substring(0, v.length - 1));
    return n == null ? null : (n * 1000).round();
  }
  return int.tryParse(v);
}
