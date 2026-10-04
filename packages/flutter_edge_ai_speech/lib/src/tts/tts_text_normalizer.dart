library;

import 'english_text_normalizer.dart';

sealed class NormToken {
  const NormToken();
}

class WordToken extends NormToken {
  const WordToken(this.word);
  final String word;
}

class SymbolToken extends NormToken {
  const SymbolToken(this.symbol);
  final String symbol;
}

/// Language-agnostic normalizer contract. Punctuation/number/acronym POLICY is
/// per-locale, so this is a seam (like TtsTextFrontend) — English is impl #1.
abstract class TtsTextNormalizer {
  List<NormToken> normalize(String text);
  List<String> splitClauses(String text);
  static TtsTextNormalizer forLocale(String locale, Set<String> symbols) =>
      switch (locale) {
        'en_us' || 'en' => EnglishTextNormalizer(symbols),
        _ => throw UnimplementedError(
          'No TtsTextNormalizer for locale "$locale"',
        ),
      };
}
