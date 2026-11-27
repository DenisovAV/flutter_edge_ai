// Copyright 2026 The ODML Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Modified: ported from C++ (LiteRT-LM v0.19.1,
// omni/speech2text/detokenizer.h and
// omni/speech2text/tokenizer_detokenizer.{h,cc}) to Dart for
// flutter_edge_ai_speech.

/// Turns the tokens a speech recognizer decoded for one audio window into
/// words with onset timestamps.
///
/// Text is handled as UTF-8 bytes up to the point where a word is complete,
/// as in the C++ original: a byte-level BPE token may hold only part of a
/// multi-byte character, so the tokenizer seam ([TokenIdsToUtf8]) returns
/// bytes, not a `String`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'text_utils.dart';

/// One token of a recognizer's output (Omni's
/// `SpeechRecognizer::DecodedToken`).
final class DecodedToken {
  const DecodedToken(
    this.tokenId, {
    this.timestampMs,
    this.isWarmStart = false,
  });

  /// The end-of-chunk sentinel: closes a window's tokens, optionally carrying
  /// the window's end time and the warm-start flag.
  const DecodedToken.endOfChunk({this.timestampMs, this.isWarmStart = false})
    : tokenId = endOfChunkTokenId;

  /// The token id of the end-of-chunk sentinel.
  static const int endOfChunkTokenId = -1;

  final int tokenId;

  /// Emission time relative to the start of the window, in the decoder's
  /// timestamp unit (the name is Omni's: for this package's CTC decoder it
  /// is encoder frames, not milliseconds); null when the decoder reports
  /// none.
  final int? timestampMs;

  /// True on the end-of-chunk sentinel of a progressive warm-start prefix
  /// emitted before the first full model window.
  final bool isWarmStart;

  bool get isEndOfChunk => tokenId == endOfChunkTokenId;

  @override
  String toString() => '$tokenId(${timestampMs ?? -1})';
}

/// A decoded word and its optional timestamp (Omni's `Detokenizer::Word`).
final class DetokenizedWord {
  const DetokenizedWord(
    this.text, {
    this.timestampMs,
    this.isWarmStart = false,
  });

  /// The end-of-chunk sentinel word.
  const DetokenizedWord.endOfChunk({this.timestampMs, this.isWarmStart = false})
    : text = '';

  /// The word; empty on the end-of-chunk sentinel.
  final String text;

  /// Onset relative to the start of the window, in the decoder's timestamp
  /// unit (encoder frames for this package's CTC decoder; on the sentinel:
  /// the end of the window).
  final int? timestampMs;

  /// True on the end-of-chunk sentinel word when this chunk is a progressive
  /// warm-start prefix emitted before the first full model window.
  final bool isWarmStart;

  /// An empty text indicates an end-of-chunk word.
  bool get isEndOfChunk => text.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is DetokenizedWord &&
      other.text == text &&
      other.timestampMs == timestampMs &&
      other.isWarmStart == isWarmStart;

  @override
  int get hashCode => Object.hash(text, timestampMs, isWarmStart);

  @override
  String toString() => '$text(${timestampMs ?? -1})';
}

/// Decodes [tokenIds] to UTF-8 bytes (Omni's `Tokenizer::TokenIdsToText`).
///
/// Throw an [ArgumentError] when [skipSpecialTokens] `true` is not supported:
/// the detokenizer then decodes again with `false`, as Omni does on an
/// `InvalidArgumentError` (its SentencePiece tokenizer refuses `true`). Any
/// other failure of the full-window decode propagates.
typedef TokenIdsToUtf8 =
    List<int> Function(List<int> tokenIds, {required bool skipSpecialTokens});

/// Converts recognizer tokens into words using a tokenizer's decode function
/// (Omni's `TokenizerDetokenizer`).
///
/// Words are split on spaces of the decoded text, and every CJK character is
/// a word of its own. When tokens carry timestamps, each word gets the
/// timestamp of the token where it starts; that token is found from how each
/// token renders when it is not the first token of a sequence (see
/// [TokenizerDetokenizer.decodedTokenPiece]), which keeps the leading space
/// SentencePiece ('▁') and byte-level BPE ('Ġ') strip from the first token.
final class TokenizerDetokenizer {
  TokenizerDetokenizer(this._tokenIdsToUtf8);

  final TokenIdsToUtf8 _tokenIdsToUtf8;

  // Caches each token id's non-initial decoded rendering
  // (`d3.sublist(d2.length)` from decoding `[id, id]` and `[id, id, id]`),
  // preserving the leading space that SentencePiece (`▁`) and HuggingFace
  // Metaspace (`Ġ`) strip from the first token of a decoded sequence. Keyed by
  // `(tokenId, skipSpecialTokens)`; bounded by the number of distinct token
  // ids seen across the session. Omni does not clear it on reset either.
  final Map<(int, bool), Uint8List> _tokenPieceCache = {};

  /// The cached non-initial decoded piece for [tokenId], or null when it
  /// cannot be derived (Omni logs and skips that token).
  Uint8List? decodedTokenPiece(int tokenId, {required bool skipSpecialTokens}) {
    final cacheKey = (tokenId, skipSpecialTokens);
    final cached = _tokenPieceCache[cacheKey];
    if (cached != null) return cached;
    // Derive how `tokenId` renders when it is not the first piece of a
    // sequence by comparing `[id, id, id]` against `[id, id]`.
    // SentencePiece (`▁`) and HuggingFace Metaspace (`Ġ`) strip the leading
    // space from index 0 of a decoded sequence:
    //   - For token "▁un": d2 = "un un", d3 = "un un un" -> caches " un"
    //   - For token "for": d2 = "forfor", d3 = "forforfor" -> caches "for"
    // Comparing `[id, id, id]` against `[id, id]` also avoids decoding a
    // single token (SentencePiece returns the raw piece string for a lone
    // control token) and identical bytes never merge into one UTF-8 code
    // point, making it byte-safe and independent of the surrounding token
    // stream.
    // Omni's GetDecodedTokenPiece returns the tokenizer's error status and
    // its caller skips the token. Here a tokenizer that throws is a bug, not
    // a status: it propagates and fails the window, instead of moving a
    // word's timestamp to the wrong token without a word.
    final d2 = _tokenIdsToUtf8([
      tokenId,
      tokenId,
    ], skipSpecialTokens: skipSpecialTokens);
    final d3 = _tokenIdsToUtf8([
      tokenId,
      tokenId,
      tokenId,
    ], skipSpecialTokens: skipSpecialTokens);
    if (d3.length < d2.length) return null;
    for (var i = 0; i < d2.length; ++i) {
      // "Decoded token triple does not start with decoded token pair."
      if (d3[i] != d2[i]) return null;
    }
    final piece = Uint8List.fromList(d3.sublist(d2.length));
    _tokenPieceCache[cacheKey] = piece;
    return piece;
  }

  // Maps each word in [0, numWords) to the index of its starting token in
  // `tokenIds` in O(N) time using cached non-initial token pieces, or returns
  // null if word-onset mapping cannot be computed.
  List<int>? _mapWordsToOnsetTokenIndices(
    List<int> tokenIds,
    int numWords, {
    required bool skipSpecialTokens,
  }) {
    final numTokens = tokenIds.length;
    if (numWords == 0 || numTokens <= 1) {
      return null;
    }

    // Subword tokenizers emit variable numbers of tokens per word, so linear
    // index interpolation (`round(i * (numTokens - 1) / (numWords - 1))`)
    // shifts word timestamps away from their acoustic onset and breaks
    // overlap alignment in `TimestampTextMerger`.
    //
    // Example: suppose a 5s chunk (frames 0..62, where the 1s overlap with the
    // next chunk starts at frame 50) contains "unfortunately it is open"
    // (numWords = 4, numTokens = 8):
    //   k=0: " un"   (t=10) -> word 0 ("unfortunately") onset
    //   k=1: "for"   (t=14)
    //   k=2: "tu"    (t=18)
    //   k=3: "nate"  (t=22)
    //   k=4: "ly"    (t=26)
    //   k=5: " it"   (t=48) -> word 1 ("it") onset
    //   k=6: " is"   (t=52) -> word 2 ("is") onset (inside overlap >= 50)
    //   k=7: " open" (t=56) -> word 3 ("open") onset (inside overlap >= 50)
    //
    // Without this mapping, linear interpolation picks token indices
    // `round(i * 7 / 3)` = {0, 2, 5, 7}, assigning:
    //   - word 1 ("it")   -> tokens[2] ("tu", t=18 instead of 48), and
    //   - word 2 ("is")   -> tokens[5] (" it", t=48 < 50 instead of 52 >= 50),
    // pulling "is" out of the >= 50 overlap window so `TimestampTextMerger`
    // locks "is" into the pre-overlap prefix of chunk 1 and duplicates it from
    // chunk 2.
    //
    // By scanning the cached non-initial pieces (" un", "for", "tu", "nate",
    // "ly", " it", " is", " open") and starting a new word whenever a
    // non-space character follows a space (`!inWord`), we record the exact
    // starting token index for each word.
    //
    // Words are counted the way `detokenize` splits them: on spaces, and with
    // every CJK character as its own word (see `splitCjkCharacters`), so each
    // CJK character gets the timestamp of the token that emits it. Pieces are
    // concatenated before decoding because a byte-level BPE token may hold
    // only part of a multi-byte character.
    final text = <int>[];
    final byteToken = <int>[]; // Token index of each byte of `text`.
    final wordTokenIdx = List<int>.filled(numWords, 0);
    var prevWordCount = 0;
    var inWord = false; // Inside a run of non-CJK characters.
    var attachPunctuation = false; // Punctuation joins the CJK char before.
    var pos = 0;
    for (var k = 0; k < numTokens && prevWordCount < numWords; ++k) {
      final piece = decodedTokenPiece(
        tokenIds[k],
        skipSpecialTokens: skipSpecialTokens,
      );
      if (piece == null) {
        continue;
      }
      text.addAll(piece);
      while (byteToken.length < text.length) {
        byteToken.add(k);
      }
      final lastToken = k + 1 == numTokens;
      while (pos < text.length && prevWordCount < numWords) {
        // Wait for the next token if it may complete a multi-byte character.
        final lead = text[pos];
        final length = lead >= 0xF0 && lead < 0xF8
            ? 4
            : lead >= 0xE0 && lead < 0xF0
            ? 3
            : lead >= 0xC0 && lead < 0xE0
            ? 2
            : 1;
        if (!lastToken && pos + length > text.length) break;
        final start = pos;
        final (cp, next) = decodeUtf8CodePoint(text, pos);
        pos = next;
        var startsWord = false;
        if (cp == 0x20) {
          inWord = false;
          attachPunctuation = false;
        } else if (isCjkCharacter(cp)) {
          startsWord = true;
          inWord = false;
          attachPunctuation = true;
        } else if (!(attachPunctuation && isPunctuation(cp))) {
          startsWord = !inWord;
          inWord = true;
          attachPunctuation = false;
        }
        if (startsWord) {
          wordTokenIdx[prevWordCount++] = byteToken[start];
        }
      }
    }

    if (prevWordCount == 0) {
      // Omni logs that the mapping resolved no word and falls back to linear
      // index interpolation.
      return null;
    }

    while (prevWordCount < numWords) {
      wordTokenIdx[prevWordCount] = numTokens - 1;
      ++prevWordCount;
    }
    return wordTokenIdx;
  }

  /// Turns one window's [tokens] into words. The end-of-chunk sentinel ends
  /// the window; it is passed on as a trailing [DetokenizedWord.endOfChunk]
  /// when it carries a timestamp or the warm-start flag.
  List<DetokenizedWord> detokenize(List<DecodedToken> tokens) {
    if (tokens.isEmpty) {
      return [];
    }

    final tokenIds = <int>[];
    int? endOfChunkTimestampMs;
    var isWarmStartChunk = false;
    var hasTokenTimestamps = false;
    for (final tok in tokens) {
      if (tok.isEndOfChunk) {
        endOfChunkTimestampMs = tok.timestampMs;
        isWarmStartChunk = tok.isWarmStart;
        break;
      }
      if (tok.timestampMs != null) {
        hasTokenTimestamps = true;
      }
      tokenIds.add(tok.tokenId);
    }

    final words = <DetokenizedWord>[];
    if (tokenIds.isNotEmpty) {
      var skipSpecialTokens = true;
      List<int> text;
      try {
        text = _tokenIdsToUtf8(tokenIds, skipSpecialTokens: skipSpecialTokens);
      } on ArgumentError catch (e) {
        // An index out of range is a bug, not the unsupported option below.
        if (e is RangeError) rethrow;
        // A SentencePiece tokenizer (used by Gemma ASR models) does not
        // support skipSpecialTokens = true; fall back to false.
        skipSpecialTokens = false;
        text = _tokenIdsToUtf8(tokenIds, skipSpecialTokens: skipSpecialTokens);
      }
      // Every CJK character is a word of its own (see `splitCjkCharacters`):
      // Chinese and Japanese have no spaces, and the text mergers align
      // overlapping windows word by word.
      final spaceWords = <List<int>>[];
      var wordStart = 0;
      for (var i = 0; i <= text.length; ++i) {
        if (i == text.length || text[i] == 0x20) {
          if (i > wordStart) spaceWords.add(text.sublist(wordStart, i));
          wordStart = i + 1;
        }
      }
      final rawWords = splitCjkCharactersUtf8(spaceWords);

      final numWords = rawWords.length;
      final numTokens = tokenIds.length;

      // Find the starting token index of each word in O(N) when tokens carry
      // timestamps. Subword tokenizers (SentencePiece, BPE) often use 2-5
      // tokens for one word and 1 token for another; linear index
      // interpolation shifts word timestamps away from their acoustic onset
      // and breaks overlap alignment.
      List<int>? wordTokenIdx;
      if (hasTokenTimestamps && numWords >= 1 && numTokens > 1) {
        wordTokenIdx = _mapWordsToOnsetTokenIndices(
          tokenIds,
          numWords,
          skipSpecialTokens: skipSpecialTokens,
        );
      }

      for (var i = 0; i < numWords; ++i) {
        int? timestampMs;
        if (hasTokenTimestamps && numTokens > 0) {
          var tokenIdx = 0;
          if (wordTokenIdx != null) {
            tokenIdx = wordTokenIdx[i];
          } else if (numWords <= 1) {
            tokenIdx = 0;
          } else {
            // std::round: half away from zero, as Dart's round().
            tokenIdx = (i * (numTokens - 1) / (numWords - 1)).round();
          }
          if (tokenIdx > numTokens - 1) tokenIdx = numTokens - 1;

          if (tokens[tokenIdx].timestampMs != null) {
            timestampMs = tokens[tokenIdx].timestampMs;
          } else {
            var minDist = -1;
            for (var j = 0; j < numTokens; ++j) {
              if (tokens[j].timestampMs == null) {
                continue;
              }
              final dist = (j - tokenIdx).abs();
              if (minDist < 0 || dist < minDist) {
                minDist = dist;
                timestampMs = tokens[j].timestampMs;
              }
            }
          }
        }
        words.add(
          DetokenizedWord(
            utf8.decode(rawWords[i], allowMalformed: true),
            timestampMs: timestampMs,
          ),
        );
      }
    }

    if (endOfChunkTimestampMs != null || isWarmStartChunk) {
      words.add(
        DetokenizedWord.endOfChunk(
          timestampMs: endOfChunkTimestampMs,
          isWarmStart: isWarmStartChunk,
        ),
      );
    }

    return words;
  }
}
