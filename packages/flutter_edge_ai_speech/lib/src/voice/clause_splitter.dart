/// Splits a streaming token sequence into speakable clauses for incremental TTS.
///
/// [feed] accumulates tokens and returns any COMPLETE clauses — a run of text
/// ending at a sentence boundary (one-or-more of `.`/`!`/`?` **followed by
/// whitespace**, or a newline) whose trimmed length is at least [minLength].
/// Requiring trailing whitespace (not end-of-buffer) means a token-final `.`
/// stays buffered until the following space arrives — so `3.14` never splits,
/// and the real end-of-reply clause is emitted via [flush]. Short fragments
/// (`Hi. `, `Dr. `) fall under [minLength] and merge forward into the next
/// clause, which also mitigates false splits on abbreviations.
class ClauseSplitter {
  ClauseSplitter({this.minLength = 8});

  /// Minimum trimmed length before a sentence boundary is allowed to split, so
  /// tiny fragments merge forward instead of becoming their own choppy,
  /// prosody-poor TTS chunk.
  final int minLength;

  final StringBuffer _buf = StringBuffer();

  static final RegExp _boundary = RegExp(r'[.!?]+\s+|\n+');

  /// Feed one streamed token; returns the clauses it completed (possibly none or
  /// several).
  List<String> feed(String token) {
    _buf.write(token);
    final text = _buf.toString();
    final out = <String>[];
    var start = 0;
    for (final m in _boundary.allMatches(text)) {
      final candidate = text.substring(start, m.end);
      if (candidate.trim().length >= minLength) {
        out.add(candidate);
        start = m.end;
      }
    }
    if (start > 0) {
      final rest = text.substring(start);
      _buf
        ..clear()
        ..write(rest);
    }
    return out;
  }

  /// Return and clear whatever remains buffered — the final, possibly
  /// unterminated clause. May be empty or whitespace-only (the caller should
  /// skip empties before synthesizing).
  String flush() {
    final s = _buf.toString();
    _buf.clear();
    return s;
  }
}
