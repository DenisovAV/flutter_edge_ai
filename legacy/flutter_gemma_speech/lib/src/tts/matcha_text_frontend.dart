/// Matcha-TTS text frontend — `text -> IPA (dictionary G2P) -> symbol ids ->
/// blank-interspersed ids + text mask -> host-side emb.bin gather -> symbol
/// embeddings`. Pure Dart, no FFI. The analog of STT's `HfTokenizer`: this is
/// the input `TtsCore` (Task 2.3) feeds to the Matcha text-encoder graph.
///
/// The algorithm is transcribed verbatim from the verified reconstruction
/// script `matcha_synth.dart` (`main()`, config/dict/emb parsing + G2P +
/// blank-intersperse + gather).
library;

import 'dart:io';
import 'dart:typed_data';

import '../model/tts_model_profile.dart';
import 'g2p_dict_bundle.dart';
import 'tts_frontend_input.dart';
import 'tts_text_frontend.dart';
import 'tts_text_normalizer.dart';

/// Pure-Dart Matcha-TTS text frontend: text normalizer (tagged tokens) +
/// dictionary G2P + optional neural fallback + blank-intersperse +
/// host-side embedding gather. OOV words throw when no neural resolver is
/// wired.
class MatchaTextFrontend implements TtsTextFrontend {
  /// Pure constructor from already-parsed data (unit-testable, no file I/O).
  MatchaTextFrontend({
    required this.symbolToId,
    required this.dictionary,
    required this.embeddingTable,
    required this.nChannels,
    required this.maxText,
    this.locale = 'en_us',
    this.neuralG2p,
  });

  /// IPA char -> symbol id (178-symbol table for the real Matcha bundle).
  final Map<String, int> symbolToId;

  /// Lowercase word -> IPA string (274,927 entries for the real bundle).
  final Map<String, String> dictionary;

  /// [nSymbols * nChannels] row-major phoneme embedding table.
  final Float32List embeddingTable;

  /// Embedding width (192 for the real Matcha bundle).
  final int nChannels;

  /// Max text length in symbol slots (256 for the real Matcha bundle).
  final int maxText;

  /// Selects the normalizer for this frontend (Task 9); matcha -> `'en_us'`.
  final String locale;

  /// Neural G2P fallback for OOV words (Task 11 wires this in via the
  /// worker); null until then, so OOV words still throw.
  final NeuralG2pResolver? neuralG2p;

  /// Normalizer for [locale]/[symbolToId], built once at construction —
  /// [locale] and [symbolToId] are fixed for the lifetime of the frontend,
  /// so rebuilding a ~178-element symbol set on every [encode] call (once
  /// per clause per request) is wasted work.
  late final TtsTextNormalizer _normalizer = TtsTextNormalizer.forLocale(
    locale,
    symbolToId.keys.toSet(),
  );

  /// Parse the real Matcha bundle files: `config.json` (symbols +
  /// n_channels + MAX_TEXT), `g2p_dict.txt.gz` (gzipped word -> IPA
  /// dictionary), `emb.bin` (little-endian f32 phoneme embedding table).
  static Future<MatchaTextFrontend> load(
    MatchaProfile profile,
    Map<String, String> paths, {
    NeuralG2pResolver? neuralG2p,
  }) async {
    final configPath = paths[profile.configFile]!;
    final dictPath = paths[profile.dictFile]!;
    final embeddingPath = paths[profile.embeddingFile]!;

    final bundle = await loadG2pDictBundle(configPath, dictPath);
    final nChannels = (bundle.config['n_channels'] as num).toInt();
    final maxText = (bundle.config['MAX_TEXT'] as num).toInt();

    final embBytes = await File(embeddingPath).readAsBytes();
    final embBd = ByteData.sublistView(embBytes);
    final embeddingTable = Float32List(embBytes.length ~/ 4);
    for (var i = 0; i < embeddingTable.length; i++) {
      embeddingTable[i] = embBd.getFloat32(i * 4, Endian.little);
    }

    return MatchaTextFrontend(
      symbolToId: bundle.symbolToId,
      dictionary: bundle.dictionary,
      embeddingTable: embeddingTable,
      nChannels: nChannels,
      maxText: maxText,
      locale: profile.locale,
      neuralG2p: neuralG2p,
    );
  }

  /// IPA symbol-ids for ONE normalized token (empty for a non-speech token).
  /// [text] is the whole chunk/clause [tok] came from — kept only to name it
  /// in the unmapped-IPA-symbol error below.
  List<int> _tokenPids(Object tok, String text) {
    final ipa = StringBuffer();
    if (tok is SymbolToken) {
      ipa.write(tok.symbol);
    } else if (tok is WordToken) {
      final hit = dictionary[tok.word];
      if (hit != null) {
        ipa.write(hit);
      } else if (neuralG2p != null) {
        ipa.write(neuralG2p!(tok.word));
      } else {
        throw StateError(
          'MatchaTextFrontend: OOV word "${tok.word}" and no neural '
          'resolver wired.',
        );
      }
    }
    final pids = <int>[];
    for (final rune in ipa.toString().runes) {
      final ch = String.fromCharCode(rune);
      final id = symbolToId[ch];
      if (id != null) {
        pids.add(id);
      } else {
        throw StateError(
          'MatchaTextFrontend: IPA symbol "$ch" (U+${rune.toRadixString(16)}) '
          'is not in the 178-symbol table — cannot synthesize "$text".',
        );
      }
    }
    return pids;
  }

  /// Build the padded/masked/gathered input from a fitting [pids] list.
  /// Caller guarantees `2*pids.length+1 <= maxText`. Empty pids -> empty input.
  MatchaFrontendInput _buildInput(List<int> pids) {
    if (pids.isEmpty) {
      return MatchaFrontendInput(Float32List(0), Float32List(0), 0);
    }
    final realLen = 2 * pids.length + 1;
    final ids = List<int>.filled(maxText, 0);
    for (var i = 0; i < pids.length; i++) {
      ids[1 + 2 * i] = pids[i];
    }
    final textMask = Float32List(maxText);
    for (var t = 0; t < maxText; t++) {
      textMask[t] = t < realLen ? 1.0 : 0.0;
    }
    final symbolEmbeddings = Float32List(maxText * nChannels);
    for (var t = 0; t < maxText; t++) {
      final srcBase = ids[t] * nChannels;
      final dstBase = t * nChannels;
      for (var c = 0; c < nChannels; c++) {
        symbolEmbeddings[dstBase + c] = embeddingTable[srcBase + c];
      }
    }
    return MatchaFrontendInput(symbolEmbeddings, textMask, realLen);
  }

  /// text -> frontend input. G2P is dictionary-first: OOV words route
  /// through [neuralG2p] when wired, else throw [StateError].
  @override
  MatchaFrontendInput encode(String text) {
    final tokens = _normalizer.normalize(text);
    final pids = <int>[];
    for (final tok in tokens) {
      pids.addAll(_tokenPids(tok, text));
    }
    if (pids.isEmpty) {
      // Non-speech clause (e.g. a lone emoji or a symbol outside the
      // model's table): a defined empty input, not a fail-loud error — the
      // worker's `realLen <= 1` guard skips it and moves on to the next
      // clause instead of erroring the whole synthesis request.
      return MatchaFrontendInput(Float32List(0), Float32List(0), 0);
    }
    final realLen = 2 * pids.length + 1;
    if (realLen > maxText) {
      throw StateError(
        'MatchaTextFrontend: chunk needs $realLen slots > MAX_TEXT $maxText '
        '(chunk before encode). Text: "$text".',
      );
    }
    return _buildInput(pids);
  }

  /// text -> one or more inputs, each within MAX_TEXT. Splits an over-long
  /// chunk at WORD boundaries (never mid-word — that would break G2P). For
  /// text that already fits, returns a single input equal to [encode]
  /// (golden-safe). A single token whose phonemes alone exceed the budget is
  /// unsplittable and still fails loud (a >127-phoneme word is a genuine
  /// limit, not silent loss).
  @override
  List<MatchaFrontendInput> encodeChunks(String text) {
    final tokens = _normalizer.normalize(text);
    final maxPids = (maxText - 1) ~/ 2; // 127 for maxText = 256
    final result = <MatchaFrontendInput>[];
    final current = <int>[];
    for (final tok in tokens) {
      final tokPids = _tokenPids(tok, text);
      if (tokPids.isEmpty) continue; // non-speech token
      if (tokPids.length > maxPids) {
        throw StateError(
          'MatchaTextFrontend: a single token needs '
          '${2 * tokPids.length + 1} slots > MAX_TEXT $maxText and cannot be '
          'split at a word boundary. Text: "$text".',
        );
      }
      if (current.length + tokPids.length > maxPids) {
        result.add(_buildInput(List.of(current)));
        current.clear();
      }
      current.addAll(tokPids);
    }
    if (current.isNotEmpty) result.add(_buildInput(List.of(current)));
    if (result.isEmpty) {
      // all-non-speech chunk -> one empty input (worker skips via realLen<=1).
      return [MatchaFrontendInput(Float32List(0), Float32List(0), 0)];
    }
    return result;
  }
}
