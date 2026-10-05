// Synchronous, isolate-agnostic native core for Matcha-TTS on-device
// synthesis.
//
// Owns the LiteRT C API handles (one environment + 4 compiled graphs:
// text-encoder, CFM decoder, HiFi-GAN vocoder, dp_g2p) for a `matchaCfm`
// pipeline. `synthesize()` runs the blocking forward passes + host-side ODE math
// synchronously on the calling thread — like `SttCore.transcribe`, it is
// meant to be driven from a background isolate so the UI isolate stays free.
//
// This is a PORT, not new work. The math (text-encoder -> host duration +
// Glow-TTS-style length regulator -> N-step Euler CFM decoder -> mel denorm
// -> HiFi-GAN vocoder -> 16-bit PCM) is a verbatim line-for-line port of the
// verified reconstruction script `matcha_synth.dart` (`main()` lines
// 505-618, helpers `_searchSortedRight`/`_tSin`/`_nextGaussian`/`runGraph`).
// The FFI STYLE is ported from `stt_core.dart` instead of that script's raw
// `dlopen`: `matcha_synth.dart` opens the dylib directly by path, which does
// NOT work inside this package (the native lib is loaded via Native
// Assets — see `LiteRtBindings.open()`/`_openLiteRt()` in
// `package:flutter_gemma_litertlm/litert_bindings.dart`). So every graph run
// here goes through `LiteRtBindings`'s create -> run -> lock(Read) ->
// copy-through-locked-ptr -> unlock -> destroy tensor-buffer sequence,
// exactly like `SttCore._encode`/`_decodeLoop`, generalized to N inputs / M
// outputs (the multi-input pattern mirrors `SttCore._decodeLoop`'s 3-input
// decode at stt_core.dart:504-527: each buffer is created into its own
// single-slot pointer, then `.value` is copied into a fresh combined array
// right before the run call). The load/run/tensor-buffer machinery itself
// now lives in `litert_graph.dart` (`loadLiteRtGraph`/`runLiteRtGraph`),
// generalized to mixed F32/I32 inputs for the upcoming Qwen3 talker/codec
// graphs; this file delegates to it and stays behavior-identical.
//
// Generic over [TtsModelProfile] — only `TtsPipelineKind.matchaCfm` is
// implemented. `qwen3ArCodec` profiles are dispatched to `Qwen3TtsCore` by
// the worker and fail-loud if they ever reach [load]'s guard instead;
// kokoro/supertonic profiles are documented follow-ons with no wired
// pipeline kind at all. The `dp_g2p` graph IS loaded here (4th compiled
// graph) and exposed via
// `TtsCore.neuralG2p` — it's the neural OOV fallback used when a word is
// missing from the dictionary; the dictionary-only path stays the golden
// path via `TtsTextFrontend`.
//
// Determinism: the Euler CFM decoder's initial noise is drawn from a FIXED
// seed ([ttsCfmSeed]) via Box-Muller ([nextGaussian]), so [TtsCore.synthesize]
// is byte-reproducible run-to-run — the golden in `tts_core_test.dart`
// depends on this. Do NOT change the seed or the Box-Muller formula
// without regenerating it.
//
// Leak-safety: buffer create/lock/read/unlock/destroy mirrors
// `litert_embedding_core.dart`'s forward-pass pattern; `load`'s partial-
// failure cleanup mirrors `SttCore.load`, generalized to 4 compiled graphs
// (a failure loading e.g. the decoder frees the already-loaded text-encoder
// + the shared environment before rethrowing).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:meta/meta.dart' show visibleForTesting;
// Public, native-only bindings library (not the package barrel) — see the
// equivalent comment in `stt_core.dart`/`litert_embedding_core.dart` for why
// this import (not the `if (dart.library.ffi)` barrel) is correct in a
// native-only file.
import 'package:flutter_gemma_litertlm/litert_bindings.dart';

import '../model/tts_model_profile.dart';
import '../tts/neural_g2p_decode.dart';
import '../tts/tts_frontend_input.dart';
import 'litert_graph.dart';

/// The Euler CFM decoder's fixed Gaussian-noise seed. Fixed (not
/// time-derived) so [TtsCore.synthesize] is byte-reproducible run-to-run —
/// the golden in `tts_core_test.dart` depends on this. Verified value from
/// `matcha_synth.dart:565`.
const int ttsCfmSeed = 1234;

/// Leftmost `i` such that `cum[i-1] <= v < cum[i]` (numpy `searchsorted`,
/// `side='right'`). Used by the Glow-TTS-style length regulator to look up
/// which text-encoder frame each mel frame belongs to. Verbatim port of
/// `matcha_synth.dart`'s `_searchSortedRight`.
int searchSortedRight(Float64List cum, double v) {
  var lo = 0, hi = cum.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (cum[mid] <= v) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Sinusoidal timestep embedding (length `half * 2`, 160 for Matcha's
/// `half=80`) fed to the CFM decoder at every Euler step. Verbatim port of
/// `matcha_synth.dart`'s `_tSin`.
Float32List tSin(double t, {int half = 80}) {
  final e = Float64List(half);
  for (var i = 0; i < half; i++) {
    e[i] = 1000.0 * t * math.exp(i * (-math.log(10000) / (half - 1)));
  }
  final out = Float32List(half * 2);
  for (var i = 0; i < half; i++) {
    out[i] = math.sin(e[i]);
    out[half + i] = math.cos(e[i]);
  }
  return out;
}

/// One standard-normal sample via Box-Muller, drawn from [r]. Verbatim port
/// of `matcha_synth.dart`'s `_nextGaussian` — used with [ttsCfmSeed] to seed
/// the CFM decoder's initial noise reproducibly.
double nextGaussian(math.Random r) {
  var u1 = r.nextDouble();
  while (u1 <= 1e-12) {
    u1 = r.nextDouble();
  }
  final u2 = r.nextDouble();
  return math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

String _artifactPath(Map<String, String> artifactPaths, String file) =>
    artifactPath(artifactPaths, file, owner: 'TtsCore');

/// Synchronous native TTS core. NOT safe to share across isolates — the FFI
/// handles it holds are owned by the isolate that called [load].
class TtsCore {
  TtsCore._({
    required this._bindings,
    required this._environment,
    required this._textEncoder,
    required this._decoder,
    required this._vocoder,
    required this._dpG2p,
    required this._nFeats,
    required this._nChannels,
    required this._maxText,
    required this._maxMel,
    required this._hop,
    required this._sampleRate,
    required this._lengthScale,
    required this._nTimesteps,
    required this._melStd,
    required this._melMean,
    required this._g2pChar2idx,
    required this._g2pIdx2ph,
    required this._g2pCharRepeats,
    required this._g2pStart,
    required this._g2pEnd,
    required this._g2pMaxT,
    required this._g2pNPhonemes,
  });

  final LiteRtBindings _bindings;
  final LiteRtEnvironment _environment;
  final LoadedGraph _textEncoder;
  final LoadedGraph _decoder;
  final LoadedGraph _vocoder;
  final LoadedGraph _dpG2p;

  final int _nFeats;
  final int _nChannels;
  final int _maxText;
  final int _maxMel;
  final int _hop;
  final int _sampleRate;
  final double _lengthScale;
  final int _nTimesteps;
  final double _melStd;
  final double _melMean;

  // Neural G2P (dp_g2p) vocab + framing params, read from `g2p_meta.json` at
  // load time so `neuralG2p` can stay synchronous (no file I/O per word).
  final Map<String, int> _g2pChar2idx;
  final Map<int, String> _g2pIdx2ph;
  final int _g2pCharRepeats;
  final int _g2pStart;
  final int _g2pEnd;
  final int _g2pMaxT;
  final int _g2pNPhonemes;

  bool _disposed = false;

  /// Loads `config.json` + `g2p_meta.json` and compiles the 4 Matcha graphs
  /// (text-encoder, decoder, vocoder, dp_g2p) for [backend]. Heavy — call
  /// once, from a background isolate. [artifactPaths] is filename ->
  /// on-disk-path for the model bundle (from `RuntimeConfig.artifactPaths`).
  static Future<TtsCore> load({
    required TtsModelProfile profile,
    required Map<String, String> artifactPaths,
    PreferredBackend? backend,
  }) async {
    if (profile is! MatchaProfile) {
      throw UnimplementedError(
        'TtsCore: only TtsPipelineKind.matchaCfm is implemented here '
        '(qwen3ArCodec is handled by Qwen3TtsCore, not the Matcha TtsCore '
        'path; kokoro/supertonic have no wired pipeline kind yet).',
      );
    }

    final configPath = _artifactPath(artifactPaths, profile.configFile);
    final config =
        jsonDecode(await File(configPath).readAsString())
            as Map<String, dynamic>;
    final nFeats = (config['n_feats'] as num).toInt();
    final nChannels = (config['n_channels'] as num).toInt();
    final maxText = (config['MAX_TEXT'] as num).toInt();
    final maxMel = (config['MAX_MEL'] as num).toInt();
    final hop = (config['hop'] as num).toInt();
    final sampleRate = (config['sample_rate'] as num).toInt();
    final lengthScale = (config['length_scale'] as num).toDouble();
    final nTimesteps = (config['n_timesteps_default'] as num).toInt();
    final melStd = (config['mel_std'] as num).toDouble();
    final melMean = (config['mel_mean'] as num).toDouble();

    final bindings = LiteRtBindings.open();
    final accelerator = acceleratorFor(backend);

    // Track handles as they're created so a failure partway through (e.g.
    // the decoder graph fails to compile after the text-encoder already
    // loaded) frees everything already allocated instead of leaking it — the
    // LiteRT native heap is process-global and is NOT reclaimed by the
    // isolate dying. Mirrors `SttCore.load`, generalized to 4 graphs.
    LiteRtEnvironment? environment;
    final loadedGraphs = <LoadedGraph>[];
    try {
      final envPtr = calloc<LiteRtEnvironment>();
      bindings
          .createEnvironment(0, nullptr, envPtr)
          .check('LiteRtCreateEnvironment');
      environment = envPtr.value;
      calloc.free(envPtr);

      final textEncoder = loadLiteRtGraph(
        bindings,
        environment,
        _artifactPath(artifactPaths, profile.textEncoderFile),
        accelerator,
      );
      loadedGraphs.add(textEncoder);

      final decoder = loadLiteRtGraph(
        bindings,
        environment,
        _artifactPath(artifactPaths, profile.decoderFile),
        accelerator,
      );
      loadedGraphs.add(decoder);

      final vocoder = loadLiteRtGraph(
        bindings,
        environment,
        _artifactPath(artifactPaths, profile.vocoderFile),
        accelerator,
      );
      loadedGraphs.add(vocoder);

      final dpG2p = loadLiteRtGraph(
        bindings,
        environment,
        _artifactPath(artifactPaths, profile.g2pFile),
        accelerator,
      );
      loadedGraphs.add(dpG2p);

      final g2pMetaPath = _artifactPath(artifactPaths, profile.g2pMetaFile);
      final g2pMeta =
          jsonDecode(await File(g2pMetaPath).readAsString())
              as Map<String, dynamic>;
      final g2pChar2idx = (g2pMeta['char2idx'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, (v as num).toInt()),
      );
      final g2pIdx2ph = (g2pMeta['idx2ph'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(int.parse(k), v as String),
      );
      final g2pCharRepeats = (g2pMeta['char_repeats'] as num).toInt();
      final g2pStart = (g2pMeta['start'] as num).toInt();
      final g2pEnd = (g2pMeta['end'] as num).toInt();
      final g2pMaxT = (g2pMeta['MAXT'] as num).toInt();
      final g2pNPhonemes = (g2pMeta['n_phonemes'] as num).toInt();

      gemmaLog('[TtsCore] loaded: backend=$backend, 4 graphs compiled');

      return TtsCore._(
        bindings: bindings,
        environment: environment,
        textEncoder: textEncoder,
        decoder: decoder,
        vocoder: vocoder,
        dpG2p: dpG2p,
        nFeats: nFeats,
        nChannels: nChannels,
        maxText: maxText,
        maxMel: maxMel,
        hop: hop,
        sampleRate: sampleRate,
        lengthScale: lengthScale,
        nTimesteps: nTimesteps,
        melStd: melStd,
        melMean: melMean,
        g2pChar2idx: g2pChar2idx,
        g2pIdx2ph: g2pIdx2ph,
        g2pCharRepeats: g2pCharRepeats,
        g2pStart: g2pStart,
        g2pEnd: g2pEnd,
        g2pMaxT: g2pMaxT,
        g2pNPhonemes: g2pNPhonemes,
      );
    } catch (_) {
      destroyGraphs(bindings, loadedGraphs);
      if (environment != null) bindings.destroyEnvironment(environment);
      rethrow;
    }
  }

  /// Output sample rate (Hz), read from `config.json`.
  int get sampleRate => _sampleRate;

  /// Runs [word] through the neural dp_g2p graph — the OOV fallback for
  /// words missing from the pronunciation dictionary — and returns its IPA
  /// phoneme string. Synchronous (no file I/O; `g2p_meta.json` was already
  /// parsed in [load]), so it's safe to call per-word from the frontend (the
  /// `NeuralG2pResolver` adapter is `core.neuralG2p`). Framing/decoding is
  /// [encodeG2pInput]/[decodeG2pOutput] — this method only runs the native
  /// forward pass and picks the per-position argmax over the
  /// `n_phonemes`-wide logits.
  String neuralG2p(String word) {
    if (_disposed) {
      throw StateError('TtsCore is disposed');
    }
    final x = encodeG2pInput(
      word,
      _g2pChar2idx,
      charRepeats: _g2pCharRepeats,
      start: _g2pStart,
      end: _g2pEnd,
      maxT: _g2pMaxT,
    );
    final logits = runLiteRtGraph(
      _bindings,
      _dpG2p.compiledModel,
      0,
      [
        F32Input([1, _g2pMaxT], x),
      ],
      [
        [1, _g2pMaxT, _g2pNPhonemes],
      ],
    )[0];
    final argmax = List<int>.generate(_g2pMaxT, (t) {
      var best = 0;
      var bestV = logits[t * _g2pNPhonemes];
      for (var p = 1; p < _g2pNPhonemes; p++) {
        final v = logits[t * _g2pNPhonemes + p];
        if (v > bestV) {
          bestV = v;
          best = p;
        }
      }
      return best;
    });
    return decodeG2pOutput(argmax, _g2pIdx2ph, end: _g2pEnd);
  }

  /// Runs the full Matcha forward pass for a prepared frontend [input]:
  /// text-encoder -> host duration + Glow-TTS length regulator -> partition
  /// into MAX_MEL-sized windows -> per-window N-step Euler CFM decoder ->
  /// mel denorm -> HiFi-GAN vocoder -> 16-bit PCM, concatenated across
  /// windows. Verbatim port of `matcha_synth.dart:518-635`'s math for the
  /// single-window case; every graph run goes through [runLiteRtGraph]
  /// instead of that script's raw-`dlopen` `runGraph`. Returns 16-bit
  /// little-endian mono PCM with NO WAV header — the example's `pcmToWav`
  /// adds a header.
  ///
  /// When the predicted duration fits one window (`rawYlen <= _maxMel`, the
  /// common case), this is byte-identical to the pre-chunking implementation
  /// — see [_decodeWindow]. When it doesn't, the phoneme run is split into
  /// contiguous windows (see [planMelWindows]) that are decoded + vocoded
  /// independently and concatenated with no inter-window silence, so
  /// arbitrarily long text no longer throws `predicted N mel frames >
  /// MAX_MEL`.
  ///
  /// [seed] seeds the CFM decoder's initial Gaussian noise (defaults to
  /// [ttsCfmSeed], the golden-reproducible value). The worker's clause
  /// chunker passes `ttsCfmSeed + i` per clause so a single-clause input —
  /// e.g. the `'Hello world.'` golden — still synthesizes with
  /// `seed == ttsCfmSeed`, byte-identical to before this parameter existed.
  /// Multi-window synthesis within a single [synthesize] call uses
  /// `seed + windowIndex` per window.
  Uint8List synthesize(MatchaFrontendInput input, {int seed = ttsCfmSeed}) {
    if (_disposed) {
      throw StateError('TtsCore is disposed');
    }

    // --- text encoder: symbolEmbeddings[1,maxText,nChannels] +
    //     textMask[1,1,maxText] -> mu[1,nFeats,maxText], logw[1,1,maxText] ---
    final teOut = runLiteRtGraph(
      _bindings,
      _textEncoder.compiledModel,
      0,
      [
        F32Input([1, _maxText, _nChannels], input.symbolEmbeddings),
        F32Input([1, 1, _maxText], input.textMask),
      ],
      [
        [1, _nFeats, _maxText],
        [1, 1, _maxText],
      ],
    );
    final mu = teOut[0]; // feat-major [nFeats*maxText]: mu[f*maxText+pos]
    final logw = teOut[1]; // [maxText]

    // --- duration + Glow-TTS-style length regulator ---
    // w = ceil(exp(logw) * textMask) * lengthScale (verbatim).
    final w = Float64List(_maxText);
    for (var t = 0; t < _maxText; t++) {
      w[t] =
          (math.exp(logw[t]) * input.textMask[t]).ceilToDouble() * _lengthScale;
    }

    // real phoneme count = highest t with textMask!=0, +1 (mask zeroes
    // padding past the real slot run; w is 0 there too since
    // textMask[t]==0 zeroes the exp(logw) term).
    var realCount = 0;
    for (var t = 0; t < _maxText; t++) {
      if (input.textMask[t] != 0.0) realCount = t + 1;
    }

    final windows = planMelWindows(w, realCount, _maxMel);
    if (windows.isEmpty) {
      // No speech frames -> empty PCM. In practice the worker skips
      // realLen<=1 inputs before they reach here; kept safe regardless.
      return Uint8List(0);
    }
    if (windows.length == 1) {
      // Single window: byte-identical to the pre-chunking implementation
      // (see the equivalence note on [_decodeWindow]).
      final (s, e) = windows.first;
      return _decodeWindow(mu, w, s, e, seed);
    }
    // Multi-window: decode each window (distinct seed per window) and
    // concat PCM with NO inter-window silence — they are one continuous
    // utterance; the worker's clause/sub-chunk splicing is the only place
    // that adds silence (see the note in `tts_worker.dart`).
    final segs = <Uint8List>[];
    for (var i = 0; i < windows.length; i++) {
      final (s, e) = windows[i];
      segs.add(_decodeWindow(mu, w, s, e, seed + i));
    }
    return concatSegments(segs);
  }

  /// Concatenate PCM segments back-to-back with NO gap/silence (multi-window
  /// output of one [synthesize] call is a single continuous utterance).
  @visibleForTesting
  static Uint8List concatSegments(List<Uint8List> segs) {
    final total = segs.fold<int>(0, (a, b) => a + b.length);
    final out = Uint8List(total);
    var off = 0;
    for (final seg in segs) {
      out.setRange(off, off + seg.length, seg);
      off += seg.length;
    }
    return out;
  }

  /// Decode ONE window: the contiguous phoneme range `[pStart, pEnd)` of
  /// [mu] (feat-major `[_nFeats*_maxText]`) whose per-phoneme durations are
  /// [w]. The window's summed duration MUST already be `<= _maxMel` (caller
  /// guarantees, via [planMelWindows]). Returns 16-bit LE mono PCM
  /// (`winFrames*_hop*2` bytes).
  ///
  /// Byte-identical to the pre-chunking `synthesize` tail when called with
  /// `pStart=0, pEnd=realPhonemeCount, seed=the original seed` (single
  /// window): `localCum` then equals the old global `cum` over the real
  /// phonemes (w is 0 past `realCount`, so `localCum.last == cum[realCount -
  /// 1] == cum[_maxText - 1]`), so `winFrames` equals the old `ylen`, `muY`
  /// (via `searchSortedRight` on the identical cumulative array) is
  /// identical, and the seed-fixed noise draw, Euler loop, mel denorm,
  /// vocoder call, and PCM quantization are all unchanged.
  Uint8List _decodeWindow(
    Float32List mu,
    Float64List w,
    int pStart,
    int pEnd,
    int seed,
  ) {
    // Local cumulative durations for this window's phonemes (relative to the
    // window start), so muY-expansion and winFrames are window-local. For the
    // single full window (pStart=0), localCum == the old global `cum`.
    final localCum = Float64List(pEnd - pStart);
    var running = 0.0;
    for (var p = pStart; p < pEnd; p++) {
      running += w[p];
      localCum[p - pStart] = running;
    }
    final rawWin = localCum.isEmpty ? 0.0 : localCum[localCum.length - 1];
    final winFrames = rawWin.clamp(1.0, _maxMel.toDouble()).toInt();

    // muY[_nFeats*_maxMel] + ymask[_maxMel] — gather mu at the phoneme each
    // window-local output frame maps to (searchSorted on the LOCAL cum, then
    // offset by pStart). Identical to today for the single-window case.
    final muY = Float32List(_nFeats * _maxMel);
    final ymask = Float32List(_maxMel);
    for (var t = 0; t < winFrames; t++) {
      var idx = pStart + searchSortedRight(localCum, t.toDouble());
      if (idx > _maxText - 1) idx = _maxText - 1;
      for (var f = 0; f < _nFeats; f++) {
        muY[f * _maxMel + t] = mu[f * _maxText + idx];
      }
      ymask[t] = 1.0;
    }

    // Euler CFM ODE — seed-fixed Gaussian noise (byte-reproducible).
    final rnd = math.Random(seed);
    final x = Float32List(_nFeats * _maxMel);
    for (var f = 0; f < _nFeats; f++) {
      for (var t = 0; t < winFrames; t++) {
        x[f * _maxMel + t] = nextGaussian(rnd);
      }
    }
    for (var k = 0; k < _nTimesteps; k++) {
      final tEmb = tSin(k / _nTimesteps);
      final decOut = runLiteRtGraph(
        _bindings,
        _decoder.compiledModel,
        0,
        [
          F32Input([1, _nFeats, _maxMel], x),
          F32Input([1, _nFeats, _maxMel], muY),
          F32Input([1, 160], tEmb),
          F32Input([1, 1, _maxMel], ymask),
        ],
        [
          [1, _nFeats, _maxMel],
        ],
      );
      final v = decOut[0];
      for (var i = 0; i < x.length; i++) {
        x[i] += v[i] / _nTimesteps;
      }
    }

    // mel denorm
    final mel = Float32List(_nFeats * _maxMel);
    for (var f = 0; f < _nFeats; f++) {
      for (var t = 0; t < winFrames; t++) {
        mel[f * _maxMel + t] = x[f * _maxMel + t] * _melStd + _melMean;
      }
    }

    // vocoder -> wav -> 16-bit LE PCM
    final vocOut = runLiteRtGraph(
      _bindings,
      _vocoder.compiledModel,
      0,
      [
        F32Input([1, _nFeats, _maxMel], mel),
      ],
      [
        [1, 1, _maxMel * _hop],
      ],
    );
    final wav = vocOut[0];
    final numSamples = winFrames * _hop;
    final pcm = Uint8List(numSamples * 2);
    final pcmView = ByteData.sublistView(pcm);
    for (var i = 0; i < numSamples; i++) {
      var s = wav[i];
      if (s > 1.0) s = 1.0;
      if (s < -1.0) s = -1.0;
      var q = (s * 32767.0).round();
      if (q > 32767) q = 32767;
      if (q < -32768) q = -32768;
      pcmView.setInt16(i * 2, q, Endian.little);
    }
    return pcm;
  }

  /// Partition phoneme indices `[0, realCount)` into contiguous windows whose
  /// summed durations [w] each fit [maxMel]. Greedy: extend a window until
  /// the next phoneme would overflow, then start a new one. Returns window
  /// boundaries as `[start, end)` index pairs.
  ///
  /// Throws if a SINGLE phoneme's duration alone exceeds [maxMel] (one
  /// phoneme longer than the decoder window is genuinely unsynthesizable —
  /// fail loud).
  @visibleForTesting
  static List<(int, int)> planMelWindows(
    Float64List w,
    int realCount,
    int maxMel,
  ) {
    final windows = <(int, int)>[];
    var start = 0;
    var acc = 0.0;
    for (var p = 0; p < realCount; p++) {
      final d = w[p];
      if (d > maxMel) {
        throw StateError(
          'TtsCore: a single phoneme needs ${d.ceil()} mel frames > MAX_MEL '
          '$maxMel and cannot be split.',
        );
      }
      if (p > start && acc + d > maxMel) {
        windows.add((start, p));
        start = p;
        acc = 0.0;
      }
      acc += d;
    }
    if (start < realCount) windows.add((start, realCount));
    return windows;
  }

  /// Destroys all 4 compiled graphs' handles + the shared environment.
  /// Mirrors `SttCore.dispose`, x4.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    destroyGraphs(_bindings, [_textEncoder, _decoder, _vocoder, _dpG2p]);
    _bindings.destroyEnvironment(_environment);
  }
}
