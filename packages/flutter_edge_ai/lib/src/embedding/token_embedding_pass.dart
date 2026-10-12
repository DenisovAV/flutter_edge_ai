// The template for engines that tokenize in Dart (R5 D3): tokenize → length
// check → run → finalize, written once. The .tflite, ONNX-native and ONNX-web
// passes share it, so SigLIP's prefix handling (in the tokenizer adapter) and
// the overflow check live in one place.

import 'package:meta/meta.dart';

import 'embedding_exceptions.dart';
import 'embedding_input.dart';
import 'embedding_modality.dart';
import 'embedding_pass.dart';
import 'forward_result.dart';
import 'task_type.dart';
import 'tokenizer_adapter.dart';

/// What [TokenEmbeddingPass.openGraph] reports about the opened graph.
final class TokenPassGraph {
  const TokenPassGraph({
    required this.dimension,
    required this.outputContract,
    this.maxInputTokens,
  });

  /// Length of the final vector.
  final int dimension;

  /// How the graph's raw output becomes the final vector.
  final EmbeddingOutputContract outputContract;

  /// Longest id sequence the graph takes — e.g. a `.tflite` input tensor's
  /// sequence dimension. Null for a dynamic-shape graph that declares none.
  final int? maxInputTokens;
}

/// An [EmbeddingPass] for an engine that tokenizes in Dart. Text only.
///
/// Subclasses open, run and close their graph; this class owns the tokenizer,
/// the task prefix, the length check and the finalisation, and nobody else
/// may override them.
abstract base class TokenEmbeddingPass extends EmbeddingPass {
  TokenEmbeddingPass({
    required String tokenizerPath,
    required EmbeddingTokenizerFactory tokenizerFactory,
  }) : _tokenizerPath = tokenizerPath,
       _tokenizerFactory = tokenizerFactory;

  final String _tokenizerPath;
  final EmbeddingTokenizerFactory _tokenizerFactory;

  EmbeddingTokenizer? _tokenizer;
  TokenPassGraph? _graph;
  bool _graphOpening = false;
  bool _closed = false;

  /// Opens the graph. Called by [load] after the tokenizer is built.
  @protected
  Future<TokenPassGraph> openGraph();

  /// One forward run over [input]. The ids are already length-checked; a
  /// static-shape graph pads here, and echoes the padded mask in
  /// `ForwardResult.attentionMask`.
  @protected
  Future<ForwardResult> runTokens(TokenizedInput input);

  /// Frees the graph. Idempotent. Also called when [openGraph] threw, to free
  /// whatever it had allocated by then; never called when [openGraph] never
  /// ran.
  @protected
  Future<void> closeGraph();

  /// Builds the tokenizer (`tokenizerFactory(tokenizerPath)`), calls
  /// [openGraph], and reports text, the graph's dimension and its
  /// `maxInputTokens`.
  @override
  @nonVirtual
  Future<EmbeddingPassInfo> load() async {
    _tokenizer = await _tokenizerFactory(_tokenizerPath);
    _graphOpening = true;
    final graph = await openGraph();
    _graph = graph;
    return EmbeddingPassInfo(
      dimension: graph.dimension,
      modalities: const {EmbeddingModality.text},
      maxInputTokens: graph.maxInputTokens,
    );
  }

  /// `tokenizer.encode(taskType.prefix, input.text!)` — the tokenizer adapter
  /// decides what the prefix means (SigLIP drops it). Throws
  /// [EmbeddingInputTooLongException] when the ids — prefix, BOS and EOS
  /// included — are longer than the graph's `maxInputTokens`; otherwise runs
  /// [runTokens] and finalises the result with the effective mask (the one the
  /// graph echoed, else the tokenizer's).
  @override
  @nonVirtual
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final tokenizer = _tokenizer;
    final graph = _graph;
    if (tokenizer == null || graph == null) {
      throw StateError('$runtimeType.embed() called before load() succeeded');
    }
    final text = input.text;
    if (text == null || input.modalities.length != 1) {
      throw StateError(
        '$runtimeType embeds text only; got ${input.modalities}',
      );
    }
    final tokenized = tokenizer.encode(taskType.prefix, text);
    final maxInputTokens = graph.maxInputTokens;
    final actualTokens = tokenized.ids.length;
    if (maxInputTokens != null && actualTokens > maxInputTokens) {
      throw EmbeddingInputTooLongException(
        'The input is $actualTokens tokens (task prefix, BOS and EOS '
        'included); this model takes at most $maxInputTokens. Split the text '
        'and embed the pieces.',
        maxInputTokens: maxInputTokens,
        actualTokens: actualTokens,
      );
    }
    final result = await runTokens(tokenized);
    return finalizeEmbedding(
      graph.outputContract,
      result,
      attentionMask: result.attentionMask ?? tokenized.attentionMask,
    );
  }

  @override
  @nonVirtual
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_graphOpening) await closeGraph();
  }
}
