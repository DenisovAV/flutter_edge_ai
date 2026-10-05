// Resolves named special tokens (`<|startoftranscript|>`, `<|endoftext|>`,
// the GPT-2 space token `Ġ`, ...) to ids from a parsed `tokenizer.json`
// document, so `SttModelProfile` can declare prompt/EOS/suppression tokens
// by NAME rather than hardcoding numeric ids (Global Constraints). Checks
// both `model.vocab` (plain vocab pieces) and `added_tokens` (specials) —
// both are standard HF `tokenizer.json` fields.
library;

/// A decode-loop-relevant token, either a fixed id (no tokenizer.json
/// lookup needed -- moonshine's verified BOS=1/EOS=2) or a name resolved
/// from the loaded tokenizer.json at `SttCore.load()` time (whisper).
sealed class SttTokenRef {
  const SttTokenRef();
  const factory SttTokenRef.id(int id) = _FixedTokenRef;
  const factory SttTokenRef.name(String name) = _NamedTokenRef;

  int resolve(SttSpecialTokenResolver resolver);
}

final class _FixedTokenRef extends SttTokenRef {
  const _FixedTokenRef(this.id);
  final int id;

  @override
  int resolve(SttSpecialTokenResolver resolver) => id;

  @override
  bool operator ==(Object other) => other is _FixedTokenRef && other.id == id;

  @override
  int get hashCode => Object.hash(_FixedTokenRef, id);

  @override
  String toString() => 'SttTokenRef.id($id)';
}

final class _NamedTokenRef extends SttTokenRef {
  const _NamedTokenRef(this.name);
  final String name;

  @override
  int resolve(SttSpecialTokenResolver resolver) => resolver.resolve(name);

  @override
  bool operator ==(Object other) =>
      other is _NamedTokenRef && other.name == name;

  @override
  int get hashCode => Object.hash(_NamedTokenRef, name);

  @override
  String toString() => 'SttTokenRef.name($name)';
}

/// Builds a name->id index from a parsed `tokenizer.json` document's
/// `model.vocab` (piece->id) and `added_tokens` (id/content pairs), then
/// resolves names against it.
class SttSpecialTokenResolver {
  SttSpecialTokenResolver(Map<String, dynamic> tokenizerJson)
    : _byName = _buildIndex(tokenizerJson);

  final Map<String, int> _byName;

  // Deliberately checks `is Map`/`is List` rather than casting the
  // container types directly (`as Map<String, dynamic>`): JSON decoded via
  // dart:convert always yields `Map<String, dynamic>`, but callers (and
  // tests) may hand in Dart map literals whose nested, unannotated `{}`
  // values infer as `Map<dynamic, dynamic>` — a container-level cast would
  // throw even though every individual key/value is perfectly castable.
  static Map<String, int> _buildIndex(Map<String, dynamic> doc) {
    final byName = <String, int>{};
    final model = doc['model'];
    if (model is Map) {
      final vocab = model['vocab'];
      if (vocab is Map) {
        vocab.forEach((key, value) {
          byName[key as String] = value as int;
        });
      }
    }
    final addedTokens = doc['added_tokens'];
    if (addedTokens is List) {
      for (final raw in addedTokens) {
        if (raw is Map) {
          byName[raw['content'] as String] = raw['id'] as int;
        }
      }
    }
    return byName;
  }

  /// Resolve [name] to its token id. Throws a [StateError] naming the
  /// missing token rather than silently falling back — a wrong/renamed
  /// tokenizer bundle must fail loudly, not garble transcripts (Global
  /// Constraints).
  int resolve(String name) {
    final id = _byName[name];
    if (id == null) {
      throw StateError(
        'SttSpecialTokenResolver: token "$name" not found in tokenizer.json '
        '(checked model.vocab and added_tokens)',
      );
    }
    return id;
  }

  /// This checkpoint's language codes → their token ids, harvested from the
  /// same index [resolve] uses: every `<|xx|>` / `<|xxx|>` whose inner text is
  /// 2-3 lowercase letters, keyed WITHOUT the delimiters (`'de' -> 50261`).
  ///
  /// This is the allow-list for `transcribe(language:)`, and the reason there
  /// is no hardcoded list of Whisper's 99 codes anywhere in the package: it is
  /// derived from the tokenizer that is actually installed, so it cannot go
  /// stale, and an `.en`-only checkpoint correctly reports none.
  ///
  /// The shape alone is enough. Measured against `openai/whisper-tiny`'s real
  /// `tokenizer.json`: the pattern matches exactly 99 entries — every language
  /// code including the 3-letter `haw`, and nothing else. Whisper's control
  /// tokens are all either longer than three characters (`<|transcribe|>`,
  /// `<|translate|>`, `<|nospeech|>`, `<|startofprev|>`, `<|notimestamps|>`)
  /// or contain a non-letter (the `<|0.00|>` timestamp block), so no
  /// by-name exclusion list is needed. `<|translate|>` is the one that matters:
  /// it exists, and without the length bound `language: 'translate'` would
  /// resolve cleanly and rewrite the prompt's TASK slot instead of its
  /// language slot.
  late final Map<String, int> languageIds = {
    for (final entry in _byName.entries)
      if (_languageTokenPattern.hasMatch(entry.key))
        entry.key.substring(2, entry.key.length - 2): entry.value,
  };

  static final RegExp _languageTokenPattern = RegExp(r'^<\|[a-z]{2,3}\|>$');
}

/// Runtime-resolved logit suppression, ready for `SttCore._decodeLoop` to
/// apply every step without any further tokenizer.json lookups.
class ResolvedSuppression {
  const ResolvedSuppression({
    required this.suppressAboveId,
    required this.suppressAtStepZeroIds,
  });

  /// Every token id strictly greater than this is forced to `-inf` at
  /// EVERY decode step (whisper: `<|endoftext|>`'s id — the timestamp
  /// block and all non-text specials sit contiguously above it).
  final int suppressAboveId;

  /// Additionally forced to `-inf`, but ONLY at decode step 0.
  final Set<int> suppressAtStepZeroIds;
}
