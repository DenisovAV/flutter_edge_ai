// SentencePiece's USER_DEFINED pieces, which `dart_sentencepiece_tokenizer`
// (1.4.1) does not honour.
//
// Google's SentencePiece matches a model's user-defined pieces BEFORE the model
// runs: at each position of the normalized text it takes the longest
// user-defined piece that starts there (its `PrefixMatcher`), and the BPE model
// treats that piece as one frozen symbol — never merged with a neighbour. The
// Dart package treats them as ordinary vocabulary, so Gemma's tag pieces come
// apart: `</div>` is the single piece 235 in SentencePiece (and in the LiteRT.js
// web bundle) but `</` `div` `>` (954, 1928, 236813) in the package, and
// `<mask>`, `<ctrl1>`, `[multimodal]` likewise. Gemma's vocabulary has 6,410 of
// them: 6,316 tags and 92 runs of spaces, newlines and tabs, which the
// package's BPE already happens to reach.
//
// [UserDefinedPieces.encode] does what SentencePiece does: the longest-match
// pass over the normalized text, each match emitted as its own id, and the
// text between two matches handed to the package. For BPE that is exact, not
// an approximation: a frozen symbol takes part in no merge, so every merge
// happens inside one stretch between two matches, in the same order as when
// the whole string is one agenda. And because the pass matches at EVERY
// position, greedily from the left, a stretch contains no user-defined piece
// for the package's BPE to build either.
//
// It applies to a pipeline where "normalize the whole text, then split" equals
// "split, then normalize each stretch": a BPE model whose normalization is
// character by character (at most spaces escaped to U+2581) — no dummy prefix,
// no whitespace collapsing, no precompiled character map. That is Gemma's, in
// all three file forms the loader reads. A BPE model with user-defined pieces
// and any other normalizer is refused at load: the dependency would split its
// pieces without a sign. A Unigram model (Gecko) gets no pass and tokenizes as
// before — the dependency's lattice keeps its pieces whole — and so does a
// tokenizer.json not in Gemma's shape, under the dependency's own HuggingFace
// added-token matching.
//
// test/sentencepiece_reference_test.dart compares the result with the Python
// `sentencepiece` package row by row.

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';

import 'sentencepiece_model_proto.dart';

/// U+2581, what SentencePiece escapes a space to.
const _escapedSpace = '\u2581';

/// A model's user-defined pieces and how its normalizer treats spaces: what
/// [encode] needs to tokenize as SentencePiece does.
final class UserDefinedPieces {
  UserDefinedPieces._(Map<String, int> pieces, {required this.escapesSpaces})
    : _ids = pieces,
      _lengthsByFirstUnit = _lengths(pieces.keys);

  /// Piece → id.
  final Map<String, int> _ids;

  /// For each first UTF-16 code unit of a piece, the lengths of the pieces
  /// that start with it, longest first: the only substrings worth looking up.
  final Map<int, List<int>> _lengthsByFirstUnit;

  /// Whether the model's normalizer escapes ' ' to U+2581. The pieces are
  /// matched on the NORMALIZED text, so Gemma's run piece `\u2581\u2581`
  /// matches two spaces of input.
  final bool escapesSpaces;

  /// How many user-defined pieces the model has.
  int get length => _ids.length;

  static Map<int, List<int>> _lengths(Iterable<String> pieces) {
    final byUnit = <int, Set<int>>{};
    for (final piece in pieces) {
      (byUnit[piece.codeUnitAt(0)] ??= <int>{}).add(piece.length);
    }
    return {
      for (final MapEntry(:key, :value) in byUnit.entries)
        key: value.toList()..sort((a, b) => b - a),
    };
  }

  /// The ids SentencePiece produces for [text] (no BOS, no EOS): the longest
  /// user-defined piece at each position, as its own id, and everything
  /// between two of them encoded by [bpe] — the package tokenizer loaded from
  /// the same file, which must apply no added-token matching of its own (the
  /// loader guarantees that).
  ///
  /// Each stretch is handed over already normalized. That is a no-op for the
  /// pipelines this class is built for (escaping is the whole normalization,
  /// and a stretch has no space left to escape), and it is what keeps the
  /// matching and the encoding on the same characters.
  List<int> encode(SentencePieceTokenizer bpe, String text) {
    final normalized = escapesSpaces
        ? text.replaceAll(' ', _escapedSpace)
        : text;
    final ids = <int>[];
    var stretch = 0;
    var i = 0;
    while (i < normalized.length) {
      final match = _longestAt(normalized, i);
      if (match == null) {
        i += _codePointLength(normalized, i);
        continue;
      }
      if (stretch < i) {
        ids.addAll(bpe.encode(normalized.substring(stretch, i)).ids);
      }
      ids.add(match.id);
      i += match.length;
      stretch = i;
    }
    if (stretch < normalized.length) {
      ids.addAll(bpe.encode(normalized.substring(stretch)).ids);
    }
    return ids;
  }

  ({int id, int length})? _longestAt(String text, int start) {
    final lengths = _lengthsByFirstUnit[text.codeUnitAt(start)];
    if (lengths == null) return null;
    final left = text.length - start;
    for (final length in lengths) {
      if (length > left) continue;
      final id = _ids[text.substring(start, start + length)];
      if (id != null) return (id: id, length: length);
    }
    return null;
  }

  static int _codePointLength(String text, int i) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
      final next = text.codeUnitAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) return 2;
    }
    return 1;
  }

  /// For a SentencePiece `.model`, read by [SentencePieceModelProto.parse]
  /// from [source].
  ///
  /// Null when there is nothing for this pass to do: the model has no
  /// user-defined piece, or it is not BPE. A Unigram model (Gecko) is left to
  /// the dependency on purpose — its lattice keeps user-defined pieces whole
  /// (Gecko's 100 `\u2581<extra_id_N>` pieces tokenize as SentencePiece's).
  ///
  /// Throws [UnsupportedError] for a BPE model that has user-defined pieces
  /// and a normalizer this pass cannot reproduce them under (a dummy prefix,
  /// whitespace collapsing or a precompiled character map): the dependency
  /// would split every piece into ids SentencePiece never produces, with no
  /// sign anything went wrong.
  static UserDefinedPieces? fromModelProto(
    SentencePieceModelProto model, {
    required String source,
  }) {
    if (model.userDefined.isEmpty || model.modelType != bpeModelType) {
      return null;
    }
    _requireCharacterLocal(
      source,
      model.userDefined.length,
      dummyPrefix: model.addDummyPrefix,
      collapsesWhitespace: model.removeExtraWhitespaces,
      characterMap: model.hasCharsmap,
    );
    return UserDefinedPieces._(
      model.userDefined,
      escapesSpaces: model.escapeWhitespaces,
    );
  }

  /// Reads a HuggingFace `tokenizer.json` in Gemma's shape — a BPE model, the
  /// single `Replace(' ' → '\u2581')` normalizer, no pre-tokenizer or a
  /// `Split` on ' ' (a no-op once no space is left), `<pad>`/`<eos>`/`<bos>`
  /// at ids 0/1/2, and added tokens with no `lstrip`/`rstrip`/`single_word`/
  /// `normalized` flags. Null for any other file, which then tokenizes with
  /// the dependency's own HuggingFace added-token matching.
  ///
  /// A `tokenizer.json` carries no piece types, and its `special` flag is NOT
  /// one: the HuggingFace converter marks a user-defined piece `special` when
  /// the tokenizer's config lists it as a special token. Measured on three
  /// Gemma-family pairs (onnx-community/embeddinggemma-300m-ONNX,
  /// google/siglip2-base-patch16-224, onnx-community/gemma-3-270m-it-ONNX),
  /// against each repository's own `tokenizer.model`:
  ///
  /// - every added token marked `special: false` is USER_DEFINED;
  /// - `special: true` covers CONTROL (`<pad>`, `<eos>`, `<bos>`, ids 0–2 —
  ///   the only CONTROL pieces in all three), UNKNOWN (`<unk>`), a token
  ///   outside the model (`<image_soft_token>`), and USER_DEFINED pieces —
  ///   `<start_of_turn>`, `<end_of_turn>`, `<start_of_image>`,
  ///   `<end_of_image>`, and `<mask>` in Gemma 3 270M — which SentencePiece
  ///   keeps whole in text like any other.
  ///
  /// So the user-defined pieces are the added tokens in the vocabulary other
  /// than ids 0–2 and the unknown token, `special` or not. A token the file
  /// itself makes ambiguous is refused with a [FormatException] naming it and
  /// [source], rather than typed by guess: one at ids 0–2 or the unknown id
  /// not marked `special`; one whose text the vocabulary gives another id, or
  /// whose id holds other text; one the post-processor or the padding uses as
  /// a sequence special token (which may make it a control piece).
  ///
  /// Returns, with the pieces, the map to build the tokenizer for the text
  /// between two pieces from: [json] with `added_tokens` emptied, because the
  /// dependency would otherwise match all of them there — turning a literal
  /// `<bos>` into id 2 and `<image_soft_token>` into an id past the embedding
  /// table.
  static ({UserDefinedPieces pieces, Map<String, dynamic> stretchJson})?
  fromHuggingFaceJson(Map<String, dynamic> json, {required String source}) {
    final model = json['model'];
    if (model is! Map<String, dynamic> || model['type'] != 'BPE') return null;
    final vocab = model['vocab'];
    if (vocab is! Map<String, dynamic>) return null;
    if (!_isSpaceEscape(json['normalizer'])) return null;
    if (!_isNoOpAfterEscape(json['pre_tokenizer'])) return null;
    if (vocab['<pad>'] != 0 || vocab['<eos>'] != 1 || vocab['<bos>'] != 2) {
      return null;
    }
    final added = json['added_tokens'] ?? const <Object?>[];
    if (added is! List) return null;
    final tokens = <({int id, String content, bool special})>[];
    for (final token in added) {
      if (token is! Map<String, dynamic>) return null;
      final id = token['id'];
      final content = token['content'];
      if (id is! int || content is! String || content.isEmpty) return null;
      if (token['lstrip'] == true ||
          token['rstrip'] == true ||
          token['single_word'] == true ||
          token['normalized'] == true) {
        return null;
      }
      tokens.add((id: id, content: content, special: token['special'] == true));
    }

    // CONTROL <pad> <eos> <bos> and UNKNOWN <unk>: never produced from text.
    final unknownId = vocab[model['unk_token']];
    final notFromText = {0, 1, 2, if (unknownId is int) unknownId};
    final sequenceSpecials = _sequenceSpecialTokens(json);
    final pieces = <String, int>{};
    for (final (:id, :content, :special) in tokens) {
      Never refuse(String why) => throw FormatException(
        'Cannot tell which SentencePiece piece type the added token '
        '"$content" (id $id) of $source has: $why. The file alone cannot '
        'decide it, and guessing would change ids silently. Install the '
        "model's tokenizer.model instead: it records each piece's type.",
      );
      final vocabId = vocab[content];
      if (vocabId != id) {
        if (vocabId != null) {
          refuse('the vocabulary gives its text id $vocabId');
        }
        if (id >= 0 && id < vocab.length) {
          refuse(
            'its id is inside the vocabulary, which holds other text there',
          );
        }
        continue; // Outside the model: not a SentencePiece piece at all.
      }
      if (notFromText.contains(id)) {
        if (!special) {
          refuse(
            'it is the vocabulary\'s ${id == unknownId ? 'unknown' : 'control'} '
            'token, yet not marked special',
          );
        }
        continue;
      }
      if (sequenceSpecials.contains(content)) {
        refuse(
          'the post-processor or the padding uses it as a sequence special '
          'token, so it may be a control piece',
        );
      }
      pieces[content] = id;
    }
    return (
      pieces: UserDefinedPieces._(pieces, escapesSpaces: true),
      stretchJson: {...json, 'added_tokens': const <Object?>[]},
    );
  }

  /// Every token text the post-processor inserts around a sequence or the
  /// padding fills with: `SpecialToken` ids and `special_tokens` entries of a
  /// template (also inside a `Sequence` of processors), the `cls`/`sep` pair of
  /// a BERT/RoBERTa processor, and the padding's `pad_token`.
  static Set<String> _sequenceSpecialTokens(Map<String, dynamic> json) {
    final found = <String>{};
    void walk(Object? node) {
      switch (node) {
        case {'SpecialToken': {'id': final String id}}:
          found.add(id);
        case Map<String, dynamic>():
          if (node['special_tokens'] case final Map<String, dynamic> map) {
            for (final entry in map.values) {
              if (entry case {'id': final String id}) found.add(id);
              if (entry case {'tokens': final List<Object?> tokens}) {
                found.addAll(tokens.whereType<String>());
              }
            }
          }
          for (final key in const ['cls', 'sep']) {
            if (node[key] case [final String token, _]) found.add(token);
          }
          node.values.forEach(walk);
        case List<Object?>():
          node.forEach(walk);
      }
    }

    walk(json['post_processor']);
    if (json['padding'] case {'pad_token': final String pad}) found.add(pad);
    return found;
  }

  /// Reads the package's own JSON format (`SentencePieceTokenizerJson.toJson`),
  /// which keeps the piece types. Null when it has no user-defined piece or
  /// is not BPE; a BPE model with user-defined pieces and a normalizer this
  /// pass cannot reproduce is refused as [fromModelProto] refuses it.
  static UserDefinedPieces? fromLibraryJson(
    Map<String, dynamic> json, {
    required String source,
  }) {
    if (json['model_type'] != 'bpe') return null;
    final vocab = json['vocab'];
    if (vocab is! Map<String, dynamic>) return null;
    final pieces = vocab['pieces'];
    final types = vocab['types'];
    if (pieces is! List || types is! List || pieces.length != types.length) {
      return null;
    }
    final userDefined = <String, int>{};
    for (var id = 0; id < types.length; id++) {
      final piece = pieces[id];
      if (types[id] != userDefinedPieceType ||
          piece is! String ||
          piece.isEmpty) {
        continue;
      }
      userDefined.putIfAbsent(piece, () => id);
    }
    if (userDefined.isEmpty) return null;
    final normalizer = json['normalizer'];
    final flags = normalizer is Map<String, dynamic>
        ? normalizer
        : const <String, dynamic>{};
    _requireCharacterLocal(
      source,
      userDefined.length,
      dummyPrefix: flags['add_dummy_prefix'] != false,
      collapsesWhitespace: flags['remove_extra_whitespaces'] != false,
      characterMap:
          flags['precompiled_charsmap'] != null ||
          flags['operations'] != null ||
          json['pre_tokenizer'] != null,
    );
    return UserDefinedPieces._(
      userDefined,
      escapesSpaces: flags['escape_whitespaces'] != false,
    );
  }

  /// Throws unless a BPE model's normalization is character by character —
  /// the only kind under which "match, then encode the rest" is exactly what
  /// SentencePiece does.
  static void _requireCharacterLocal(
    String source,
    int userDefined, {
    required bool dummyPrefix,
    required bool collapsesWhitespace,
    required bool characterMap,
  }) {
    final unsupported = [
      if (dummyPrefix) 'a dummy prefix',
      if (collapsesWhitespace) 'whitespace collapsing',
      if (characterMap) 'a precompiled character map or pre-tokenizer',
    ];
    if (unsupported.isEmpty) return;
    throw UnsupportedError(
      '$source is a BPE SentencePiece model with $userDefined user-defined '
      'pieces and ${unsupported.join(' and ')} in its normalizer. '
      'dart_sentencepiece_tokenizer splits user-defined pieces, and this '
      'package keeps them whole only under character-by-character '
      'normalization, so its ids would differ from SentencePiece\'s without '
      'any error. This tokenizer is not supported.',
    );
  }

  /// `{"type": "Replace", "pattern": {"String": " "}, "content": "\u2581"}`,
  /// alone or as the only member of a `Sequence`.
  static bool _isSpaceEscape(Object? normalizer) => switch (normalizer) {
    {'type': 'Sequence', 'normalizers': [final only]} => _isSpaceEscape(only),
    {'type': 'Replace', 'pattern': {'String': ' '}, 'content': _escapedSpace} =>
      true,
    _ => false,
  };

  /// No pre-tokenizer, or a `Split` on a literal space that is not inverted:
  /// after the escape no space is left for it to split on.
  static bool _isNoOpAfterEscape(Object? preTokenizer) =>
      switch (preTokenizer) {
        null => true,
        {'type': 'Split', 'pattern': {'String': ' '}, 'invert': final invert} =>
          invert != true,
        {'type': 'Split', 'pattern': {'String': ' '}} => true,
        _ => false,
      };
}
