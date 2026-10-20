import 'dart:async';

import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart'
    show CancelToken;
import 'package:meta/meta.dart' show experimental, nonVirtual;

import '../decision/decider.dart' show Decider;
import '../decision/decider_method.dart';
import '../decision/decider_option.dart';
import '../decision/embedding_decider.dart';
import 'embedding_exceptions.dart';
import 'embedding_input.dart';
import 'embedding_modality.dart';
import 'task_type.dart';

/// An embedding model, as returned by `FlutterEdgeAi.getActiveEmbedder()`.
///
/// Core builds every model an app receives: it hosts the engine's pass, checks
/// each request before it is sent, and owns the close. Extend this class only
/// for test fakes — `final class FakeEmbedder extends EmbeddingModel` (add
/// `with CloseNotifier` from `engine.dart` for close listeners) implementing
/// [dimension], [isClosed], [embed], [addCloseListener] and [close].
///
/// `base`: outside core it can be extended (by a `base`, `final` or `sealed`
/// class) but not implemented, so `implements EmbeddingModel` — and therefore
/// a mockito/mocktail mock of it — does not compile. A member added here in a
/// later release then reaches every fake through its superclass instead of
/// breaking it.
abstract base class EmbeddingModel {
  /// Length of every vector this model returns. Known when the model is
  /// returned: every engine loads eagerly.
  int get dimension;

  /// What this model accepts: the media declared at load (and confirmed by
  /// the engine), plus text when the model has a text tower. A request
  /// carrying anything else fails with `EmbeddingModalityNotLoadedException`.
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};

  /// Longest input in tokens — task prefix, BOS and EOS included — as the
  /// loaded engine can accept it, including any configured context or batch
  /// limit. Null when the engine cannot establish a limit. Longer inputs fail with `EmbeddingInputTooLongException`; they
  /// are never truncated. Null does not mean unlimited.
  int? get maxInputTokens => null;

  /// Backend this embedder actually uses, when known — the counterpart of
  /// `InferenceModel.activeBackend`, and the answer to
  /// `getActiveEmbedder(preferredBackend:)` that survives a release build.
  ///
  /// Providers report the loaded accelerator. CPU-only LiteRT and ONNX
  /// providers answer CPU: LiteRT's int4 GPU delegate returns all-zero
  /// vectors, and native ONNX uses no GPU execution provider.
  /// EmbeddingGemma 2 per-SoC `.litertlm` bundles can
  /// answer NPU. GPU-capable providers can report GPU after loading.
  ///
  /// On web, EmbeddingGemma 2 `.litertlm` reports GPU or refuses to load.
  /// LiteRT.js and ONNX web do not report their selection and leave this null. Treat
  /// null as unknown, never as CPU.
  PreferredBackend? get activeBackend => null;

  /// Whether [close] has been called, or the model can no longer be used
  /// because its worker exited. Abstract since 2.3.0 (2.2 defaulted it to
  /// false).
  bool get isClosed;

  /// The vector for [input].
  ///
  /// [taskType] prefixes TEXT parts only; [TaskType.none] embeds the text raw.
  ///
  /// Every error is delivered as a FAILED FUTURE, never thrown synchronously:
  /// `EmbedderClosedException`, `EmbeddingModalityNotLoadedException`,
  /// `UnsupportedEmbeddingCombinationException`,
  /// `EmbeddingFormatNotSupportedException`,
  /// `EmbeddingInputTooLongException`, `EmbeddingEngineException`.
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  });

  /// The vectors for [inputs], in input order.
  ///
  /// The first failure fails the call. [cancelToken] stops sending and fails
  /// the call with `EmbeddingCancelledException`; partial results are
  /// discarded. Text and media alike.
  ///
  /// The models core returns also validate every input before the first is
  /// sent, and keep at most two requests of the call outstanding; requests
  /// already outstanding when the call fails or is cancelled finish and are
  /// dropped. This default body — for fakes — embeds one input at a time.
  Future<List<List<double>>> embedAll(
    List<EmbeddingInput> inputs, {
    required TaskType taskType,
    CancelToken? cancelToken,
  }) async {
    final out = <List<double>>[];
    for (final input in inputs) {
      if (cancelToken?.isCancelled ?? false) {
        throw const EmbeddingCancelledException();
      }
      out.add(await embed(input, taskType: taskType));
    }
    return out;
  }

  /// Register a callback fired once when this model is closed — by [close],
  /// or because its worker exited. Core's embedder cache evicts through it.
  void addCloseListener(void Function() listener);

  /// Closes the model. Idempotent. Requests not yet started fail with
  /// `EmbedderClosedException`; the one in flight finishes; then the engine is
  /// released. Waits as long as that takes — nothing is ever killed, since a
  /// killed worker never frees its native model.
  Future<void> close();

  /// A decider that picks one of [options] for an input, or abstains.
  ///
  /// Every option's inputs — its description, then its examples — are
  /// embedded once, here, with [TaskType.sentenceSimilarity] (the prefix every
  /// compared input gets), and fitted by [method]: centroids, plus the linear
  /// layer for [DeciderMethod.linear]. [calibration] sets when the decider
  /// abstains; the default cross-fit needs two inputs per option. A
  /// `choose` then costs one [embed] and a dot product per option.
  ///
  /// The decider borrows this model and never closes it. When a model
  /// `FlutterEdgeAi.getActiveEmbedder` returned is closed — core replaced it
  /// (other media, another backend, a re-install), its worker died, or the
  /// app closed it — the decider's next `choose` asks core for the active
  /// embedder again, with the backend and media this model was built with
  /// (so it may load the model again), and retries there when that
  /// embedder's space id is the decider's; another space fails with
  /// `DeciderSpaceMismatchException`. On any other model `choose` fails with
  /// `EmbedderClosedException` and the decider reports `isClosed`: reload it
  /// with [loadDecider] from its `toArtifact()` — no re-embedding.
  ///
  /// [embedderId] names the model's weights in the decider's embedding-space
  /// id. A model `FlutterEdgeAi.getActiveEmbedder` returned is named by its
  /// installed files unless one is given: their names and, natively, their
  /// sizes in bytes — file names and sizes, not the bytes themselves (on web
  /// the names alone). Any other model (a test fake, a custom subclass)
  /// needs an [embedderId], and so does a model whose [activeBackend] is
  /// null (LiteRT.js and ONNX on web): without a backend to tell WebGPU from
  /// WASM, the call is refused with [ArgumentError]. An [embedderId]
  /// REPLACES the installed-file guard: the caller owns the identity, and
  /// with a null [activeBackend] it must name the backend too. The space id
  /// also holds the dimension, [activeBackend] and the task prefix, so a
  /// decider fitted on the CPU file is never loaded onto an NPU bundle's
  /// vectors, and — when an option example or a labelled request is an
  /// image — the engine's image budget (EmbeddingGemma 2: 140 or 70 tokens
  /// per image), so image vectors of one budget never meet the other's.
  ///
  /// [cancelToken] stops the embedding of the options and the fit (natively
  /// the fit's isolate is killed; on web the fit stops at its next yield);
  /// the call then fails with `DeciderCancelledException` and returns no
  /// decider.
  ///
  /// [onProgress] counts the inputs this call embeds — each option's
  /// description and examples, then the rows of
  /// [EmbeddingDeciderCalibration.fromLabelled] — as `(done, total)`:
  /// `(0, total)` first, then once per input as its vector comes back, ending
  /// at `(total, total)`. It does not cover the fit that follows: a
  /// [DeciderMethod.linear] fit at 150 options takes seconds after the last
  /// call. A throw from it fails the call.
  ///
  /// Errors arrive as a FAILED FUTURE: [ArgumentError] for options it cannot
  /// use (none, duplicate ids, an option with nothing to embed, a calibration
  /// these options or labelled rows cannot support) and for
  /// [DeciderMethod.optionScoring], an `InferenceModel` method; [StateError]
  /// for a vector that is not finite or not [dimension] long and for a fit
  /// that is not finite (an option whose inputs cancel out); and this model's
  /// own failures — an over-long input is `EmbeddingInputTooLongException`,
  /// never truncated; an input's failure names its option and input, with its
  /// type and fields kept.
  ///
  /// Experimental: may change in a minor release while the API settles.
  @experimental
  @nonVirtual
  Future<Decider> createDecider({
    required List<DeciderOption> options,
    DeciderMethod method = DeciderMethod.centroid,
    EmbeddingDeciderCalibration calibration =
        const EmbeddingDeciderCalibration.crossFit(),
    String? embedderId,
    CancelToken? cancelToken,
    void Function(int done, int total)? onProgress,
  }) => createEmbeddingDecider(
    this,
    options: options,
    method: method,
    calibration: calibration,
    embedderId: embedderId,
    cancelToken: cancelToken,
    onProgress: onProgress,
  );

  /// The decider stored by `Decider.toArtifact()`, on this model, without
  /// embedding anything.
  ///
  /// Fails with `DeciderSpaceMismatchException` when [artifact] was fitted in
  /// another embedding space than this model's (another model file,
  /// dimension, backend or task prefix — see [createDecider] for
  /// [embedderId]), and with [FormatException] for an artifact this release
  /// cannot read.
  ///
  /// Experimental: may change in a minor release while the API settles.
  @experimental
  @nonVirtual
  Future<Decider> loadDecider(
    Map<String, Object?> artifact, {
    String? embedderId,
  }) => loadEmbeddingDecider(this, artifact, embedderId: embedderId);
}
