/// Reads a HuggingFace `tokenizer.json` well enough to tell which special-token
/// convention it declares — without building a tokenizer, and without touching
/// `dart:io`, so an engine's web arm can call it too.
///
/// This exists because a tokenizer file is not identified by its vocabulary.
/// SigLIP 2 uses the Gemma BPE vocabulary verbatim — same 256k pieces, same
/// `<pad>`=0 and `<eos>`=1 — so "is this a Gemma tokenizer or a SigLIP text
/// tower?" cannot be answered from `model.vocab`. It CAN be answered from the
/// pipeline blocks, which is where HuggingFace records the convention:
///
/// | block | SigLIP 2 | Gemma |
/// |---|---|---|
/// | `padding` | `{"strategy": {"Fixed": 64}, "pad_id": 0}` | `null` |
/// | `post_processor.single` | `[Sequence A, <eos>]` | `[<bos>, Sequence A]` |
///
/// Getting this wrong is silent: every id stays in range and nothing throws, so
/// a SigLIP model tokenized the Gemma way returns a plausible vector that is
/// simply the wrong point in the embedding space.
library;

/// True when [json] — a decoded HuggingFace `tokenizer.json` — declares the
/// SigLIP 2 text-tower convention: a fixed-width right padding block, and a
/// post-processor that appends an EOS without prepending a BOS.
///
/// Both signals are required. A fixed padding block alone is not enough (other
/// models pad), and a BOS-less template alone is not enough (a plain BPE export
/// may declare no post-processor at all). Missing or malformed blocks answer
/// false rather than throwing: the question is "does this file declare SigLIP 2",
/// and anything it cannot establish is a no.
bool isSiglip2TokenizerJson(Map<String, dynamic> json) =>
    _hasFixedPadding(json) && _appendsEosWithoutBos(json);

bool _hasFixedPadding(Map<String, dynamic> json) {
  final padding = json['padding'];
  if (padding is! Map) return false;
  final strategy = padding['strategy'];
  // `"strategy": {"Fixed": 64}` — a fixed width, as opposed to `"BatchLongest"`.
  return strategy is Map && strategy.containsKey('Fixed');
}

bool _appendsEosWithoutBos(Map<String, dynamic> json) {
  final pp = json['post_processor'];
  if (pp is! Map) return false;
  final single = pp['single'];
  if (single is! List || single.isEmpty) return false;

  // Entries are one-key maps: {"Sequence": …} or {"SpecialToken": {"id": …}}.
  String? specialId(Object? entry) {
    if (entry is! Map) return null;
    final token = entry['SpecialToken'];
    return token is Map ? token['id'] as String? : null;
  }

  final leading = specialId(single.first);
  final trailing = specialId(single.last);
  final bosLike = leading != null && leading.contains('bos');
  final eosLike = trailing != null && trailing.contains('eos');
  return eosLike && !bosLike;
}
