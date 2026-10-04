// The engine-specific forward-pass seam for the runtime-agnostic embedder
// (design: docs/superpowers/specs/2026-08-17-flutter-gemma-onnx-engine-design.md
// §2, §11 D3/D4).
//
// `flutter_edge_ai_embeddings` owns tokenization and TaskType prefixing;
// pooling/normalization is `pooling.dart` beside this file. The ONLY thing an
// inference
// engine (LiteRT-LM, ONNX, ...) supplies is the raw forward pass over
// already-tokenized input. This file defines that seam.
//
// Lifecycle is ASYNC (`Future<void> load()`, not a sync constructor) because
// every real forward-pass implementation loads/compiles a native model from
// disk — e.g. `litert_embedding_core.dart`'s `EmbeddingCore.load()` takes
// ~570-780ms. A sync API would force that work onto whichever isolate calls
// the constructor; async lets an off-main-isolate host (see
// `litert_embedding_worker.dart`'s pattern) `await` it inside the worker.

import 'tokenizer_adapter.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;

/// One engine's forward-pass implementation.
///
/// An instance is built and lives inside a single isolate — see
/// [ForwardPassDescriptor] for how the *ability to build one* crosses an
/// isolate boundary. Once built, the SAME isolate that called [load] must be
/// the one that calls [run] and [close]: the concrete implementation owns
/// native (FFI) handles that cannot themselves cross isolates.
abstract class EmbeddingForwardPass {
  /// Load/compile the model. Heavy (hundreds of ms for a real native
  /// engine) — call once, then reuse for many [run] calls.
  Future<void> load();

  /// Run one forward pass over already-tokenized input.
  ///
  /// [tokenIds] is required. [attentionMask] / [tokenTypeIds] are optional —
  /// BERT-style models (WordPiece tokenizers) use them; SentencePiece/
  /// Gemma-style models typically don't and may ignore them.
  Future<ForwardResult> run({
    required List<int> tokenIds,
    List<int>? attentionMask,
    List<int>? tokenTypeIds,
  });

  /// Free native resources. Must be safe to call multiple times.
  Future<void> close();

  /// Output embedding dimension. Valid only after [load] completes.
  int get outputDimension;

  /// Sequence length the model was compiled/loaded for, if the engine knows
  /// it ahead of a forward pass (e.g. LiteRT auto-detects it from the
  /// compiled model's input tensor layout). `null` when the engine has no
  /// fixed input length to report (e.g. a dynamic-shape ONNX graph) — the
  /// worker's `_Ready` handshake falls back to `-1` in that case.
  int? get inputSequenceLength => null;

  /// Overrides [ForwardPassDescriptor.outputContract] once the engine knows
  /// its actual output layout — only knowable for ONNX after the session
  /// opens (output names live in the graph), but the descriptor is built
  /// before that (design D-T2). The worker resolves the effective contract
  /// as `pass.outputContract ?? descriptor.outputContract`.
  ///
  /// `null` (the default) means "the descriptor's value is authoritative" —
  /// LiteRT never overrides; its descriptor always declares `pooledFinal`
  /// and this getter stays `null`.
  EmbeddingOutputContract? get outputContract => null;
}

/// How to turn a [ForwardResult] into the final embedding vector.
///
/// The dispatch MUST be on this enum, never on [ForwardResult.shape] — a
/// rank-2 `[1, dim]` result from an engine that already pools+normalizes
/// internally (LiteRT) must NOT be routed through `meanPoolAndNormalize` a
/// second time (that would silently add an L2-normalize the LiteRT path
/// never had — see this file's module doc / the embedder decoupling plan's
/// Invariant I0). `meanPoolAndNormalize` lives in `pooling.dart` and is
/// applied by the generalized worker (`embedding_worker.dart`) based on this
/// contract.
enum EmbeddingOutputContract {
  /// [ForwardResult] IS the final embedding already — copy `values` verbatim
  /// (`List<double>.of(result.values)`). No pooling, no normalization.
  /// Used by LiteRT: whatever pooling/normalization exists is baked into the
  /// compiled `.tflite` graph and is opaque to Dart.
  pooledFinal,

  /// [ForwardResult] is `[1, seq, dim]` per-token hidden states. Apply
  /// `meanPoolAndNormalize` (mean-pool over `seq`, then L2-normalize) to get
  /// the final embedding. Used by engines (e.g. ONNX) that expose raw
  /// hidden states rather than a pooled output.
  tokenLevel,
}

/// Raw forward-pass output: a flat, row-major buffer plus its tensor shape.
///
/// [shape] is one of two layouts a forward pass can hand back — see
/// `pooling.dart`'s `meanPoolAndNormalize` for how each is turned into a
/// single embedding vector:
///  - `[1, dim]` — already pooled by the engine (e.g. a LiteRT compiled
///    model whose graph itself produces one vector per input). Treated as a
///    pass-through.
///  - `[1, seq, dim]` — per-token hidden states. Mean-pooled over the `seq`
///    axis (optionally respecting an attention mask) before normalizing.
class ForwardResult {
  const ForwardResult({
    required this.values,
    required this.shape,
    this.attentionMask,
  });

  /// Flat, row-major buffer. `values.length == shape.reduce((a, b) => a * b)`.
  final List<double> values;

  /// Tensor shape, e.g. `[1, dim]` or `[1, seq, dim]`.
  final List<int> shape;

  /// The *effective* attention mask over this result's `seq` axis, when the
  /// pass knows one (design D-T3's silent-regression fix). A pass that pads
  /// a fixed-shape graph MUST pad `tokenIds`/mask/`tokenTypeIds` together and
  /// echo the padded mask here, so the worker's masked mean-pool excludes
  /// exactly the padding it added — never the caller-supplied
  /// `run(attentionMask:)`, which describes the UNPADDED input. A pass over
  /// a dynamic-shape graph (no padding) may pass the input mask through
  /// unchanged or omit it — the worker falls back to the request's mask.
  final List<int>? attentionMask;
}

/// Factory that builds an [EmbeddingForwardPass] for a given on-disk model
/// path.
///
/// MUST be a top-level or static function — a genuine tear-off — and never a
/// closure or bound instance method. This is enforced by convention (not by
/// the type system: `Function(String)` can't statically distinguish a
/// tear-off from a closure), so implementers must follow it deliberately.
///
/// **Why it must be a tear-off, not a closure or a registry:**
/// [ForwardPassDescriptor] carrying this factory is sent through a
/// [SendPort] into a freshly [Isolate.spawn]'d isolate (see
/// `IsolateForwardHost` in engine packages, and
/// `test/forward_pass_isolate_test.dart` for the boundary proof). Isolates
/// do not share mutable state — no shared statics, no captured closures —
/// they only share the compiled *code* of the program (in AOT, the same
/// binary; in JIT, the same loaded kernel). Dart's isolate messaging allows
/// sending values that *denote* code rather than *capture* it:
///  - A top-level/static function tear-off denotes "the function declared at
///    this source location." That declaration exists, unchanged, in the
///    fresh isolate's copy of the program, so the receiving isolate can
///    invoke it immediately — nothing needs to be reconstructed.
///  - A closure over local/instance state is either rejected outright by
///    isolate messaging, or (if it captured only sendable values) would
///    silently NOT carry the mutable object identity the closure's author
///    expected — a correctness trap.
///  - A runtime registry (e.g. a `Map<String, EmbeddingForwardPassFactory>`
///    populated via some `register()` call in the main isolate) is equally
///    unusable: a freshly spawned isolate starts from the *initial* static
///    state of the program, so the registry would be empty inside the
///    worker no matter what the main isolate had registered into it before
///    spawning — top-level/static state is NOT shared across isolates,
///    only re-initialized identically in each.
typedef EmbeddingForwardPassFactory =
    EmbeddingForwardPass Function(String modelPath);

/// Sendable description of "which engine, which model" that crosses an
/// isolate boundary so the receiving isolate can build its own
/// [EmbeddingForwardPass] locally. FFI handles/pointers themselves can never
/// cross isolates — only this descriptor (plain data + a code reference)
/// does; see [EmbeddingForwardPassFactory] for why [factory] must be a
/// top-level/static tear-off.
class ForwardPassDescriptor {
  const ForwardPassDescriptor({
    required this.engineTag,
    required this.modelPath,
    required this.factory,
    required this.tokenizerFactory,
    required this.outputContract,
    this.activeBackend,
  });

  /// Human-readable engine identifier for diagnostics (e.g. `'LiteRT-LM'`,
  /// `'ONNX'`). Not used for dispatch — [factory] already IS the dispatch;
  /// no receiving isolate ever switches on this string.
  final String engineTag;

  /// On-disk path to the model file, already resolved by core before this
  /// descriptor is built (install-vs-runtime separation — see
  /// `RuntimeConfig.modelPath`).
  final String modelPath;

  /// Top-level factory tear-off (see [EmbeddingForwardPassFactory]) that
  /// builds the forward pass inside the receiving isolate.
  final EmbeddingForwardPassFactory factory;

  /// Top-level factory tear-off (see [EmbeddingTokenizerFactory] in
  /// `tokenizer_adapter.dart`) that builds the tokenizer inside the
  /// receiving isolate. Model-family logic (WordPiece vs SentencePiece), not
  /// engine logic — kept alongside [factory] on the same descriptor because
  /// both cross the same isolate boundary together (design D-T1).
  final EmbeddingTokenizerFactory tokenizerFactory;

  /// The backend this engine's forward pass actually runs on, surfaced by
  /// [EmbeddingModel.activeBackend].
  ///
  /// Deliberately NOT defaulted to CPU. A CPU default would let the next engine
  /// — including one that really does use an accelerator — be reported as CPU
  /// by omission, which is the same "accepted the argument and said nothing"
  /// defect this field exists to answer. The engine that built the pass is the
  /// only thing that knows, so it is the only thing that can say.
  ///
  /// Optional rather than required, because required would be a break no
  /// version constraint can guard. Core must not depend on an engine package,
  /// so it cannot declare a floor on one: a newer core with an older engine
  /// would simply stop compiling, and nothing in either pubspec could have
  /// warned. Omitting it answers `null` — "this engine did not say" — which is
  /// honest in a way a CPU default is not.
  ///
  /// Every engine that builds a pass in the embedding worker does know its
  /// backend, so both in-tree engines pass it explicitly. The web arms never
  /// construct a descriptor at all — they build their own [EmbeddingModel] —
  /// so `null` here is not the web case.
  final PreferredBackend? activeBackend;

  /// How the worker must turn this engine's [ForwardResult] into the final
  /// embedding — see [EmbeddingOutputContract]. A plain enum value, so it
  /// stays trivially sendable across the isolate boundary alongside the rest
  /// of this descriptor.
  final EmbeddingOutputContract outputContract;
}
