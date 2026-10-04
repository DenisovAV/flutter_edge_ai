/// Shared loader for the Matcha-style G2P bundle files that BOTH pure-Dart
/// text frontends parse identically: `config.json` (symbol table, plus any
/// pipeline-specific keys the caller reads off the returned map) and
/// `g2p_dict.txt.gz` (gzipped tab-separated word -> IPA dictionary).
/// `MatchaTextFrontend.load` and `InflectTextFrontend.load` used to carry
/// verbatim copies of this parse — Inflect reuses Matcha's bundle wholesale
/// (see `inflect_text_frontend.dart`'s header).
library;

import 'dart:convert';
import 'dart:io';

/// One parsed G2P bundle: the raw decoded `config.json` map (so callers can
/// read extra keys like Matcha's `n_channels`/`MAX_TEXT`), the symbol -> id
/// table built from `config['symbols']` (last-wins on duplicates, matching
/// the reference Python dict comprehension), and the word -> IPA dictionary.
typedef G2pDictBundle = ({
  Map<String, dynamic> config,
  Map<String, int> symbolToId,
  Map<String, String> dictionary,
});

/// Parses `config.json` at [configPath] + the gzipped dictionary at
/// [dictPath]. Dictionary lines without a tab are skipped (verbatim from the
/// original frontends' parse).
Future<G2pDictBundle> loadG2pDictBundle(
  String configPath,
  String dictPath,
) async {
  final config =
      jsonDecode(await File(configPath).readAsString()) as Map<String, dynamic>;
  final symbols = (config['symbols'] as List).cast<String>();
  final symbolToId = <String, int>{
    // last-wins on duplicates, matches Python dict comprehension.
    for (var i = 0; i < symbols.length; i++) symbols[i]: i,
  };

  final gzBytes = await File(dictPath).readAsBytes();
  final dictText = utf8.decode(gzip.decode(gzBytes));
  final dictionary = <String, String>{};
  for (final line in const LineSplitter().convert(dictText)) {
    final tab = line.indexOf('\t');
    if (tab < 0) continue;
    dictionary[line.substring(0, tab)] = line.substring(tab + 1);
  }

  return (config: config, symbolToId: symbolToId, dictionary: dictionary);
}
