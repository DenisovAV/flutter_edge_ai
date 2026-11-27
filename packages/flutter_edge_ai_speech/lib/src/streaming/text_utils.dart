/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified: ported from C++ (LiteRT-LM v0.19.1, omni/base/text_utils.{h,cc})
 * to Dart for flutter_edge_ai_speech.
 */

/// Unicode text helpers shared by the streaming speech-to-text port, e.g.
/// for languages written without spaces between words (Chinese, Japanese).
///
/// The C++ original works on UTF-8 bytes; so does this port wherever a
/// length or an index is observable (byte lengths decide matches in the
/// mergers), with `String` wrappers for callers that hold Dart strings.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Decodes the UTF-8 code point starting at byte [pos] of [text] and returns
/// it with the position just past it. An invalid or truncated sequence decodes
/// as its first byte (and advances by one byte), so iteration always
/// terminates. Returns `(0, pos)` when `pos >= text.length`.
(int codePoint, int next) decodeUtf8CodePoint(List<int> text, int pos) {
  if (pos >= text.length) return (0, pos);
  final c0 = text[pos];
  var len = 1;
  var cp = c0;
  if (c0 >= 0xC0 && c0 < 0xE0) {
    len = 2;
    cp = c0 & 0x1F;
  } else if (c0 >= 0xE0 && c0 < 0xF0) {
    len = 3;
    cp = c0 & 0x0F;
  } else if (c0 >= 0xF0 && c0 < 0xF8) {
    len = 4;
    cp = c0 & 0x07;
  }
  if (len == 1 || pos + len > text.length) {
    return (c0, pos + 1);
  }
  for (var k = 1; k < len; ++k) {
    final ck = text[pos + k];
    if ((ck & 0xC0) != 0x80) {
      return (c0, pos + 1);
    }
    cp = (cp << 6) | (ck & 0x3F);
  }
  return (cp, pos + len);
}

/// True for Han ideographs, Hiragana and Katakana, and the letters and
/// numerals of the CJK Symbols and Punctuation block (e.g. "々" in "人々", "〇"
/// in "二〇二六"): characters of scripts written without spaces between words.
bool isCjkCharacter(int codePoint) {
  final cp = codePoint;
  return (cp >= 0x3005 && cp <= 0x3007) || // Iteration marks, 〆, 〇
      (cp >= 0x3021 && cp <= 0x3029) || // Hangzhou numerals
      (cp >= 0x3031 && cp <= 0x3035) || // Kana repeat marks
      (cp >= 0x3038 && cp <= 0x303C) || // Hangzhou numerals, 〻, 〼
      (cp >= 0x3040 && cp <= 0x30FF) || // Hiragana, Katakana
      (cp >= 0x3400 && cp <= 0x4DBF) || // CJK Extension A
      (cp >= 0x4E00 && cp <= 0x9FFF) || // CJK Unified Ideographs
      (cp >= 0xF900 && cp <= 0xFAFF) || // CJK Compatibility Ideographs
      (cp >= 0x20000 && cp <= 0x2FA1F); // CJK Extensions B-F
}

/// True for CJK punctuation and symbols (U+3001..U+303F except the letters
/// and numerals there, e.g. "。、「」") and fullwidth ASCII punctuation (e.g.
/// "，？！："). The ideographic space U+3000 is not punctuation.
bool isCjkPunctuation(int codePoint) {
  final cp = codePoint;
  // U+3001..U+303F except the letters and numerals in that block (see
  // `isCjkCharacter`). U+3000 is the ideographic space, not punctuation.
  if (cp >= 0x3001 && cp <= 0x303F) return !isCjkCharacter(cp);
  return (cp >= 0xFF01 && cp <= 0xFF0F) ||
      (cp >= 0xFF1A && cp <= 0xFF20) ||
      (cp >= 0xFF3B && cp <= 0xFF40) ||
      (cp >= 0xFF5B && cp <= 0xFF65);
}

/// `std::ispunct` in the "C" locale: the printable ASCII characters that are
/// neither alphanumeric nor a space.
bool _isAsciiPunct(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E);

/// True for ASCII punctuation, CJK and fullwidth punctuation, and the General
/// Punctuation block (e.g. curly quotes, dashes, ellipsis).
bool isPunctuation(int codePoint) {
  final cp = codePoint;
  if (cp < 0x80) return _isAsciiPunct(cp);
  return isCjkPunctuation(cp) ||
      (cp >= 0x2010 && cp <= 0x205E) ||
      cp == 0x00A1 ||
      cp == 0x00AB ||
      cp == 0x00BB ||
      cp == 0x00BF;
}

/// Byte-level [splitCjkCharacters]: each word and each returned piece is a
/// UTF-8 byte sequence.
List<Uint8List> splitCjkCharactersUtf8(List<List<int>> words) {
  final pieces = <BytesBuilder>[];
  for (final word in words) {
    // Non-CJK text accumulated since the last CJK character of this word.
    var pending = BytesBuilder(copy: false);
    // Whether the last piece pushed for this word ends with a CJK character,
    // so that directly following punctuation attaches to it.
    var attachPunctuation = false;
    var pos = 0;
    while (pos < word.length) {
      final start = pos;
      final (cp, next) = decodeUtf8CodePoint(word, pos);
      pos = next;
      final ch = word.sublist(start, pos);
      if (isCjkCharacter(cp)) {
        if (pending.isNotEmpty) pieces.add(pending);
        pending = BytesBuilder(copy: false);
        pieces.add(BytesBuilder(copy: false)..add(ch));
        attachPunctuation = true;
      } else if (attachPunctuation && isPunctuation(cp)) {
        pieces.last.add(ch);
      } else {
        pending.add(ch);
        attachPunctuation = false;
      }
    }
    if (pending.isNotEmpty) pieces.add(pending);
  }
  return [for (final piece in pieces) piece.takeBytes()];
}

/// Splits [words] so that every CJK character (see [isCjkCharacter]) is its
/// own piece, keeping the punctuation that directly follows it attached
/// ("吗？" is one piece). Other text, e.g. Latin words, is kept as is. This
/// turns space-separated "words" into units that can be aligned or compared
/// for any script: a decoder that splits on spaces otherwise yields a whole
/// Chinese sentence as one word.
List<String> splitCjkCharacters(List<String> words) => [
  for (final piece in splitCjkCharactersUtf8([
    for (final word in words) utf8.encode(word),
  ]))
    utf8.decode(piece, allowMalformed: true),
];

/// The last code point of a non-empty [text].
int _lastCodePoint(String text) {
  final last = text.codeUnitAt(text.length - 1);
  if (text.length >= 2 && last >= 0xDC00 && last <= 0xDFFF) {
    final lead = text.codeUnitAt(text.length - 2);
    if (lead >= 0xD800 && lead <= 0xDBFF) {
      return 0x10000 + ((lead - 0xD800) << 10) + (last - 0xDC00);
    }
  }
  return last;
}

/// Joins [pieces] with a space between them, except between two CJK
/// characters and next to CJK punctuation, which carries its own spacing.
/// Inverts [splitCjkCharacters] for text that separates words with spaces,
/// puts spaces around Latin words inside CJK text (e.g. "欢迎体验 LiteRT 演示。")
/// and none next to fullwidth punctuation (e.g. "请看（LiteRT）演示").
String joinWithCjkAwareSpacing(Iterable<String> pieces) {
  final text = StringBuffer();
  var lastPiece = '';
  for (final piece in pieces) {
    if (piece.isEmpty) continue;
    if (text.isNotEmpty) {
      // The last code point of `text` and the first one of `piece`.
      final last = _lastCodePoint(lastPiece);
      final first = piece.runes.first;
      // Fullwidth CJK punctuation carries its own spacing, so it never gets
      // an extra space on either side ("好，OK", "（LiteRT）").
      final glued =
          isCjkPunctuation(last) ||
          isCjkPunctuation(first) ||
          (isCjkCharacter(last) && isCjkCharacter(first));
      if (!glued) text.write(' ');
    }
    text.write(piece);
    lastPiece = piece;
  }
  return text.toString();
}
