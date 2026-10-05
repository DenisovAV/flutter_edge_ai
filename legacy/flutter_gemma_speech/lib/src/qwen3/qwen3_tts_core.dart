// Qwen3-TTS talker/MTP/codec graph loader + talker KV-cache prefill.
//
// This file (plus `qwen3_prompt.dart`, `qwen3_sampler.dart`,
// `qwen3_talker_layout.dart`, `qwen3_tables.dart`) ports
// `google-ai-edge/litert-samples`' `Qwen3TtsPipeline` reference recipe
// (`samples/litert/text_to_speech_lm/python/qwen3_tts_pipeline.py`), a
// frozen snapshot of which is vendored at `tool/qwen3/qwen3_tts_pipeline.py`
// for citation/reproducibility. Citations below name the recipe's Python
// symbols (class/method/constant), NOT line numbers — the vendored copy
// carries an extra provenance-comment line versus upstream, so any :NNN
// anchor would silently drift; see that file's own header comment.
//
// `Qwen3TtsCore.load` opens the 3 LiteRT graphs that make up the Qwen3-TTS
// pipeline (`talker_int4.tflite`, `mtp_fp32.tflite`,
// `codec_decoder_fp32.tflite`), the host embedding tables + text-projection
// MLP (`Qwen3Tables`), and the Qwen2 byte-level BPE text encoder
// (`Qwen2BpeEncoder`); asserts the talker's graph layout against the frozen
// `TalkerLayout` constants; and introspects the MTP/codec graphs' fixed-size
// inputs (`mtpCacheLen`, `mtpKvShape`, `codecChunk`) so the MTP inner loop
// ([Qwen3TtsCore.runMtp]) and the codec sliding-window decode
// ([Qwen3TtsCore.decodeCodes]) don't need to re-open the graphs to read
// them. Ports the constructor of `Qwen3TtsPipeline.__init__`.
//
// [Qwen3TtsCore.runPrefill] ports `Qwen3TtsPipeline._run_prefill`:
// right-pads the (<=32-row) prompt embedding into the talker's fixed
// 32-row `prefill_32` signature, builds the matching causal `mask`, runs
// it against an all-zero initial KV cache (`Qwen3TtsPipeline.synthesize`'s
// KV-dict init), and returns the 56 filled KV tensors — this initializes
// the KV cache the decode loop ([Qwen3TtsCore.runDecode]) threads forward
// one step at a time.
//
// [Qwen3TtsCore.runDecode] ports `Qwen3TtsPipeline._run_decode`: builds
// the one-row causal `mask` (`mask[...,:pos+1] = 0`, else `qwen3NegInf`)
// for the current KV-cache write position, runs the talker's `decode`
// signature against the threaded-forward KV cache, and splits the
// `[1,1,4096]` logits output into codebook-0 logits (`[:3072]`) and the
// hidden-state tail (`[3072:]`) consumed by [runMtp]. This is the
// correctness milestone for the whole talker path: prefill -> decode ->
// KV threading -> logit split -> cb0 scoring must reproduce the PyTorch
// reference's frame-0 cb0 exactly (see `qwen3_talker_decode_test.dart`'s
// golden gate).
//
// FFI style + graph load/run machinery: same as `TtsCore`/`SttCore` — see
// `litert_graph.dart`'s file header for the create -> run -> lock(Read) ->
// copy-through-locked-ptr -> unlock -> destroy sequence this delegates to.
// [Qwen3TtsCore.runPrefill]/[Qwen3TtsCore.runDecode] are not truly public
// API (no v1 consumer outside this package calls them directly) but are
// deliberately not name-mangled private either, so `qwen3_prefill_test.dart`
// / `qwen3_talker_decode_test.dart` — different libraries — can drive them
// directly; annotated `@visibleForTesting` to say so, mirroring
// `TtsCore.planMelWindows`/`concatSegments`.
//
// [Qwen3TtsCore.runMtp] ports `Qwen3TtsPipeline._run_mtp`: the 16-step
// MTP inner loop that predicts the 15 residual codebooks of one frame from
// the talker's hidden state ([runDecode]'s `hidden`) + the already-picked
// codebook-0 token. The MTP graph is single-signature (`args_0..4` ->
// `output_0..2`, no prefill/decode split like the talker); [load]
// introspects `output_0`'s shape (the 15-head residual-logit tensor,
// `[15, vocab]`) via the bulk `getOutputTensorLayouts` accessor (there is
// no per-output-index accessor — see [_readOutputShapes]'s doc) so this
// file never hardcodes the residual vocabulary size.
//
// [Qwen3TtsCore.decodeCodes] ports `Qwen3TtsPipeline._decode_codes`: turns
// the accumulated `[T, 16]` codec frames (codebook-0 + the 15 MTP
// residuals, one row per talker frame) into 24 kHz PCM by running them
// through the codec-decoder graph in fixed-size [codecChunk]-frame
// windows, each carrying 25 frames of LEFT CONTEXT from the previous
// window (`ctx = 25`) that is decoded but then cropped back out of the
// emitted audio — the codec is a small causal-ish conv stack, not a fully
// streaming one, so re-feeding a tail of already-seen frames as context on
// every step is what keeps chunk boundaries from producing audible seams.
// Every codec call decodes exactly [codecChunk] frames' worth of PCM
// (`[1, 1, codecChunk * _upsampleFactor]`) regardless of how many of the
// window's rows are real (the rest of `buf` is left as zero-padding); only
// the `window.length`-worth of frames actually fed are kept from each
// call's output.
//
// [Qwen3TtsCore.synthesize] ports `Qwen3TtsPipeline.synthesize` verbatim —
// the host-orchestrated, end-to-end AR loop that ties [runPrefill]/
// [runDecode]/[runMtp]/[decodeCodes] together: tokenize the
// chat-template-wrapped text (`Qwen2BpeEncoder`), build the prompt
// embeddings (`Qwen3Prompt.build`), prefill + one initial decode step,
// then loop — score + pick cb0 ([buildSuppress]/[applyCb0Scoring]/
// [pickGreedy]/[pickSampled], EOS breaks), run the MTP inner loop for the
// 15 residuals, accumulate the frame, assemble the next step's talker
// embedding (codec-token embedding of cb0 plus all 15 MTP-residual
// embeddings plus the next streamed-text/pad row), and decode one more
// talker step — until EOS or [maxFrames]. This is the culmination
// correctness gate for the whole pipeline: fp32-greedy waveform
// correlation ≈ 1.0 vs the PyTorch reference (`qwen3_synthesize_test.dart`).
// [Qwen3TtsCore.synthesizePcm16] is the same loop, returning int16 LE mono
// PCM instead of `[-1, 1]` float samples, for the isolate worker
// (`_runQwen3Worker` in `tts_worker.dart`).

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:meta/meta.dart' show visibleForTesting;
// Public, native-only bindings library (not the package barrel) — see the
// equivalent comment in `tts_core.dart`/`stt_core.dart` for why this import
// (not the `if (dart.library.ffi)` barrel) is correct in a native-only file.
import 'package:flutter_gemma_litertlm/litert_bindings.dart';

import '../litert/litert_graph.dart';
import 'qwen2_bpe_encoder.dart';
import 'qwen3_prompt.dart';
import 'qwen3_sampler.dart'
    show applyCb0Scoring, buildSuppress, pickGreedy, pickSampled;
import 'qwen3_tables.dart';
import 'qwen3_talker_layout.dart';

/// Mask fill value for "not yet attendable" KV-cache positions — matches
/// `qwen3_tts_pipeline.py`'s module-level `_NEG_INF = -1e9` (used by both
/// `_run_prefill` and `_run_decode`'s causal masks).
const double qwen3NegInf = -1e9;

/// Codec-frame width — codebook-0 + the 15 MTP residuals — matches
/// `qwen3_tts_pipeline.py`'s module-level `_NUM_CODE_GROUPS = 16`. Used by
/// [Qwen3TtsCore.decodeCodes] to size + transpose the codec's `[1, 16,
/// chunk]` input.
const int _numCodeGroups = 16;

/// Codec-frame -> PCM-sample upsample factor — matches
/// `qwen3_tts_pipeline.py`'s module-level `_UPSAMPLE = 1920` (24 kHz output
/// at the talker's 12.5 Hz frame rate). Used by [Qwen3TtsCore.decodeCodes]
/// to size the codec's output and crop left-context samples out of it.
const int _upsampleFactor = 1920;

/// Number of MTP residual codebooks — matches `qwen3_tts_pipeline.py`'s
/// module-level implicit `15` (the `arange(15)` in [Qwen3TtsCore.synthesize]'s
/// embed-accumulation step, `qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize`). Distinct from
/// [_numCodeGroups] (`16` = cb0 + these 15 residuals).
const int _mtpResidualGroups = 15;

/// Codec end-of-sequence token id — matches `qwen3_tts_pipeline.py`'s
/// module-level `_CODEC_EOS = 2150`. Defined privately here (not imported
/// from `qwen3_sampler.dart`, where an identical private copy backs
/// [buildSuppress]/[applyCb0Scoring]) — same "each file owns its own frozen
/// token constants" convention `qwen3_prompt.dart` already follows for its
/// `_codecPad`/`_codecBos`/etc.
const int _codecEos = 2150;

/// Left-context frame count [Qwen3TtsCore.decodeCodes]'s sliding window
/// re-feeds from the previous window on every step but one (`ctx`/`c` in
/// `qwen3_tts_pipeline.py Qwen3TtsPipeline._decode_codes` — see this file's header). [codecChunk]
/// must exceed this or [Qwen3TtsCore.decodeCodes]'s window advance
/// (`codecChunk - c`) never makes progress — checked at [Qwen3TtsCore.load]
/// time, see the guard there.
const int _codecLeftContext = 25;

String _artifactPath(Map<String, String> artifactPaths, String file) =>
    artifactPath(artifactPaths, file, owner: 'Qwen3TtsCore');

/// Reads one input tensor's full shape via the index-based
/// `getInputTensorLayout` accessor — the only per-tensor introspection the
/// bound LiteRT C API offers (see `TalkerLayout`'s file header for the same
/// caveat re: no name-based or bulk-input accessor).
List<int> _readInputShape(
  LiteRtBindings bindings,
  LiteRtCompiledModel graph,
  int signatureIndex,
  int inputIndex,
  String label,
) {
  final layout = LiteRtLayoutView.calloc();
  try {
    bindings
        .getInputTensorLayout(graph, signatureIndex, inputIndex, layout.pointer)
        .check(
          'LiteRtGetCompiledModelInputTensorLayout($label, '
          'sig=$signatureIndex, in=$inputIndex)',
        );
    return [for (var i = 0; i < layout.rank; i++) layout.dimension(i)];
  } finally {
    layout.free();
  }
}

/// Reads the first [count] output tensor shapes for [graph]'s
/// [signatureIndex] via the BULK `LiteRtGetCompiledModelOutputTensorLayouts`
/// accessor — unlike [_readInputShape]'s per-index `getInputTensorLayout`,
/// there is no per-output-index accessor (see `TalkerLayout`'s file header
/// for the same gap on the talker graph): the C API always fills
/// `num_layouts` entries starting at output 0, so reading output N's shape
/// means reading outputs `0..N` together into one contiguous native array.
/// Only used for the MTP graph at [Qwen3TtsCore.load] time, where [count] is
/// the small, fixed `3` (`output_0` logits, `output_1`/`output_2` k/v) — see
/// this file's header.
List<List<int>> _readOutputShapes(
  LiteRtBindings bindings,
  LiteRtCompiledModel graph,
  int signatureIndex,
  int count,
  String label,
) {
  final shapes = <List<int>>[];
  // LiteRtLayout has one layout on every compiler (see litert_bindings.dart),
  // so the array stride is the same on Windows too.
  final layouts = calloc<LiteRtLayoutPosix>(count);
  try {
    bindings
        .getOutputTensorLayouts(
          graph,
          signatureIndex,
          count,
          layouts.cast(),
          false,
        )
        .check('LiteRtGetCompiledModelOutputTensorLayouts($label)');
    for (var i = 0; i < count; i++) {
      final s = (layouts + i).ref;
      final rank = s.rankAndHasStrides & 0x7f;
      shapes.add([for (var d = 0; d < rank; d++) s.dimensions[d]]);
    }
  } finally {
    calloc.free(layouts);
  }
  return shapes;
}

/// `true` iff [a] and [b] have the same length and elements — a plain
/// `List<int>` equality check (no `package:collection` dependency in this
/// package; see `pubspec.yaml`).
bool _shapeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Synchronous native core for the Qwen3-TTS talker/MTP/codec pipeline. NOT
/// safe to share across isolates — the FFI handles it holds are owned by the
/// isolate that called [load]. Mirrors `TtsCore`/`SttCore`'s shape.
class Qwen3TtsCore {
  Qwen3TtsCore._({
    required this._bindings,
    required this._environment,
    required this._talker,
    required this._mtp,
    required this._codec,
    required this._tables,
    required this._encoder,
    required this._kvShapes,
    required this.mtpCacheLen,
    required this.mtpKvShape,
    required this._mtpLogitsShape,
    required this._mtpResidualVocab,
    required this.codecChunk,
  });

  final LiteRtBindings _bindings;
  final LiteRtEnvironment _environment;
  final LoadedGraph _talker;
  final LoadedGraph _mtp;
  final LoadedGraph _codec;

  /// Host embedding tables + text-projection MLP — used by the decode loop
  /// (`runDecode`/`synthesize`) to turn codec-token / MTP-residual /
  /// text-token ids into 1024-d talker-space embeddings. Not read by
  /// [runPrefill] (the caller supplies already-embedded prompt rows, e.g. via
  /// `Qwen3Prompt.build`), but loaded here so a single [Qwen3TtsCore] owns
  /// every table the full pipeline needs.
  final Qwen3Tables _tables;

  /// Qwen2 byte-level BPE text encoder — used by [synthesize] to turn raw
  /// text into token ids ahead of `Qwen3Prompt.build`.
  final Qwen2BpeEncoder _encoder;

  /// Each of the talker's 56 KV tensor shapes (`kv_cache_{k,v}_{0..27}`,
  /// positional), read once at load time from the `decode` signature's
  /// inputs 3..58 — identical across all 3 talker signatures (see
  /// `TalkerLayout`'s file header).
  final List<List<int>> _kvShapes;

  /// MTP graph's KV-cache capacity — the last dim of its `args_2` (mask)
  /// input. Expected 17 (16 MTP steps + 1), per the C1 spike.
  final int mtpCacheLen;

  /// MTP graph's `args_3` (k-cache) input shape, read once at load time.
  final List<int> mtpKvShape;

  /// MTP graph's `output_0` (residual-head logits) shape, read once at load
  /// time via [_readOutputShapes] — expected `[15, vocab]` (a leading `1`
  /// batch dim, `[1, 15, vocab]`, is also tolerated; see [load]). Used
  /// verbatim as [runMtp]'s `outputShapes[0]` on every step.
  final List<int> _mtpLogitsShape;

  /// Residual-codebook vocabulary size — the last dim of [_mtpLogitsShape].
  /// Read (not hardcoded) so a future model revision that reshapes the MTP
  /// head fails loud at load time (see [load]) instead of [runMtp] silently
  /// misreading which slice of `output_0` is head `t-1`.
  final int _mtpResidualVocab;

  /// Codec-decoder graph's `args_0` input's last dim — its fixed
  /// frame-chunk width.
  final int codecChunk;

  bool _disposed = false;

  /// The codec [frames] (row = `[cb0, ...residual]`, one per talker AR
  /// step) generated by the most recent [synthesize]/[synthesizePcm16]
  /// call — empty until the first call. Exposed for inspection (e.g. the
  /// golden test's frame-agreement diagnostic against the PyTorch
  /// reference's `frames.json`); overwritten, not accumulated, on every
  /// call.
  List<List<int>> get lastFrames => _lastFrames;
  List<List<int>> _lastFrames = const [];

  /// Output sample rate (Hz) — fixed for this model family.
  int get sampleRate => 24000;

  /// Opens `LiteRtBindings`, compiles the talker/MTP/codec graphs (see this
  /// file's header), asserts the talker's layout against the frozen
  /// [TalkerLayout] constants, reads the talker's 56 KV tensor shapes,
  /// introspects [mtpCacheLen]/[mtpKvShape]/[codecChunk], and loads the host
  /// tables + text encoder. Heavy — call once, from a background isolate.
  /// [artifactPaths] is filename -> on-disk-path for the model bundle
  /// (talker_int4.tflite, mtp_fp32.tflite, codec_decoder_fp32.tflite,
  /// tokenizer.json, and the 4 `Qwen3Tables` members).
  ///
  /// [talkerFileName] selects which talker artifact to load — defaults to
  /// the int4 runtime name (`talker_int4.tflite`) so every existing caller
  /// is unaffected. The golden cb0 test
  /// (`qwen3_talker_decode_test.dart`) passes `'talker_fp32.tflite'`
  /// instead: the fixtures in `test/golden/qwen3/` were generated by
  /// `gen_qwen3_goldens.py` against the fp32 talker
  /// (`Qwen3TtsPipeline(..., talker_file='talker_fp32.tflite')`) — int4 is
  /// NOT bit-exact vs the PyTorch reference, so only fp32 can reproduce the
  /// golden frame-0 cb0.
  static Future<Qwen3TtsCore> load({
    required Map<String, String> artifactPaths,
    PreferredBackend? backend,
    String talkerFileName = 'talker_int4.tflite',
  }) async {
    final bindings = LiteRtBindings.open();
    final accelerator = acceleratorFor(backend);

    // Track handles as they're created so a failure partway through (e.g.
    // the codec graph fails to compile after the talker/MTP already
    // loaded) frees everything already allocated instead of leaking it —
    // the LiteRT native heap is process-global and is NOT reclaimed by the
    // isolate dying. Mirrors `TtsCore.load`, generalized to 3 graphs + the
    // tables' open file handle.
    LiteRtEnvironment? environment;
    final loadedGraphs = <LoadedGraph>[];
    Qwen3Tables? tables;
    try {
      final envPtr = calloc<LiteRtEnvironment>();
      bindings
          .createEnvironment(0, nullptr, envPtr)
          .check('LiteRtCreateEnvironment');
      environment = envPtr.value;
      calloc.free(envPtr);

      final talker = loadLiteRtGraph(
        bindings,
        environment,
        _artifactPath(artifactPaths, talkerFileName),
        accelerator,
      );
      loadedGraphs.add(talker);

      final mtp = loadLiteRtGraph(
        bindings,
        environment,
        _artifactPath(artifactPaths, 'mtp_fp32.tflite'),
        accelerator,
      );
      loadedGraphs.add(mtp);

      final codec = loadLiteRtGraph(
        bindings,
        environment,
        _artifactPath(artifactPaths, 'codec_decoder_fp32.tflite'),
        accelerator,
      );
      loadedGraphs.add(codec);

      // Fails loud at load time if a future model revision has drifted from
      // the C1-spike-frozen talker layout (see `TalkerLayout`'s file
      // header) — do this before trusting any KV-shape introspection below.
      TalkerLayout.assertLayout(bindings, talker.compiledModel);

      // KV tensor shapes are identical across all 3 talker signatures (per
      // TalkerLayout's file header) — read once from `decode`, inputs
      // 3..58 (`kv_cache_{k,v}_{0..27}`, positional).
      final kvShapes = [
        for (var i = 0; i < TalkerLayout.numKvTensors; i++)
          _readInputShape(
            bindings,
            talker.compiledModel,
            TalkerLayout.decodeSig,
            3 + i,
            'talker.kv_cache[$i]',
          ),
      ];

      // MTP/codec are each single-signature graphs (signature index 0);
      // their inputs are positional `args_N` == input index N (recipe's
      // `Qwen3TtsPipeline.__init__`).
      final mtpMaskShape = _readInputShape(
        bindings,
        mtp.compiledModel,
        0,
        2,
        'mtp.args_2 (mask)',
      );
      final mtpCacheLen = mtpMaskShape.last;
      final mtpKvShape = _readInputShape(
        bindings,
        mtp.compiledModel,
        0,
        3,
        'mtp.args_3 (k-cache)',
      );

      // MTP has 3 outputs (recipe `Qwen3TtsPipeline._run_mtp`: `output_0`
      // residual-head logits, `output_1`/`output_2` the new k/v cache) —
      // read all 3 via
      // the bulk accessor (see [_readOutputShapes]'s doc for why a single
      // call must ask for all of them) and pick out `output_0` by shape:
      // it's the one that does NOT match [mtpKvShape] (k/v are both
      // `mtpKvShape`-shaped). Verified once, at load time, against the
      // REAL compiled graph — not hardcoded.
      final mtpOutputShapes = _readOutputShapes(
        bindings,
        mtp.compiledModel,
        0,
        3,
        'mtp outputs (output_0..2)',
      );
      if (mtpOutputShapes.length != 3) {
        throw StateError(
          'Qwen3TtsCore.load: expected 3 MTP graph outputs '
          '(output_0 logits, output_1/output_2 k/v), got '
          '${mtpOutputShapes.length}',
        );
      }
      final mtpLogitsShape = mtpOutputShapes[0];
      if (_shapeEquals(mtpLogitsShape, mtpKvShape)) {
        throw StateError(
          'Qwen3TtsCore.load: expected MTP output_0 to be the '
          'residual-head logits (shape != mtpKvShape=$mtpKvShape), got '
          '$mtpLogitsShape — output order may have drifted from the '
          'recipe (output_0=logits, output_1=k, output_2=v)',
        );
      }
      if (!_shapeEquals(mtpOutputShapes[1], mtpKvShape) ||
          !_shapeEquals(mtpOutputShapes[2], mtpKvShape)) {
        throw StateError(
          'Qwen3TtsCore.load: expected MTP output_1/output_2 to match '
          'mtpKvShape=$mtpKvShape (the new k/v cache), got '
          '${mtpOutputShapes[1]} / ${mtpOutputShapes[2]}',
        );
      }
      // `[15, vocab]` (observed) or `[1, 15, vocab]` (a leading batch dim,
      // tolerated defensively) — either way the
      // flat `output_0` buffer is row-major `[15 * vocab]`, so only
      // `vocab` (the last dim) is actually needed by [runMtp].
      final int mtpResidualVocab;
      final int mtpResidualHeads;
      if (mtpLogitsShape.length == 2) {
        mtpResidualHeads = mtpLogitsShape[0];
        mtpResidualVocab = mtpLogitsShape[1];
      } else if (mtpLogitsShape.length == 3 && mtpLogitsShape[0] == 1) {
        mtpResidualHeads = mtpLogitsShape[1];
        mtpResidualVocab = mtpLogitsShape[2];
      } else {
        throw StateError(
          'Qwen3TtsCore.load: unexpected MTP output_0 shape '
          '$mtpLogitsShape (want [15, vocab] or [1, 15, vocab])',
        );
      }
      if (mtpResidualHeads != 15) {
        throw StateError(
          'Qwen3TtsCore.load: expected MTP output_0 to have 15 residual '
          'heads, got $mtpResidualHeads (shape=$mtpLogitsShape)',
        );
      }

      final codecInShape = _readInputShape(
        bindings,
        codec.compiledModel,
        0,
        0,
        'codec.args_0',
      );
      final codecChunk = codecInShape.last;
      // [decodeCodes]'s sliding window advances by `codecChunk -
      // min(_codecLeftContext, i)` rows per step (this file's header); if a
      // drifted model shipped a codecChunk at or below the left-context
      // width, that advance is <= 0 and the decode loop never makes
      // progress (hangs) instead of failing loud here.
      if (codecChunk <= _codecLeftContext) {
        throw StateError(
          'Qwen3TtsCore.load: codecChunk ($codecChunk) must exceed the '
          'codec left-context ($_codecLeftContext); model layout drift.',
        );
      }

      tables = await Qwen3Tables.load(
        codecEmbPath: _artifactPath(artifactPaths, 'codec_embedding_fp32.npy'),
        mtpEmbPath: _artifactPath(artifactPaths, 'mtp_embeddings_fp16.npy'),
        textEmbPath: _artifactPath(artifactPaths, 'text_embedding_fp16.npy'),
        projectionNpzPath: _artifactPath(
          artifactPaths,
          'text_projection_fp32.npz',
        ),
      );

      final encoder = await Qwen2BpeEncoder.fromTokenizerJson(
        _artifactPath(artifactPaths, 'tokenizer.json'),
      );

      gemmaLog(
        '[Qwen3TtsCore] loaded: backend=$backend, 3 graphs compiled, '
        'mtpCacheLen=$mtpCacheLen, mtpKvShape=$mtpKvShape, '
        'mtpLogitsShape=$mtpLogitsShape, mtpResidualVocab=$mtpResidualVocab, '
        'codecChunk=$codecChunk',
      );

      return Qwen3TtsCore._(
        bindings: bindings,
        environment: environment,
        talker: talker,
        mtp: mtp,
        codec: codec,
        tables: tables,
        encoder: encoder,
        kvShapes: kvShapes,
        mtpCacheLen: mtpCacheLen,
        mtpKvShape: mtpKvShape,
        mtpLogitsShape: mtpLogitsShape,
        mtpResidualVocab: mtpResidualVocab,
        codecChunk: codecChunk,
      );
    } catch (_) {
      tables?.dispose();
      destroyGraphs(bindings, loadedGraphs);
      if (environment != null) bindings.destroyEnvironment(environment);
      rethrow;
    }
  }

  /// All-zero initial KV cache — 56 tensors sized to [_kvShapes]. Port of
  /// `qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize`'s
  /// `kv = {n: np.zeros(shape, np.float32) for n in kv_names}`.
  List<Float32List> _zeroKv() => [
    for (final shape in _kvShapes)
      Float32List(shape.fold<int>(1, (a, b) => a * b)),
  ];

  /// Prefills the talker's KV cache from the (<=32-row) prompt embedding
  /// [prefillEmb] (flat `[promptLen * 1024]`, row-major — e.g.
  /// `Qwen3Prompt.build`'s `prefill`). Port of `Qwen3TtsPipeline._run_prefill`:
  /// right-pads into the fixed 32-row `prefill_32` signature, builds the
  /// matching causal `mask`, runs against an all-zero initial KV cache
  /// ([_zeroKv]), and returns the 56 filled KV tensors — the new KV state a
  /// caller threads into the first decode step (`runDecode`).
  ///
  /// Not true public API (no v1 consumer outside this package calls it
  /// directly) — exposed (not underscore-private) so
  /// `qwen3_prefill_test.dart` can drive it, and annotated
  /// [visibleForTesting] to say so, mirroring `TtsCore.planMelWindows`.
  @visibleForTesting
  List<Float32List> runPrefill(Float32List prefillEmb, int promptLen) {
    if (_disposed) {
      throw StateError('Qwen3TtsCore is disposed');
    }
    if (promptLen < 0 || promptLen > 32) {
      throw ArgumentError.value(
        promptLen,
        'promptLen',
        "Qwen3TtsCore.runPrefill: prompt too long for the talker's "
            'prefill_32 signature (must be 0..32)',
      );
    }
    if (prefillEmb.length != promptLen * TalkerLayout.embeddingDim) {
      throw ArgumentError.value(
        prefillEmb.length,
        'prefillEmb.length',
        'Qwen3TtsCore.runPrefill: expected '
            '${promptLen * TalkerLayout.embeddingDim} '
            '(promptLen * ${TalkerLayout.embeddingDim})',
      );
    }

    // buf[1,32,1024]: right-padded prompt (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_prefill).
    final buf = Float32List(32 * TalkerLayout.embeddingDim);
    buf.setRange(0, prefillEmb.length, prefillEmb);

    // input_pos = arange(32) (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_prefill).
    final inputPos = Int32List.fromList([for (var i = 0; i < 32; i++) i]);

    // mask[1,1,32,cacheLen]: causal, `mask[0,0,i,:min(i,p-1)+1] = 0.0` else
    // qwen3NegInf (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_prefill). Flattened row-major —
    // row i occupies mask[i*cacheLen .. (i+1)*cacheLen).
    final cacheLen = TalkerLayout.cacheLen;
    final mask = Float32List(32 * cacheLen);
    for (var i = 0; i < 32; i++) {
      final lastValid = math.min(i, promptLen - 1);
      final rowBase = i * cacheLen;
      for (var j = 0; j <= lastValid; j++) {
        mask[rowBase + j] = 0.0;
      }
      for (var j = lastValid + 1; j < cacheLen; j++) {
        mask[rowBase + j] = qwen3NegInf;
      }
    }

    final kv = _zeroKv();
    final inputs = <GraphInput>[
      F32Input([1, 32, TalkerLayout.embeddingDim], buf),
      I32Input([32], inputPos),
      F32Input([1, 1, 32, cacheLen], mask),
      for (var i = 0; i < TalkerLayout.numKvTensors; i++)
        F32Input(_kvShapes[i], kv[i]),
    ];

    return runLiteRtGraph(
      _bindings,
      _talker.compiledModel,
      TalkerLayout.prefill32Sig,
      inputs,
      _kvShapes,
    );
  }

  /// Runs one autoregressive talker decode step, threading [kv] (the 56
  /// tensors from the previous [runPrefill]/[runDecode] call) forward one
  /// position. Port of `Qwen3TtsPipeline._run_decode`.
  ///
  /// [embed] (`[1024]`) is the current step's input embedding — for the
  /// very first decode step this is the last prefill row (`prefill[0, -1]`,
  /// recipe's `Qwen3TtsPipeline.synthesize`); for later steps (the AR loop
  /// in [synthesize]) it's the assembled next-frame embedding. [pos] is the
  /// KV-cache write position (0-indexed, matching `input_pos` passed to the
  /// graph).
  ///
  /// Builds the one-row causal `mask` (`[1,1,1,cacheLen]`,
  /// `mask[...,:pos+1] = 0.0` else [qwen3NegInf]), runs the talker's
  /// `decode` signature, and splits the `[1,1,4096]` `logits` output per
  /// `TalkerLayout`'s frozen layout (file header): `[:3072]` is the
  /// codebook-0 logits the caller scores/picks from ([cb0Logits]), `[3072:]`
  /// is the hidden-state tail the MTP graph consumes ([hidden]). Returns the
  /// 56 updated KV tensors ([newKv]) — the same order as [kv] (KV output
  /// order == KV input order, per `TalkerLayout`) — to thread into the next
  /// call.
  ///
  /// Not true public API (see this file's header) — [visibleForTesting] so
  /// `qwen3_talker_decode_test.dart` can drive it directly, and structured
  /// (single call, explicit `kv`/`pos` in, updated `kv` out) so a later
  /// task's per-frame decode loop can call it repeatedly without needing any
  /// internal state this class doesn't already expose.
  @visibleForTesting
  (Float32List cb0Logits, Float32List hidden, List<Float32List> newKv)
  runDecode(List<Float32List> kv, Float32List embed, int pos) {
    if (_disposed) {
      throw StateError('Qwen3TtsCore is disposed');
    }
    if (kv.length != TalkerLayout.numKvTensors) {
      throw ArgumentError.value(
        kv.length,
        'kv.length',
        'Qwen3TtsCore.runDecode: expected ${TalkerLayout.numKvTensors} KV '
            'tensors',
      );
    }
    if (embed.length != TalkerLayout.embeddingDim) {
      throw ArgumentError.value(
        embed.length,
        'embed.length',
        'Qwen3TtsCore.runDecode: expected ${TalkerLayout.embeddingDim} '
            '(embeddingDim)',
      );
    }
    final cacheLen = TalkerLayout.cacheLen;
    if (pos < 0 || pos >= cacheLen) {
      throw ArgumentError.value(
        pos,
        'pos',
        'Qwen3TtsCore.runDecode: pos must be in [0, $cacheLen)',
      );
    }

    // mask[1,1,1,cacheLen]: mask[...,:pos+1] = 0.0 else qwen3NegInf.
    // qwen3_tts_pipeline.py Qwen3TtsPipeline._run_decode (the decode-step causal mask — every
    // KV-cache slot up to and including `pos` is attendable, everything
    // after is not-yet-written).
    final mask = Float32List(cacheLen);
    for (var j = 0; j <= pos; j++) {
      mask[j] = 0.0;
    }
    for (var j = pos + 1; j < cacheLen; j++) {
      mask[j] = qwen3NegInf;
    }

    final inputs = <GraphInput>[
      F32Input([1, 1, TalkerLayout.embeddingDim], embed),
      I32Input([1], Int32List.fromList([pos])),
      F32Input([1, 1, 1, cacheLen], mask),
      for (var i = 0; i < TalkerLayout.numKvTensors; i++)
        F32Input(_kvShapes[i], kv[i]),
    ];

    // decode's outputs are the 56 KV tensors (same order as the KV inputs)
    // followed by `logits [1,1,4096]` — see `TalkerLayout`'s file header.
    final outputShapes = <List<int>>[
      ..._kvShapes,
      [1, 1, TalkerLayout.logitsWidth],
    ];

    final outputs = runLiteRtGraph(
      _bindings,
      _talker.compiledModel,
      TalkerLayout.decodeSig,
      inputs,
      outputShapes,
    );

    final newKv = outputs.sublist(0, TalkerLayout.numKvTensors);
    final logits = outputs[TalkerLayout.numKvTensors];
    final cb0Logits = logits.sublist(0, TalkerLayout.logitsCodec);
    final hidden = logits.sublist(
      TalkerLayout.logitsCodec,
      TalkerLayout.logitsWidth,
    );

    return (cb0Logits, hidden, newKv);
  }

  /// Runs the MTP (multi-token-prediction) 16-step inner loop that predicts
  /// the 15 residual codebooks of one frame from the talker's last hidden
  /// state [hidden] (`[1024]`, [runDecode]'s `hidden` output) and the
  /// already-picked codebook-0 token [cb0]. Port of
  /// `Qwen3TtsPipeline._run_mtp`.
  ///
  /// The MTP graph is a single decode step over a fixed [mtpCacheLen]-slot
  /// (17) KV cache, invoked 16 times per frame (`t = 0..15`): two seed
  /// feeds (`hidden`, then `codecEmbRow(cb0)`), then one feed per residual
  /// codebook, threading the graph's own k/v outputs (`output_1`/
  /// `output_2`) forward each step exactly like [runDecode] threads the
  /// talker's KV cache — except here the loop owns the cache itself
  /// (there's no separate prefill).
  ///
  /// Step `t`'s embedding is `feeds[t]` for `t < 2` (the two seeds above),
  /// else [Qwen3Tables.mtpEmbRow] of residual group `t - 2` at the
  /// previously-picked code — so the loop only ever embeds groups `0..13`
  /// (`t` ranges `2..15`); group 14 is never looked up here (it's used
  /// later, when the caller assembles the *next* frame's talker embedding —
  /// not by this loop). Head `t - 1` of `output_0` is read (and, when
  /// `t >= 1`, picked) at every step from `t = 1` to `t = 15`, producing the
  /// 15 returned codes — this off-by-one is faithful to the recipe, not a
  /// bug: ported verbatim, not "fixed".
  ///
  /// [greedy] selects [pickGreedy] (`do_sample=False`, the golden path —
  /// `qwen3_mtp_test.dart`'s gate) when `true`, else [pickSampled] with
  /// [topK]/[temperature]/[rng] (`do_sample=True`, ported from
  /// `qwen3_tts_pipeline.py Qwen3TtsPipeline._run_mtp`'s `_pick(..., do_sample, top_k,
  /// temperature, rng)` — the same top-k/temperature knobs are threaded
  /// through every one of the 15 residual heads, exactly as the recipe
  /// does). [rng] is required (and only consulted) when `greedy` is `false`.
  ///
  /// Not true public API (see this file's header) — [visibleForTesting] so
  /// `qwen3_mtp_test.dart` can drive it directly, mirroring [runPrefill]/
  /// [runDecode].
  @visibleForTesting
  List<int> runMtp(
    Float32List hidden,
    int cb0, {
    bool greedy = true,
    int topK = 50,
    double temperature = 0.9,
    math.Random? rng,
  }) {
    if (_disposed) {
      throw StateError('Qwen3TtsCore is disposed');
    }
    if (!greedy && rng == null) {
      throw ArgumentError.value(
        rng,
        'rng',
        'Qwen3TtsCore.runMtp: rng is required when greedy is false',
      );
    }
    if (hidden.length != TalkerLayout.embeddingDim) {
      throw ArgumentError.value(
        hidden.length,
        'hidden.length',
        'Qwen3TtsCore.runMtp: expected ${TalkerLayout.embeddingDim} '
            '(embeddingDim)',
      );
    }

    // k_all/v_all: qwen3_tts_pipeline.py Qwen3TtsPipeline._run_mtp
    // (`k_all = np.zeros(self._mtp_kv_shape, np.float32); v_all =
    // np.zeros_like(k_all)`) — reassigned each step to the graph's own
    // `output_1`/`output_2`, same "thread the previous step's output back
    // in as the next step's input" shape as [runDecode]'s KV threading.
    final kvCount = mtpKvShape.fold<int>(1, (a, b) => a * b);
    var kAll = Float32List(kvCount);
    var vAll = Float32List(kvCount);

    // feeds = [hidden, self._codec_emb[cb0]] (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_mtp).
    final feeds = <Float32List>[hidden, _tables.codecEmbRow(cb0)];
    final codes = <int>[];

    // output_0 (logits), output_1 (k), output_2 (v) — order + shapes
    // introspected once at [load] time (see [_mtpLogitsShape]'s doc); used
    // verbatim here so [runLiteRtGraph]'s per-output tensor-buffer creation
    // matches the graph's real output layout on every step.
    final outputShapes = <List<int>>[_mtpLogitsShape, mtpKvShape, mtpKvShape];

    for (var t = 0; t < 16; t++) {
      // embed = (feeds[t] if t < 2 else self._mtp_emb[t - 2][codes[-1]])
      // .reshape(1, 1, _HIDDEN) (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_mtp).
      final embed = t < 2 ? feeds[t] : _tables.mtpEmbRow(t - 2, codes.last);

      // mask = np.where(np.arange(cache) <= t, 0.0, _NEG_INF)...
      // .reshape(1, 1, 1, -1) (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_mtp).
      final mask = Float32List(mtpCacheLen);
      for (var j = 0; j <= t; j++) {
        mask[j] = 0.0;
      }
      for (var j = t + 1; j < mtpCacheLen; j++) {
        mask[j] = qwen3NegInf;
      }

      // out = self._mtp(args_0=embed, args_1=[t], args_2=mask,
      //                  args_3=k_all, args_4=v_all)
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_mtp).
      final inputs = <GraphInput>[
        F32Input([1, 1, TalkerLayout.embeddingDim], embed),
        I32Input([1], Int32List.fromList([t])),
        F32Input([1, 1, 1, mtpCacheLen], mask),
        F32Input(mtpKvShape, kAll),
        F32Input(mtpKvShape, vAll),
      ];

      final out = runLiteRtGraph(
        _bindings,
        _mtp.compiledModel,
        0,
        inputs,
        outputShapes,
      );

      // k_all, v_all = out['output_1'], out['output_2']
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_mtp).
      kAll = out[1];
      vAll = out[2];

      // if t >= 1: codes.append(_pick(out['output_0'][t - 1], ...))
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline._run_mtp). `out[0]` is the flat, row-major
      // `[15 * vocab]` (or `[1, 15, vocab]`) buffer — head `t - 1` is the
      // `vocab`-wide slice at that row, regardless of a leading batch dim
      // (row-major layout is unaffected by a leading size-1 axis).
      if (t >= 1) {
        final head = out[0].sublist(
          (t - 1) * _mtpResidualVocab,
          t * _mtpResidualVocab,
        );
        codes.add(
          greedy
              ? pickGreedy(head)
              : pickSampled(
                  head,
                  topK: topK,
                  temperature: temperature,
                  rng: rng!,
                ),
        );
      }
    }

    return codes;
  }

  /// Decodes the accumulated `[T, 16]` codec [frames] (row `t` = codebook-0
  /// + the 15 MTP residuals for talker frame `t`, e.g. every row of
  /// [runMtp]'s output prefixed with its `cb0`) into 24 kHz PCM in `[-1,
  /// 1]`. Port of `Qwen3TtsPipeline._decode_codes` — see this file's header
  /// for the sliding-window-with-left-context rationale.
  ///
  /// Walks [frames] in windows of at most [codecChunk] rows: each window
  /// after the first carries up to 25 rows of left context (`c = min(25,
  /// i)`) copied from the END of the previous window, so a window spans
  /// `[i - c, j)` where `j = min(i + codecChunk - c, frames.length)` — the
  /// loop only ever advances `i` to `j`, i.e. by `codecChunk - c` NEW rows
  /// per step. Each window is transposed into the codec's fixed
  /// `[1, 16, codecChunk]` `args_0` input (`buf[0, :, :window.length] =
  /// window.T`, zero-padded past `window.length`; row-major flat index for
  /// codebook `k`, window position `n` is `k * codecChunk + n` — see
  /// [runLiteRtGraph]'s `I32Input`), producing `[1, 1, codecChunk *
  /// _upsampleFactor]` PCM; only the samples for the window's OWN (non-
  /// context) rows are kept (`wav.sublist(c * _upsampleFactor, window.length
  /// * _upsampleFactor)`) before being concatenated across windows.
  ///
  /// Not true public API (see this file's header) — [visibleForTesting] so
  /// `qwen3_codec_test.dart` can drive it directly against the golden
  /// `frames.json` / `waveform_f32.bin` fixtures, mirroring [runPrefill]/
  /// [runDecode]/[runMtp].
  @visibleForTesting
  Float32List decodeCodes(List<List<int>> frames) {
    if (_disposed) {
      throw StateError('Qwen3TtsCore is disposed');
    }
    for (var t = 0; t < frames.length; t++) {
      if (frames[t].length != _numCodeGroups) {
        throw ArgumentError.value(
          frames[t].length,
          'frames[$t].length',
          'Qwen3TtsCore.decodeCodes: expected $_numCodeGroups codebooks per '
              'frame',
        );
      }
    }

    // chunk, ctx = self._codec_chunk, 25 (qwen3_tts_pipeline.py Qwen3TtsPipeline._decode_codes).
    const ctx = _codecLeftContext;
    final chunk = codecChunk;
    final pieces = <Float32List>[];
    var i = 0;
    while (i < frames.length) {
      // c = min(ctx, i); j = min(i + chunk - c, len(codes))
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline._decode_codes).
      final c = math.min(ctx, i);
      final j = math.min(i + chunk - c, frames.length);
      // window = codes[i - c:j] (qwen3_tts_pipeline.py Qwen3TtsPipeline._decode_codes).
      final window = frames.sublist(i - c, j);

      // buf = zeros(1, 16, chunk); buf[0, :, :len(window)] = window.T
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline._decode_codes) — flat row-major `[1,16,chunk]`:
      // codebook k, window position n -> buf[k * chunk + n].
      final buf = Int32List(_numCodeGroups * chunk);
      for (var n = 0; n < window.length; n++) {
        final row = window[n];
        for (var k = 0; k < _numCodeGroups; k++) {
          buf[k * chunk + n] = row[k];
        }
      }

      // out = self._codec(args_0=buf); wav = out.values()[0][0, 0]
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline._decode_codes).
      final out = runLiteRtGraph(
        _bindings,
        _codec.compiledModel,
        0,
        [
          I32Input([1, _numCodeGroups, chunk], buf),
        ],
        [
          [1, 1, chunk * _upsampleFactor],
        ],
      );
      final wav = out[0];

      // pieces.append(wav[c * _UPSAMPLE:len(window) * _UPSAMPLE])
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline._decode_codes) — drop the left-context samples.
      pieces.add(
        Float32List.sublistView(
          wav,
          c * _upsampleFactor,
          window.length * _upsampleFactor,
        ),
      );
      i = j;
    }

    // return np.concatenate(pieces) (qwen3_tts_pipeline.py Qwen3TtsPipeline._decode_codes).
    final total = pieces.fold<int>(0, (sum, p) => sum + p.length);
    final result = Float32List(total);
    var offset = 0;
    for (final piece in pieces) {
      result.setRange(offset, offset + piece.length, piece);
      offset += piece.length;
    }
    return result;
  }

  /// Synthesizes speech for [text] in the voice identified by [speaker].
  /// Port of `Qwen3TtsPipeline.synthesize` — see this file's header for the
  /// full loop shape.
  ///
  /// [speaker] is a `[1024]` x-vector identifying the target voice (see
  /// `Qwen3Prompt.build`'s doc comment). [language] is one of
  /// `Qwen3Prompt.languageIds`' keys (case-insensitive), or `'auto'`.
  /// [doSample] selects top-k/temperature sampling ([pickSampled], the
  /// model default — matches the recipe's `do_sample: bool = True`) when
  /// `true`, or deterministic greedy argmax ([pickGreedy]) when `false`; the
  /// golden gate (`qwen3_synthesize_test.dart`) passes `doSample: false` so
  /// the run is fully reproducible against the PyTorch-derived fixtures
  /// (greedy decoding reproduces the reference token-for-token). [topK] /
  /// [temperature] / [repetitionPenalty] are only consulted by the sampled
  /// path — [repetitionPenalty] scores the cb0 pick only (`applyCb0Scoring`
  /// over the `history` of previously-picked cb0 tokens), matching the
  /// recipe's `history` set (`Qwen3TtsPipeline.synthesize`). [seed]
  /// seeds the `dart:math.Random` [pickSampled]/[runMtp]'s sampled path
  /// draws from; the greedy path never touches it. [maxFrames] caps the
  /// number of generated 12.5 Hz frames (512 frames ≈ 41 s of audio).
  ///
  /// Returns mono float32 PCM in `[-1, 1]` at [sampleRate]. The frames
  /// generated by this call are cached in [lastFrames] for inspection.
  ///
  /// Throws a [StateError] if the AR loop hits [maxFrames] without reaching
  /// end-of-speech — i.e. [text] is too long to synthesize in a single AR
  /// pass. This is a fail-loud guard, not a truncation: no partial audio is
  /// ever returned silently.
  Float32List synthesize(
    String text, {
    required Float32List speaker,
    String language = 'english',
    bool doSample = true,
    int topK = 50,
    double temperature = 0.9,
    double repetitionPenalty = 1.05,
    int maxFrames = 512,
    int? seed,
  }) {
    final frames = _synthesizeFrames(
      text: text,
      speaker: speaker,
      language: language,
      doSample: doSample,
      topK: topK,
      temperature: temperature,
      repetitionPenalty: repetitionPenalty,
      maxFrames: maxFrames,
      seed: seed,
    );
    _lastFrames = frames;
    return decodeCodes(frames);
  }

  /// Same as [synthesize], but returns mono 16-bit PCM (little-endian)
  /// bytes instead of `[-1, 1]` float samples — for the isolate worker
  /// (`_runQwen3Worker` in `tts_worker.dart`) that streams audio to a
  /// player expecting int16 PCM. Every float sample is clamped to `[-1, 1]`,
  /// scaled by `32767`, and rounded before being written little-endian:
  /// `(sample.clamp(-1, 1) * 32767).round()`.
  ///
  /// Throws a [StateError] under the same condition as [synthesize] — see
  /// its doc — when [text] is too long for one AR pass.
  Uint8List synthesizePcm16(
    String text, {
    required Float32List speaker,
    String language = 'english',
    bool doSample = true,
    int topK = 50,
    double temperature = 0.9,
    double repetitionPenalty = 1.05,
    int maxFrames = 512,
    int? seed,
  }) {
    final wav = synthesize(
      text,
      speaker: speaker,
      language: language,
      doSample: doSample,
      topK: topK,
      temperature: temperature,
      repetitionPenalty: repetitionPenalty,
      maxFrames: maxFrames,
      seed: seed,
    );
    final bytes = Uint8List(wav.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < wav.length; i++) {
      final clamped = wav[i].clamp(-1.0, 1.0);
      view.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
    }
    return bytes;
  }

  /// The end-to-end AR loop shared by [synthesize]/[synthesizePcm16], split
  /// out so both can call [decodeCodes] on the same `frames` without
  /// duplicating the loop. Port of `Qwen3TtsPipeline.synthesize` — the part
  /// before its `_decode_codes` call.
  List<List<int>> _synthesizeFrames({
    required String text,
    required Float32List speaker,
    required String language,
    required bool doSample,
    required int topK,
    required double temperature,
    required double repetitionPenalty,
    required int maxFrames,
    required int? seed,
  }) {
    if (_disposed) {
      throw StateError('Qwen3TtsCore is disposed');
    }
    final rng = math.Random(seed);

    // ids = tokenizer.encode(f'<|im_start|>assistant\n{text}<|im_end|>\n
    // <|im_start|>assistant\n').ids (qwen3_tts_pipeline.py Qwen3TtsPipeline._build_prompt).
    final ids = _encoder.encode(
      '<|im_start|>assistant\n$text<|im_end|>\n<|im_start|>assistant\n',
    );
    final prompt = Qwen3Prompt.build(
      ids: ids,
      speaker: speaker,
      language: language,
      tables: _tables,
    );

    // kv = _run_prefill(...); pos = prefill.shape[1] - 1; logits, hidden,
    // kv = _run_decode(kv, prefill[0, -1], pos)
    // (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
    final initialKv = runPrefill(prompt.prefill, prompt.promptLen);
    var pos = prompt.promptLen - 1;
    final firstEmbed = Float32List.sublistView(
      prompt.prefill,
      pos * TalkerLayout.embeddingDim,
      prompt.promptLen * TalkerLayout.embeddingDim,
    );
    var (cb0Logits, hidden, kv) = runDecode(initialKv, firstEmbed, pos);

    // suppress = ...; qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize.
    final suppress = buildSuppress();
    final frames = <List<int>>[];
    final history = <int>{};
    var hitEos = false;

    // while len(frames) < max_frames: ... (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
    while (frames.length < maxFrames) {
      // scores = logits + suppress; ... (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
      // COPY cb0Logits first — applyCb0Scoring mutates its argument in
      // place (see its doc), and the original decode-step logits must not
      // be corrupted (nothing else reads them again this iteration, but
      // mutating shared state that isn't obviously owned by this call is a
      // footgun even so — the recipe itself never mutates `logits`, only
      // the freshly-allocated `scores`).
      final scores = Float32List.fromList(cb0Logits);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: history,
        repetitionPenalty: repetitionPenalty,
        // len(frames) < 2: min_new_tokens=2 (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
        minNewTokensGuard: frames.length < 2,
      );

      // cb0 = _pick(scores, do_sample, top_k, temperature, rng); history.
      // add(cb0) (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
      final cb0 = doSample
          ? pickSampled(scores, topK: topK, temperature: temperature, rng: rng)
          : pickGreedy(scores);
      history.add(cb0);
      // if cb0 == _CODEC_EOS: break (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
      if (cb0 == _codecEos) {
        hitEos = true;
        break;
      }

      // residual = _run_mtp(hidden, cb0, do_sample, top_k, temperature,
      // rng) (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
      final residual = runMtp(
        hidden,
        cb0,
        greedy: !doSample,
        topK: topK,
        temperature: temperature,
        rng: rng,
      );
      // frames.append([cb0] + residual) (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
      frames.add([cb0, ...residual]);

      // embed = codec_emb[cb0] + mtp_emb[arange(15), residual].sum(0)
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize) — element-wise add over ALL 15 MTP
      // residual groups (unlike [runMtp]'s own inner loop, which only ever
      // embeds groups 0..13 while picking; group 14 is used here, for the
      // FIRST time, to assemble the NEXT talker step's input).
      final embed = Float32List(TalkerLayout.embeddingDim);
      final cb0Row = _tables.codecEmbRow(cb0);
      for (var k = 0; k < TalkerLayout.embeddingDim; k++) {
        embed[k] = cb0Row[k];
      }
      for (var g = 0; g < _mtpResidualGroups; g++) {
        final row = _tables.mtpEmbRow(g, residual[g]);
        for (var k = 0; k < TalkerLayout.embeddingDim; k++) {
          embed[k] += row[k];
        }
      }
      // step = len(frames) - 1; embed += trailing[step] if step <
      // len(trailing) else tts_pad (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
      final step = frames.length - 1;
      final addend = step < prompt.trailing.length
          ? prompt.trailing[step]
          : prompt.ttsPad;
      for (var k = 0; k < TalkerLayout.embeddingDim; k++) {
        embed[k] += addend[k];
      }

      // pos += 1; logits, hidden, kv = _run_decode(kv, embed, pos)
      // (qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize).
      pos++;
      (cb0Logits, hidden, kv) = runDecode(kv, embed, pos);
    }

    if (!hitEos) {
      // Fail loud (per the project's no-masking-fallback rule): a
      // `gemmaLog`-only warning here is compile-time stripped in release
      // builds (`gemma_log.dart`'s `kDebugMode` gate), so a release app
      // synthesizing text too long for one AR pass would otherwise get
      // silently truncated audio with no signal at all. Throw instead of
      // returning the partial `frames` — the caller (`synthesize`/
      // `synthesizePcm16` -> the worker's per-request `try/catch` in
      // `_runQwen3Worker`) turns this into a clear `completeError`, not
      // confident-but-incomplete output.
      throw StateError(
        'Qwen3 TTS reached the maxFrames cap ($maxFrames ≈ '
        '${(maxFrames / 12.5).round()} s of audio) without reaching '
        'end-of-speech — the input is too long for a single AR pass. Split '
        'it into shorter segments (Qwen3 v1 does not chunk text the way '
        'Matcha does).',
      );
    }

    return frames;
  }

  /// Destroys the 3 compiled graphs' handles + the shared environment, and
  /// closes [_tables]' open `text_embedding` file handle. Mirrors
  /// `TtsCore.dispose`.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    destroyGraphs(_bindings, [_talker, _mtp, _codec]);
    _bindings.destroyEnvironment(_environment);
    _tables.dispose();
  }
}
