// Runtime-agnostic tokenizer seam (Phase 2 — plain-ORT embedding forward
// pass, design D-T1). Mirrors `forward_pass.dart`'s
// `EmbeddingForwardPassFactory` shape exactly: [EmbeddingForwardPassFactory]
// answers "which engine runs the forward pass"; [EmbeddingTokenizerFactory]
// answers "which tokenizer turns text into ids" — the two questions are
// independent (WordPiece-vs-SentencePiece correlates with the *model
// family*, not the engine: EmbeddingGemma is SentencePiece on both LiteRT
// and ONNX). [ForwardPassDescriptor.tokenizerFactory] carries this factory
// alongside [ForwardPassDescriptor.factory] across the same isolate
// boundary.

/// One text's tokenized form, ready for [EmbeddingForwardPass.run].
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
  /// tokenizer's convention adds. Not yet padded/truncated to a fixed
  /// sequence length — that is the forward pass's job (see
  /// `forward_pass.dart`'s module doc).
  final List<int> ids;

  /// Attention mask aligned 1:1 with [ids] (`1` = real token, `0` = padding).
  /// `null` when the tokenizer's convention has no notion of padding at this
  /// stage (e.g. Gemma SentencePiece — the forward pass pads/truncates
  /// internally and has no mask to report back either).
  final List<int>? attentionMask;

  /// Token-type (segment) ids aligned 1:1 with [ids]. `null` for tokenizers
  /// that don't use them (Gemma SentencePiece); all-zeros for single-segment
  /// WordPiece input.
  final List<int>? tokenTypeIds;
}

/// Turns raw text (with a TaskType prefix already applied) into a
/// [TokenizedInput]. One instance per loaded tokenizer file; built once by
/// the worker at startup and reused for every `encode` call.
abstract class EmbeddingTokenizer {
  /// Tokenizes ([prefix] + [text]) per this tokenizer's convention (BOS/EOS
  /// wrap for SentencePiece, [CLS]/.../[SEP] for WordPiece).
  TokenizedInput encode(String prefix, String text);
}

/// Factory that builds an [EmbeddingTokenizer] for a given on-disk tokenizer
/// path.
///
/// MUST be a top-level or static function — a genuine tear-off — and never a
/// closure or bound instance method, for exactly the reason documented on
/// [EmbeddingForwardPassFactory] in `forward_pass.dart`: a
/// [ForwardPassDescriptor] carrying this factory is sent through a
/// [SendPort] into a freshly `Isolate.spawn`'d isolate (see
/// `test/forward_pass_isolate_test.dart` for the boundary proof), and only a
/// top-level/static tear-off survives that trip intact — a closure over
/// local/instance state is either rejected outright or silently loses the
/// captured object identity, and a runtime registry populated via some
/// `register()` call is empty in the freshly spawned isolate no matter what
/// the main isolate registered into it before spawning.
typedef EmbeddingTokenizerFactory =
    Future<EmbeddingTokenizer> Function(String tokenizerPath);
