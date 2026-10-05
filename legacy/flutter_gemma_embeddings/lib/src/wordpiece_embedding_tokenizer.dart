// [EmbeddingTokenizer] adapter for BERT-style **WordPiece** models loaded
// from a HuggingFace `tokenizer.json` file (e.g. `all-MiniLM-L6-v2`).
//
// Ported verbatim (tokenization algorithm unchanged) from the ONNX-family
// spike's `flutter_gemma_onnx_embeddings/lib/src/wordpiece_tokenizer_adapter.dart`
// and re-shaped to this seam's [EmbeddingTokenizer] interface. It lives in
// `flutter_gemma_embeddings` — not in `flutter_gemma_onnx` — because
// WordPiece-vs-SentencePiece is model-family logic, not engine logic (design
// D-T1): a hypothetical WordPiece `.tflite` would need this same tokenizer
// under LiteRT, and EmbeddingGemma is SentencePiece on *both* LiteRT and
// ONNX.
//
// The existing [EmbeddingTokenizer] SentencePiece adapter
// (`embedding_tokenizer.dart`) targets Unigram/BPE via
// `dart_sentencepiece_tokenizer`, which cannot parse a WordPiece
// `tokenizer.json` (it expects a custom `pieces/scores/types`
// serialization). MiniLM-family embedding models ship a standard BERT
// WordPiece vocab, so this adapter re-implements the deterministic BERT
// tokenization pipeline:
//
//   1. **Normalize** (`BertNormalizer`): clean control chars, optionally fold
//      CJK with surrounding spaces, optionally strip accents, optionally
//      lowercase. Defaults match the canonical uncased BERT config.
//   2. **Pre-tokenize** (`BertPreTokenizer`): split on whitespace and isolate
//      every punctuation character into its own token.
//   3. **WordPiece**: greedy longest-match-first subword splitting using the
//      `##` continuation prefix; unknown words collapse to `[UNK]`.
//   4. **Post-process**: prepend `[CLS]` and append `[SEP]`, matching the
//      `TemplateProcessing` post-processor in `tokenizer.json`.
//
// This reproduces the reference `tokenizers` library output exactly for the
// ASCII/Latin text used by the embedding test suite.
//
// The private constructor deliberately maps named params onto distinctly
// named private fields (the public factory names read better than
// `_vocab:` etc.), so initializing formals don't apply here.
// ignore_for_file: prefer_initializing_formals
//
// Deliberately NO `dart:io` import: this file is web-safe (imported directly
// by `flutter_gemma_onnx`'s web embedding arm), and an unconditional
// `import 'dart:io'` makes a whole library uncompilable for web. [fromPath]
// still needs to read a file, so it goes through the `readTextFile` seam below
// — the same `if (dart.library.…)` technique the ONNX web PR used for its own
// barrel split.
//
// #449 solved the same problem by DELETING `fromPath`, which silently removed a
// method that had already shipped in published 2.0.0 two days earlier. The seam
// is what that deletion should have been.

import 'dart:convert';

import 'io/read_text_file_stub.dart'
    if (dart.library.io) 'io/read_text_file_io.dart';

import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart';

/// [EmbeddingTokenizer] for BERT-style WordPiece models. `encode(prefix,
/// text)` tokenizes `prefix + text` (matching the SentencePiece adapter's
/// convention) as `[CLS] + wordpiece(prefix+text) + [SEP]`, with an
/// all-ones [TokenizedInput.attentionMask] and all-zeros
/// [TokenizedInput.tokenTypeIds] (single-segment input).
class WordPieceEmbeddingTokenizer implements EmbeddingTokenizer {
  WordPieceEmbeddingTokenizer._({
    required Map<String, int> vocab,
    required this.clsId,
    required this.sepId,
    required this.unkId,
    required String continuingSubwordPrefix,
    required int maxInputCharsPerWord,
    required bool lowercase,
    required bool stripAccents,
    required bool handleChineseChars,
    required bool cleanText,
  }) : _vocab = vocab,
       _continuingSubwordPrefix = continuingSubwordPrefix,
       _maxInputCharsPerWord = maxInputCharsPerWord,
       _lowercase = lowercase,
       _stripAccents = stripAccents,
       _handleChineseChars = handleChineseChars,
       _cleanText = cleanText;

  final Map<String, int> _vocab;
  final String _continuingSubwordPrefix;
  final int _maxInputCharsPerWord;
  final bool _lowercase;
  final bool _stripAccents;
  final bool _handleChineseChars;
  final bool _cleanText;

  /// `[CLS]` special-token id (BERT convention: 101).
  final int clsId;

  /// `[SEP]` special-token id (BERT convention: 102).
  final int sepId;

  /// `[UNK]` special-token id (BERT convention: 100).
  final int unkId;

  /// Returns true when [json] (a decoded `tokenizer.json` map) describes a
  /// WordPiece model. Used by the ONNX backend's tokenizer loader to route
  /// between SentencePiece and WordPiece without a file-extension heuristic.
  static bool isWordPieceJson(Map<String, dynamic> json) {
    final model = json['model'];
    return model is Map && model['type'] == 'WordPiece';
  }

  /// Load a WordPiece tokenizer from a HuggingFace `tokenizer.json` at [path].
  ///
  /// [path] must be an ABSOLUTE filesystem path — not a Flutter asset key
  /// (`File` knows nothing about `AssetBundle`) and not a bundle-relative name.
  /// Under the macOS/iOS App Sandbox a path outside the app container needs an
  /// active security-scoped bookmark, or the read fails with a permission error
  /// for a file the user can see in Finder.
  ///
  /// Native only — on web this throws [UnsupportedError], because a browser has
  /// no on-disk path to read. Fetch the file yourself there and use
  /// [fromJsonString].
  static Future<WordPieceEmbeddingTokenizer> fromPath(String path) async =>
      fromJsonString(await readTextFile(path));

  /// Parse a WordPiece tokenizer from the raw `tokenizer.json` [content].
  static WordPieceEmbeddingTokenizer fromJsonString(String content) {
    final json = jsonDecode(content) as Map<String, dynamic>;
    final model = json['model'] as Map<String, dynamic>?;
    if (model == null || model['type'] != 'WordPiece') {
      throw FormatException(
        'tokenizer.json is not a WordPiece model '
        '(model.type=${model?['type']}); use the Gemma SentencePiece adapter.',
      );
    }

    final rawVocab = model['vocab'] as Map<String, dynamic>;
    final vocab = <String, int>{
      for (final entry in rawVocab.entries) entry.key: entry.value as int,
    };

    final unkToken = (model['unk_token'] as String?) ?? '[UNK]';
    final continuingSubwordPrefix =
        (model['continuing_subword_prefix'] as String?) ?? '##';
    final maxInputCharsPerWord =
        (model['max_input_chars_per_word'] as int?) ?? 100;

    // Normalizer flags (BertNormalizer). HuggingFace uses `strip_accents: null`
    // to mean "follow lowercase", so a null value resolves to [lowercase].
    final normalizer = json['normalizer'] as Map<String, dynamic>?;
    final lowercase = (normalizer?['lowercase'] as bool?) ?? true;
    final stripAccentsRaw = normalizer?['strip_accents'];
    final stripAccents = stripAccentsRaw is bool ? stripAccentsRaw : lowercase;
    final handleChineseChars =
        (normalizer?['handle_chinese_chars'] as bool?) ?? true;
    final cleanText = (normalizer?['clean_text'] as bool?) ?? true;

    // Special-token ids come from the post-processor's TemplateProcessing block
    // when present; otherwise fall back to the canonical BERT ids.
    int specialId(String token, int fallback) => vocab[token] ?? fallback;
    final clsId = specialId('[CLS]', 101);
    final sepId = specialId('[SEP]', 102);
    final unkId = specialId(unkToken, 100);

    return WordPieceEmbeddingTokenizer._(
      vocab: vocab,
      clsId: clsId,
      sepId: sepId,
      unkId: unkId,
      continuingSubwordPrefix: continuingSubwordPrefix,
      maxInputCharsPerWord: maxInputCharsPerWord,
      lowercase: lowercase,
      stripAccents: stripAccents,
      handleChineseChars: handleChineseChars,
      cleanText: cleanText,
    );
  }

  @override
  TokenizedInput encode(String prefix, String text) {
    final normalized = _normalize(prefix + text);
    final words = _preTokenize(normalized);

    final ids = <int>[clsId];
    for (final word in words) {
      ids.addAll(_wordPieceEncode(word));
    }
    ids.add(sepId);
    return TokenizedInput(
      ids: ids,
      attentionMask: List<int>.filled(ids.length, 1),
      tokenTypeIds: List<int>.filled(ids.length, 0),
    );
  }

  // ---------------------------------------------------------------------------
  // 1. BertNormalizer
  // ---------------------------------------------------------------------------

  String _normalize(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      // clean_text: drop NUL/replacement-char and control chars; fold all
      // whitespace to a single space.
      if (_cleanText) {
        if (rune == 0 || rune == 0xFFFD || _isControl(rune)) {
          continue;
        }
        if (_isWhitespace(rune)) {
          buffer.writeCharCode(0x20);
          continue;
        }
      }
      // handle_chinese_chars: surround every CJK char with spaces so each
      // becomes its own pre-token.
      if (_handleChineseChars && _isChineseChar(rune)) {
        buffer.writeCharCode(0x20);
        buffer.writeCharCode(rune);
        buffer.writeCharCode(0x20);
        continue;
      }
      buffer.writeCharCode(rune);
    }

    var result = buffer.toString();
    if (_lowercase) {
      result = result.toLowerCase();
    }
    if (_stripAccents) {
      result = _stripAccentMarks(result);
    }
    return result;
  }

  /// Strip accents by mapping precomposed Latin accented code points to their
  /// base letter — equivalent to NFD-decompose then dropping combining marks
  /// (HuggingFace `strip_accents`) for the Latin-1 / Latin-Extended-A ranges.
  /// Any already-combining mark (category Mn) is dropped outright so input that
  /// is already NFD-decomposed folds correctly too.
  static String _stripAccentMarks(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if (_isCombiningMark(rune)) continue;
      final base = _latinAccentFold[rune];
      buffer.writeCharCode(base ?? rune);
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------------------
  // 2. BertPreTokenizer — whitespace split + punctuation isolation
  // ---------------------------------------------------------------------------

  List<String> _preTokenize(String text) {
    final tokens = <String>[];
    final current = StringBuffer();

    void flush() {
      if (current.isNotEmpty) {
        tokens.add(current.toString());
        current.clear();
      }
    }

    for (final rune in text.runes) {
      if (_isWhitespace(rune)) {
        flush();
      } else if (_isPunctuation(rune)) {
        flush();
        tokens.add(String.fromCharCode(rune));
      } else {
        current.writeCharCode(rune);
      }
    }
    flush();
    return tokens;
  }

  // ---------------------------------------------------------------------------
  // 3. WordPiece greedy longest-match-first
  // ---------------------------------------------------------------------------

  List<int> _wordPieceEncode(String word) {
    final chars = word.runes.toList();
    if (chars.length > _maxInputCharsPerWord) {
      return [unkId];
    }

    final subTokenIds = <int>[];
    var start = 0;
    while (start < chars.length) {
      var end = chars.length;
      int? curId;
      while (start < end) {
        var substr = String.fromCharCodes(chars.sublist(start, end));
        if (start > 0) {
          substr = '$_continuingSubwordPrefix$substr';
        }
        final id = _vocab[substr];
        if (id != null) {
          curId = id;
          break;
        }
        end -= 1;
      }
      if (curId == null) {
        // Any unmatchable piece makes the entire word unknown.
        return [unkId];
      }
      subTokenIds.add(curId);
      start = end;
    }
    return subTokenIds;
  }

  // ---------------------------------------------------------------------------
  // Character-class helpers (mirror BERT's `_is_*` predicates).
  // ---------------------------------------------------------------------------

  static bool _isWhitespace(int c) {
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) return true;
    // Unicode space separator (Zs) — approximated by the common code points.
    return c == 0xA0 ||
        c == 0x1680 ||
        (c >= 0x2000 && c <= 0x200A) ||
        c == 0x202F ||
        c == 0x205F ||
        c == 0x3000;
  }

  static bool _isControl(int c) {
    // Tab/newline/CR are treated as whitespace, not control.
    if (c == 0x09 || c == 0x0A || c == 0x0D) return false;
    if (c < 0x20 || c == 0x7F) return true;
    // C1 controls.
    return c >= 0x80 && c <= 0x9F;
  }

  /// Punctuation per BERT: all ASCII non-alphanumeric printable chars plus any
  /// Unicode code point in a punctuation block (P*). We approximate the Unicode
  /// side with the common punctuation ranges; the ASCII rule covers the
  /// test-relevant characters exactly.
  static bool _isPunctuation(int c) {
    if ((c >= 0x21 && c <= 0x2F) ||
        (c >= 0x3A && c <= 0x40) ||
        (c >= 0x5B && c <= 0x60) ||
        (c >= 0x7B && c <= 0x7E)) {
      return true;
    }
    // General Unicode punctuation blocks.
    return (c >= 0x2000 && c <= 0x206F) ||
        (c >= 0x3000 && c <= 0x303F) ||
        (c >= 0xFF00 && c <= 0xFFEF && _isPunctuationFullwidth(c));
  }

  static bool _isPunctuationFullwidth(int c) {
    // Fullwidth ASCII punctuation mirrors the ASCII ranges shifted by 0xFEE0.
    final ascii = c - 0xFEE0;
    return (ascii >= 0x21 && ascii <= 0x2F) ||
        (ascii >= 0x3A && ascii <= 0x40) ||
        (ascii >= 0x5B && ascii <= 0x60) ||
        (ascii >= 0x7B && ascii <= 0x7E);
  }

  static bool _isChineseChar(int c) {
    return (c >= 0x4E00 && c <= 0x9FFF) ||
        (c >= 0x3400 && c <= 0x4DBF) ||
        (c >= 0x20000 && c <= 0x2A6DF) ||
        (c >= 0x2A700 && c <= 0x2B73F) ||
        (c >= 0x2B740 && c <= 0x2B81F) ||
        (c >= 0x2B820 && c <= 0x2CEAF) ||
        (c >= 0xF900 && c <= 0xFAFF) ||
        (c >= 0x2F800 && c <= 0x2FA1F);
  }

  /// Unicode combining-mark ranges (category Mn) covering the Latin accents
  /// produced by NFD decomposition. Sufficient for Latin-script accent folding.
  static bool _isCombiningMark(int c) {
    return (c >= 0x0300 && c <= 0x036F) || // Combining Diacritical Marks
        (c >= 0x1AB0 && c <= 0x1AFF) ||
        (c >= 0x1DC0 && c <= 0x1DFF) ||
        (c >= 0x20D0 && c <= 0x20FF) ||
        (c >= 0xFE20 && c <= 0xFE2F);
  }

  /// Precomposed Latin accented code points → base ASCII letter. Covers the
  /// Latin-1 Supplement and Latin Extended-A blocks (NFD base after dropping
  /// combining marks). Generated to mirror HuggingFace `strip_accents`.
  static const Map<int, int> _latinAccentFold = {
    0x00C0: 0x41,
    0x00C1: 0x41,
    0x00C2: 0x41,
    0x00C3: 0x41,
    0x00C4: 0x41,
    0x00C5: 0x41,
    0x00C7: 0x43,
    0x00C8: 0x45,
    0x00C9: 0x45,
    0x00CA: 0x45,
    0x00CB: 0x45,
    0x00CC: 0x49,
    0x00CD: 0x49,
    0x00CE: 0x49,
    0x00CF: 0x49,
    0x00D1: 0x4E,
    0x00D2: 0x4F,
    0x00D3: 0x4F,
    0x00D4: 0x4F,
    0x00D5: 0x4F,
    0x00D6: 0x4F,
    0x00D9: 0x55,
    0x00DA: 0x55,
    0x00DB: 0x55,
    0x00DC: 0x55,
    0x00DD: 0x59,
    0x00E0: 0x61,
    0x00E1: 0x61,
    0x00E2: 0x61,
    0x00E3: 0x61,
    0x00E4: 0x61,
    0x00E5: 0x61,
    0x00E7: 0x63,
    0x00E8: 0x65,
    0x00E9: 0x65,
    0x00EA: 0x65,
    0x00EB: 0x65,
    0x00EC: 0x69,
    0x00ED: 0x69,
    0x00EE: 0x69,
    0x00EF: 0x69,
    0x00F1: 0x6E,
    0x00F2: 0x6F,
    0x00F3: 0x6F,
    0x00F4: 0x6F,
    0x00F5: 0x6F,
    0x00F6: 0x6F,
    0x00F9: 0x75,
    0x00FA: 0x75,
    0x00FB: 0x75,
    0x00FC: 0x75,
    0x00FD: 0x79,
    0x00FF: 0x79,
    0x0100: 0x41,
    0x0101: 0x61,
    0x0102: 0x41,
    0x0103: 0x61,
    0x0104: 0x41,
    0x0105: 0x61,
    0x0106: 0x43,
    0x0107: 0x63,
    0x0108: 0x43,
    0x0109: 0x63,
    0x010A: 0x43,
    0x010B: 0x63,
    0x010C: 0x43,
    0x010D: 0x63,
    0x010E: 0x44,
    0x010F: 0x64,
    0x0112: 0x45,
    0x0113: 0x65,
    0x0114: 0x45,
    0x0115: 0x65,
    0x0116: 0x45,
    0x0117: 0x65,
    0x0118: 0x45,
    0x0119: 0x65,
    0x011A: 0x45,
    0x011B: 0x65,
    0x011C: 0x47,
    0x011D: 0x67,
    0x011E: 0x47,
    0x011F: 0x67,
    0x0120: 0x47,
    0x0121: 0x67,
    0x0122: 0x47,
    0x0123: 0x67,
    0x0124: 0x48,
    0x0125: 0x68,
    0x0128: 0x49,
    0x0129: 0x69,
    0x012A: 0x49,
    0x012B: 0x69,
    0x012C: 0x49,
    0x012D: 0x69,
    0x012E: 0x49,
    0x012F: 0x69,
    0x0130: 0x49,
    0x0134: 0x4A,
    0x0135: 0x6A,
    0x0136: 0x4B,
    0x0137: 0x6B,
    0x0139: 0x4C,
    0x013A: 0x6C,
    0x013B: 0x4C,
    0x013C: 0x6C,
    0x013D: 0x4C,
    0x013E: 0x6C,
    0x0143: 0x4E,
    0x0144: 0x6E,
    0x0145: 0x4E,
    0x0146: 0x6E,
    0x0147: 0x4E,
    0x0148: 0x6E,
    0x014C: 0x4F,
    0x014D: 0x6F,
    0x014E: 0x4F,
    0x014F: 0x6F,
    0x0150: 0x4F,
    0x0151: 0x6F,
    0x0154: 0x52,
    0x0155: 0x72,
    0x0156: 0x52,
    0x0157: 0x72,
    0x0158: 0x52,
    0x0159: 0x72,
    0x015A: 0x53,
    0x015B: 0x73,
    0x015C: 0x53,
    0x015D: 0x73,
    0x015E: 0x53,
    0x015F: 0x73,
    0x0160: 0x53,
    0x0161: 0x73,
    0x0162: 0x54,
    0x0163: 0x74,
    0x0164: 0x54,
    0x0165: 0x74,
    0x0168: 0x55,
    0x0169: 0x75,
    0x016A: 0x55,
    0x016B: 0x75,
    0x016C: 0x55,
    0x016D: 0x75,
    0x016E: 0x55,
    0x016F: 0x75,
    0x0170: 0x55,
    0x0171: 0x75,
    0x0172: 0x55,
    0x0173: 0x75,
    0x0174: 0x57,
    0x0175: 0x77,
    0x0176: 0x59,
    0x0177: 0x79,
    0x0178: 0x59,
    0x0179: 0x5A,
    0x017A: 0x7A,
    0x017B: 0x5A,
    0x017C: 0x7A,
    0x017D: 0x5A,
    0x017E: 0x7A,
  };
}
