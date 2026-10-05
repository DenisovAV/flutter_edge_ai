library;

import 'tts_text_normalizer.dart';
export 'tts_text_normalizer.dart';

/// English impl of [TtsTextNormalizer], PRESERVING punctuation as model
/// symbols. [symbols] is the model's symbol set (config.json `symbols`) — only
/// marks the model knows survive as SymbolToken; the rest are dropped as
/// non-speech. Numbers/years/acronyms are expanded to words and markdown/URLs
/// are stripped by [_preclean] before tokenization.
class EnglishTextNormalizer implements TtsTextNormalizer {
  const EnglishTextNormalizer(this.symbols);
  final Set<String> symbols;

  static final _letter = RegExp(r'[A-Za-z]');
  static final _whitespace = RegExp(r'\s');

  static const _ones = [
    'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
    'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
    'sixteen', 'seventeen', 'eighteen', 'nineteen', //
  ];
  static const _tens = [
    '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy',
    'eighty', 'ninety', //
  ];

  /// Strips markdown/URLs and expands numbers/years/acronyms to words, ahead
  /// of the rune loop below. No-op on already-clean text.
  String _preclean(String text) {
    var s = text;
    s = s.replaceAll(RegExp(r'https?://\S+'), ' '); // URLs
    // inline/fenced code: strip the backtick delimiters but KEEP the inner
    // text — LLM replies commonly wrap speakable values/words/commands in
    // backticks (e.g. "The answer is `42`."), and dropping the content
    // silently loses it (#PR-panel).
    s = s.replaceAllMapped(RegExp(r'`{1,3}([^`]*)`{1,3}'), (m) => ' ${m[1]} ');
    s = s.replaceAll(RegExp(r'[*_#>~|]'), ' '); // markdown punctuation
    s = s.replaceAllMapped(
      RegExp(r'\b\d[\d,]*\b'), // numbers
      (m) => ' ${_numberToWords(m[0]!.replaceAll(',', ''))} ',
    );
    s = s.replaceAllMapped(
      RegExp(r'\b[A-Z]{2,}\b'), // ALL-CAPS acronyms
      (m) => ' ${m[0]!.split('').join(' ')} ',
    );
    return s;
  }

  String _numberToWords(String digits) {
    final n = int.tryParse(digits);
    if (n == null) {
      return digits.split('').map((d) => _ones[int.parse(d)]).join(' ');
    }
    if (digits.length == 4 && n >= 1100 && n <= 9999) {
      // year: two pairs, e.g. 2023 -> "twenty twenty three". The last two
      // digits need special-casing: a round pair (2000) reads as a plain
      // number ("two thousand"), and 01-09 (2005) needs the "oh" that a
      // naive _below100(5) -> "five" would drop ("twenty oh five").
      final firstPair = n ~/ 100;
      final lastPair = n % 100;
      if (lastPair == 0) return _below1000000(n);
      if (lastPair <= 9) return '${_below100(firstPair)} oh ${_ones[lastPair]}';
      return '${_below100(firstPair)} ${_below100(lastPair)}'.trim();
    }
    if (n >= 1000000) {
      // Beyond standard word expansion: spell out digit-by-digit rather than
      // overflow _below1000000's internal 0-999 assumptions (RangeError).
      return digits.split('').map((d) => _ones[int.parse(d)]).join(' ');
    }
    return _below1000000(n);
  }

  String _below100(int n) => n < 20
      ? _ones[n]
      : '${_tens[n ~/ 10]}${n % 10 == 0 ? '' : ' ${_ones[n % 10]}'}';

  String _below1000(int n) => n < 100
      ? _below100(n)
      : '${_ones[n ~/ 100]} hundred${n % 100 == 0 ? '' : ' ${_below100(n % 100)}'}';

  String _below1000000(int n) => n < 1000
      ? _below1000(n)
      : '${_below1000(n ~/ 1000)} thousand${n % 1000 == 0 ? '' : ' ${_below1000(n % 1000)}'}';

  @override
  List<NormToken> normalize(String text) {
    text = _preclean(text);
    final out = <NormToken>[];
    final buf = StringBuffer();
    void flushWord() {
      if (buf.isNotEmpty) {
        out.add(WordToken(buf.toString().toLowerCase()));
        buf.clear();
      }
    }

    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (_letter.hasMatch(ch)) {
        buf.write(ch);
      } else if (ch == ' ' || _whitespace.hasMatch(ch)) {
        flushWord();
        if (out.isNotEmpty && out.last is! SymbolToken) {
          out.add(const SymbolToken(' '));
        }
      } else {
        flushWord();
        if (symbols.contains(ch)) out.add(SymbolToken(ch));
        // else: non-speech char; drop.
      }
    }
    flushWord();
    return out;
  }

  static final _digit = RegExp(r'[0-9]');

  @override
  List<String> splitClauses(String text) {
    final parts = <String>[];
    final buf = StringBuffer();
    final chars = text.runes.map(String.fromCharCode).toList();
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      buf.write(ch);
      if ('.!?,;:'.contains(ch)) {
        // A ',' or '.' flanked by digits is part of a number ("1,234",
        // "3.14"), not a clause boundary — splitting there tears the digit
        // group apart before the per-clause number expansion sees it.
        if ((ch == ',' || ch == '.') &&
            i > 0 &&
            i + 1 < chars.length &&
            _digit.hasMatch(chars[i - 1]) &&
            _digit.hasMatch(chars[i + 1])) {
          continue;
        }
        final s = buf.toString().trim();
        if (s.isNotEmpty) parts.add(s);
        buf.clear();
      }
    }
    final tail = buf.toString().trim();
    if (tail.isNotEmpty) parts.add(tail);
    return parts;
  }
}
