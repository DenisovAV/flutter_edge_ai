// Runtime-agnostic tokenizer seam (design D-T1). An engine's
// `EmbeddingPassDescriptor` answers "which engine runs the model";
// [EmbeddingTokenizerFactory] answers "which tokenizer turns text into ids" —
// the two questions are independent (WordPiece-vs-SentencePiece correlates
// with the *model family*, not the engine: EmbeddingGemma is SentencePiece on
// both LiteRT and ONNX). A `TokenEmbeddingPass` takes this factory in its
// constructor, so an engine's pass config carries it across the same isolate
// boundary as the rest of the descriptor.

/// One text's tokenized form, ready for `TokenEmbeddingPass.runTokens`.
///
/// [attentionMask] / [tokenTypeIds] are `null` for tokenizers that don't
/// produce them (Gemma SentencePiece); WordPiece tokenizers always populate
/// them (all-ones mask, all-zeros type-ids for single-segment input).
class TokenizedInput {
  const TokenizedInput({
    required this.ids,
    this.attentionMask,
    this.tokenTypeIds,
  });

  /// Token ids, including any special tokens (BOS/EOS or [CLS]/[SEP]) the
  /// tokenizer's convention adds. Never truncated: `TokenEmbeddingPass`
  /// refuses ids longer than the graph takes
  /// (`EmbeddingInputTooLongException`), and a static-shape graph pads them
  /// in `runTokens`.
  final List<int> ids;

  /// Attention mask aligned 1:1 with [ids] (`1` = real token, `0` = padding).
  /// `null` when the tokenizer's convention has no notion of padding at this
  /// stage (e.g. Gemma SentencePiece — a graph that pads echoes its own mask
  /// in `ForwardResult.attentionMask` instead).
  final List<int>? attentionMask;

  /// Token-type (segment) ids aligned 1:1 with [ids]. `null` for tokenizers
  /// that don't use them (Gemma SentencePiece); all-zeros for single-segment
  /// WordPiece input.
  final List<int>? tokenTypeIds;
}

/// Turns raw text (with a TaskType prefix already applied) into a
/// [TokenizedInput]. One instance per loaded tokenizer file; built once by
/// `TokenEmbeddingPass.load` and reused for every `encode` call.
abstract class EmbeddingTokenizer {
  /// Tokenizes ([prefix] + [text]) per this tokenizer's convention (BOS/EOS
  /// wrap for SentencePiece, [CLS]/.../[SEP] for WordPiece).
  TokenizedInput encode(String prefix, String text);
}

/// Factory that builds an [EmbeddingTokenizer] for a given on-disk tokenizer
/// path.
///
/// MUST be a top-level or static function — a genuine tear-off — and never a
/// closure or bound instance method, for the reason documented on
/// `EmbeddingPassDescriptor`: on native the descriptor, and the pass config
/// carrying this factory, are sent into core's freshly spawned worker isolate
/// (see `test/embedding/embedding_host_test.dart` for the boundary), and only
/// a top-level/static tear-off survives that trip intact — a closure over
/// local/instance state is either rejected outright or silently loses the
/// captured object identity, and a runtime registry populated via some
/// `register()` call is empty in the freshly spawned isolate no matter what
/// the main isolate registered into it before spawning.
typedef EmbeddingTokenizerFactory =
    Future<EmbeddingTokenizer> Function(String tokenizerPath);
