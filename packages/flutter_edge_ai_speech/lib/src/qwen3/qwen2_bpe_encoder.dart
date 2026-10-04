// Qwen2 byte-level BPE ENCODER (text -> token ids) for the Qwen3-TTS text
// frontend. Companion to `Gpt2ByteLevelBpeTokenizer`
// (`../tokenizer/gpt2_byte_level_bpe_tokenizer.dart`), which is DECODE-only
// for Whisper's ids -> text; `HfTokenizer`/that decoder has no encoder, so
// this is net-new. Same byte-level BPE family (GPT-2's byte<->unicode map +
// rank-ordered merges), but reproduces Qwen2's specific pre-tokenizer
// pipeline as recorded in `tokenizer.json`:
//
//   NFC normalize
//     -> split out added/special tokens atomically (longest match first)
//     -> for each remaining span, the Qwen2 pre-tokenizer `Split` regex
//        (behavior "Isolated", `add_prefix_space=false`)
//     -> ByteLevel: map each UTF-8 byte of every piece to its GPT-2
//        byte<->unicode character
//     -> BPE merge each byte-level piece (rank-ordered, from `model.merges`)
//     -> vocab lookup (`model.vocab`) for the final merged symbols.
//
// Pure Dart (`dart:convert` + `dart:io`) -- no Flutter import -- so this runs
// headless in `dart test` / `flutter test` without a device.
//
// NFC: this encoder does NOT perform explicit Unicode NFC normalization.
// Dart's core libraries have no built-in NFC implementation, and adding one
// would mean a new third-party dependency -- not done unilaterally here. In
// practice this is a pass-through: text authored in a normal editor/source
// file is already NFC, and the golden coverage (contractions, German/French
// accented Latin, CJK, whitespace runs, digits, a literal special-token
// string) all encode correctly without it. Known v1 limitation: arbitrary
// non-NFC input (e.g. combining-character sequences from some IMEs or
// pasted text) is not renormalized before encoding and may diverge from the
// reference HF tokenizer for that specific input.
library;

import 'dart:convert';
import 'dart:io';

/// Byte-level BPE encoder for the Qwen2 tokenizer family, driving the
/// Qwen3-TTS text frontend (text prompt -> token ids fed to the LLM core).
class Qwen2BpeEncoder {
  Qwen2BpeEncoder._({
    required this._vocab,
    required this._mergeRanks,
    required List<_AddedToken> addedTokens,
  }) : _addedTokenById = {for (final t in addedTokens) t.content: t.id},
       _addedTokenPattern = _buildAddedTokenPattern(addedTokens);

  final Map<String, int> _vocab;
  final Map<String, int> _mergeRanks;
  final Map<String, int> _addedTokenById;
  final RegExp? _addedTokenPattern;

  /// GPT-2's byte<->unicode map: every raw byte 0..255 -> a printable
  /// unicode code point, so arbitrary UTF-8 bytes round-trip through a BPE
  /// vocab of "characters". Ports the same table as
  /// `Gpt2ByteLevelBpeTokenizer._gpt2ByteToUnicode()` (private there, so
  /// duplicated here rather than reused across libraries); see that file's
  /// doc comment for the byte-range rationale.
  static final Map<int, int> _byteToUnicode = _buildByteToUnicode();

  static Map<int, int> _buildByteToUnicode() {
    final bytes = <int>[
      for (var b = 0x21; b <= 0x7E; b++) b,
      for (var b = 0xA1; b <= 0xAC; b++) b,
      for (var b = 0xAE; b <= 0xFF; b++) b,
    ];
    final selfMapped = bytes.toSet();
    final codepoints = <int>[...bytes];
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!selfMapped.contains(b)) {
        bytes.add(b);
        codepoints.add(256 + n);
        n++;
      }
    }
    return {for (var i = 0; i < bytes.length; i++) bytes[i]: codepoints[i]};
  }

  /// The Qwen2 pre-tokenizer's `Split` regex, taken verbatim from
  /// `tokenizer.json`'s `pre_tokenizer.pretokenizers[0].pattern.Regex`
  /// (a `Sequence` of `Split(behavior=Isolated, invert=false)` then
  /// `ByteLevel(add_prefix_space=false, use_regex=false)`). The pattern
  /// alone tiles the whole input (contractions / letter runs / lone digits
  /// / punctuation runs / newline-terminated whitespace / trailing
  /// whitespace / any other whitespace), so `allMatches` over it is
  /// equivalent to applying the `Split` step.
  ///
  /// `(?i:...)` (inline case-insensitive group) and `\p{L}`/`\p{N}` (Unicode
  /// property escapes, needing `unicode: true`) are both supported by
  /// Dart's `RegExp` as of the 3.12 SDK.
  static final RegExp _splitPattern = RegExp(
    r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+",
    unicode: true,
  );

  /// Loads an uncompressed `tokenizer.json` from disk (the form the model
  /// bundle installs at runtime).
  static Future<Qwen2BpeEncoder> fromTokenizerJson(String path) async {
    final raw = await File(path).readAsString();
    return Qwen2BpeEncoder.fromTokenizerJsonString(raw);
  }

  /// Same as [fromTokenizerJson], but from an already-in-memory JSON string
  /// (e.g. a test that gunzips the golden fixture first).
  factory Qwen2BpeEncoder.fromTokenizerJsonString(String jsonStr) {
    return Qwen2BpeEncoder.fromTokenizerJsonMap(
      jsonDecode(jsonStr) as Map<String, dynamic>,
    );
  }

  /// Same as [fromTokenizerJson], but from an already-parsed `tokenizer.json`
  /// document.
  factory Qwen2BpeEncoder.fromTokenizerJsonMap(Map<String, dynamic> doc) {
    final model = doc['model'] as Map<String, dynamic>;

    final vocabJson = model['vocab'] as Map<String, dynamic>;
    final vocab = <String, int>{
      for (final entry in vocabJson.entries) entry.key: entry.value as int,
    };

    final mergesJson = model['merges'] as List<dynamic>;
    final mergeRanks = <String, int>{};
    for (var i = 0; i < mergesJson.length; i++) {
      final entry = mergesJson[i];
      final String a;
      final String b;
      if (entry is List) {
        a = entry[0] as String;
        b = entry[1] as String;
      } else if (entry is String) {
        final sp = entry.indexOf(' ');
        if (sp < 0) {
          throw FormatException('malformed merges entry: $entry');
        }
        a = entry.substring(0, sp);
        b = entry.substring(sp + 1);
      } else {
        throw FormatException('unexpected merges entry type: $entry');
      }
      mergeRanks[_pairKey(a, b)] = i;
    }

    final addedTokensJson = doc['added_tokens'] as List<dynamic>? ?? const [];
    final addedTokens =
        [
            for (final t in addedTokensJson)
              _AddedToken(
                content: (t as Map<String, dynamic>)['content'] as String,
                id: t['id'] as int,
              ),
          ]
          // Longest-match-first: see `_buildAddedTokenPattern`.
          ..sort((x, y) => y.content.length.compareTo(x.content.length));

    return Qwen2BpeEncoder._(
      vocab: vocab,
      mergeRanks: mergeRanks,
      addedTokens: addedTokens,
    );
  }

  static String _pairKey(String a, String b) => '$a $b';

  /// Builds a single alternation over every added-token content string,
  /// longest-first, so that `allMatches` performs longest-match-at-position
  /// scanning (regex alternation picks the first alternative that matches
  /// at a given start position; since alternatives are sorted by
  /// descending length, that first success is always the longest possible
  /// added token starting there). Mirrors the HF `AddedVocabulary` trie's
  /// longest-match behavior for `added_tokens` (both `special: true` and
  /// `special: false` entries participate -- HF's fast tokenizer splits on
  /// *all* added tokens before pre-tokenization, not just the "special"
  /// subset).
  static RegExp? _buildAddedTokenPattern(List<_AddedToken> addedTokens) {
    if (addedTokens.isEmpty) return null;
    final alternatives = addedTokens
        .map((t) => RegExp.escape(t.content))
        .join('|');
    return RegExp(alternatives);
  }

  /// Encodes [text] into token ids, reproducing the HF `tokenizers`
  /// fast-tokenizer pipeline for this `tokenizer.json`.
  List<int> encode(String text) {
    final ids = <int>[];
    for (final segment in _splitOnAddedTokens(text)) {
      final addedId = segment.addedTokenId;
      if (addedId != null) {
        ids.add(addedId);
        continue;
      }
      for (final match in _splitPattern.allMatches(segment.text!)) {
        final piece = match[0]!;
        if (piece.isEmpty) continue;
        final byteLevel = _byteLevelEncode(piece);
        for (final symbol in _bpe(byteLevel)) {
          final id = _vocab[symbol];
          if (id == null) {
            throw StateError(
              'Qwen2BpeEncoder: no vocab entry for BPE symbol '
              '${symbol.runes.toList()} (from piece "$piece")',
            );
          }
          ids.add(id);
        }
      }
    }
    return ids;
  }

  List<_Segment> _splitOnAddedTokens(String text) {
    final pattern = _addedTokenPattern;
    if (pattern == null) return [_Segment.text(text)];

    final segments = <_Segment>[];
    var lastEnd = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > lastEnd) {
        segments.add(_Segment.text(text.substring(lastEnd, m.start)));
      }
      final content = m[0]!;
      segments.add(_Segment.added(_addedTokenById[content]!));
      lastEnd = m.end;
    }
    if (lastEnd < text.length) {
      segments.add(_Segment.text(text.substring(lastEnd)));
    }
    return segments;
  }

  /// UTF-8-encodes [piece] and maps each raw byte to its GPT-2
  /// byte<->unicode character, producing the byte-level string the BPE
  /// merge table and vocab operate on.
  String _byteLevelEncode(String piece) {
    final bytes = utf8.encode(piece);
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.writeCharCode(_byteToUnicode[b]!);
    }
    return buf.toString();
  }

  /// Standard byte-pair-encoding merge loop (the same algorithm as OpenAI's
  /// reference `gpt2/encoder.py` `bpe()` / HF's slow-tokenizer `bpe()`):
  /// each iteration finds the single lowest-rank pair present anywhere in
  /// the symbol list, then merges *every* non-overlapping occurrence of
  /// that exact pair in one left-to-right pass, and repeats until no known
  /// pair remains. (Naively merging only the first occurrence found per
  /// iteration -- and immediately reconsidering newly formed pairs -- can
  /// diverge from this on inputs with repeated bigrams; merging the whole
  /// pass before recomputing ranks is required for exact parity with the
  /// reference tokenizer.)
  List<String> _bpe(String word) {
    var symbols = [for (final r in word.runes) String.fromCharCode(r)];
    if (symbols.length < 2) return symbols;

    while (true) {
      int? bestRank;
      String? bestFirst;
      String? bestSecond;
      for (var i = 0; i < symbols.length - 1; i++) {
        final rank = _mergeRanks[_pairKey(symbols[i], symbols[i + 1])];
        if (rank != null && (bestRank == null || rank < bestRank)) {
          bestRank = rank;
          bestFirst = symbols[i];
          bestSecond = symbols[i + 1];
        }
      }
      if (bestFirst == null || bestSecond == null) break;
      final first = bestFirst;
      final second = bestSecond;

      final merged = <String>[];
      var i = 0;
      while (i < symbols.length) {
        if (i < symbols.length - 1 &&
            symbols[i] == first &&
            symbols[i + 1] == second) {
          merged.add(first + second);
          i += 2;
        } else {
          merged.add(symbols[i]);
          i += 1;
        }
      }
      symbols = merged;
      if (symbols.length == 1) break;
    }
    return symbols;
  }
}

class _AddedToken {
  const _AddedToken({required this.content, required this.id});
  final String content;
  final int id;
}

class _Segment {
  const _Segment.text(this.text) : addedTokenId = null;
  const _Segment.added(int id) : addedTokenId = id, text = null;

  final String? text;
  final int? addedTokenId;
}
