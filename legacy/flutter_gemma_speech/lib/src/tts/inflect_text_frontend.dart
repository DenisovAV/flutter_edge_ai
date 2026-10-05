/// Inflect-Nano-v2 text frontend — `text -> espeak-style IPA -> token ids`.
/// Pure Dart, no FFI (except the optional neural-G2P resolver for OOV words,
/// which the worker wires the same way Matcha does).
///
/// Inflect was trained on the SAME espeak IPA and the SAME 178-symbol Tacotron/
/// VITS table as Matcha (verified byte-identical: Matcha's `g2p_dict` gives
/// `hello -> həlˈoʊ`, exactly Inflect's espeak reference, and the two
/// `config.json` symbol lists are equal). So this frontend REUSES Matcha's G2P
/// bundle wholesale — the symbol table (`config.json`), the word->IPA dictionary
/// (`g2p_dict.txt.gz`), and the neural OOV G2P — and differs from
/// `MatchaTextFrontend` in only two ways:
///   1. Inflect's encoder takes RAW token ids (int32 `tokens`), not gathered
///      phoneme embeddings, so there is no `emb.bin` gather — a per-character
///      IPA-string -> id map (Inflect's `cleaned_text_to_sequence`, which drops
///      symbols outside the table), then the VITS blank (id 0) interspersed
///      around every id, as the reference `say.py` does. Without the blanks
///      the duration predictor sees half the sequence it was trained on and
///      the speech comes out about a third as long and unintelligible.
///   2. Inflect keeps the inter-word SPACES espeak emits (`həlˈoʊ ðˈɛɹ`), which
///      Matcha drops (its blank tokens play that role). A space precedes every
///      non-first word; punctuation ([SymbolToken]) attaches with no space.
library;

import '../model/tts_model_profile.dart';
import 'g2p_dict_bundle.dart';
import 'tts_text_frontend.dart' show NeuralG2pResolver;
import 'tts_text_normalizer.dart';

/// Pure-Dart Inflect text frontend. OOV words route through [neuralG2p] when
/// wired, else throw.
class InflectTextFrontend {
  InflectTextFrontend({
    required this.symbolToId,
    required this.dictionary,
    this.locale = 'en_us',
    this.neuralG2p,
  });

  /// IPA char -> symbol id (the 178-symbol table, shared with Matcha).
  final Map<String, int> symbolToId;

  /// Lowercase word -> IPA string (Matcha's `g2p_dict`).
  final Map<String, String> dictionary;

  /// Selects the text normalizer (number/date/punctuation policy).
  final String locale;

  /// Neural G2P fallback for OOV words (wired by the worker; null -> OOV throws).
  final NeuralG2pResolver? neuralG2p;

  late final TtsTextNormalizer _normalizer = TtsTextNormalizer.forLocale(
    locale,
    symbolToId.keys.toSet(),
  );

  /// Parse the (Matcha) bundle files this frontend reuses: `config.json`
  /// (symbol table) + `g2p_dict.txt.gz` (gzipped word -> IPA). The neural OOV
  /// G2P is injected separately via [neuralG2p].
  static Future<InflectTextFrontend> load(
    TtsModelProfile profile,
    Map<String, String> paths, {
    NeuralG2pResolver? neuralG2p,
  }) async {
    if (profile is! InflectProfile) {
      throw UnimplementedError(
        'InflectTextFrontend: only TtsPipelineKind.inflectVits profiles are '
        'supported here (Matcha has MatchaTextFrontend; Qwen3 tokenizes via '
        'Qwen3TtsCore).',
      );
    }
    final bundle = await loadG2pDictBundle(
      paths[profile.configFile]!,
      paths[profile.dictFile]!,
    );

    return InflectTextFrontend(
      symbolToId: bundle.symbolToId,
      dictionary: bundle.dictionary,
      locale: profile.locale,
      neuralG2p: neuralG2p,
    );
  }

  /// text -> Inflect phoneme-symbol token ids, blank-interspersed:
  /// `[0, id1, 0, id2, …, idN, 0]`. Symbols outside the table are dropped
  /// (matches the reference `cleaned_text_to_sequence`).
  List<int> encode(String text) {
    final tokens = _normalizer.normalize(text);
    final ipa = StringBuffer();
    // The normalizer emits inter-word spaces as SymbolToken(' ') but NOT after
    // punctuation (e.g. "there, how" -> [there] [,] [how], no space token). So
    // put exactly one space before a WORD when the buffer isn't already ended
    // by one — reproducing espeak's single-space-between-units layout. Start of
    // buffer counts as a boundary (no leading space).
    var endsWithSpace = true;
    for (final tok in tokens) {
      switch (tok) {
        case WordToken(:final word):
          if (!endsWithSpace) ipa.write(' ');
          final hit = dictionary[word];
          if (hit != null) {
            ipa.write(hit);
          } else if (neuralG2p != null) {
            ipa.write(neuralG2p!(word));
          } else {
            throw StateError(
              'InflectTextFrontend: OOV word "$word" and no neural resolver '
              'wired.',
            );
          }
          endsWithSpace = false;
        case SymbolToken(:final symbol):
          ipa.write(symbol);
          endsWithSpace = symbol == ' ';
      }
    }
    final ids = <int>[];
    for (final rune in ipa.toString().runes) {
      final id = symbolToId[String.fromCharCode(rune)];
      if (id != null) ids.add(id);
    }
    // Empty stays empty: the worker skips a clause with nothing to say.
    if (ids.isEmpty) return ids;
    final interspersed = List<int>.filled(2 * ids.length + 1, 0);
    for (var i = 0; i < ids.length; i++) {
      interspersed[2 * i + 1] = ids[i];
    }
    return interspersed;
  }
}
