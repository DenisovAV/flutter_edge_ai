// Inflect-Nano-v2 TTS synthesis core — a VITS-style pipeline over two LiteRT
// graphs, run through the shared FFI helpers in `litert_graph.dart` (the same
// create -> run -> lock(Read) -> copy -> unlock -> destroy path `TtsCore` uses).
//
// Pipeline (a verbatim port of the reference `bench.py`/`say.py` from
// huggingface.co/sasha-denisov/inflect-nano-v2-litert):
//   1. text-encoder: tokens[1,N] (phoneme-symbol ids) -> three outputs, in the
//      model's declared order: m_p[1,N,128], logs_p[1,N,128], logw[1,N,1].
//   2. host-side length regulator: durations = ceil(exp(logw)); repeat encoder
//      frame t of m_p/logs_p durations[t] times -> [1,T,128] each (T = sum).
//   3. z_p = m_p_exp + noise * exp(logs_p_exp) * NOISE_SCALE.
//   4. decoder: z_p[1,T,128] -> waveform[1, T*HOP] (24 kHz, no separate
//      vocoder — the decoder emits samples directly).
//   5. float32 [-1,1] -> 16-bit little-endian PCM.
//
// Determinism / verification: VITS is stochastic — the `noise` term is a random
// realization, so any fixed seed produces valid speech (a DIFFERENT noise
// instance changes the waveform's fine structure completely: sample-correlation
// against a reference generated with a different RNG is ~0, not ~1). The product
// path uses a fixed-seed Box-Muller Gaussian ([_defaultSeed]) so a given text is
// byte-reproducible run-to-run. To verify the FFI graphs + host math byte-exact
// against a reference WITHOUT reimplementing numpy's Mersenne-Twister, pass the
// reference's exported noise via [synthesize]'s `noiseOverride` — that removes
// the RNG as a variable and makes the whole chain reproducible.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma_litertlm/litert_bindings.dart';

import '../model/tts_model_profile.dart';
import '../tts/neural_g2p_decode.dart';
import '../tts/tts_text_frontend.dart' show NeuralG2pResolver;
import 'litert_graph.dart';
import 'tts_core.dart' show nextGaussian;

/// Inflect output sample rate (Hz).
const int inflectSampleRate = 24000;

/// Waveform samples the decoder emits per z_p frame (upsampling factor).
const int _hop = 256;

/// Upper bound on a single phoneme's duration (frames) — a guard against
/// degenerate model output driving `tFrames` into an OOM allocation. At
/// 24 kHz / hop 256 (~94 frames/s) this is ~11 s for one phoneme: far beyond
/// anything legitimate, so it only ever clamps garbage.
const int _maxFramesPerPhoneme = 1024;

/// Upper bound on the TOTAL length-regulated frames across the whole utterance.
/// The per-phoneme clamp only caps one frame; without this, N degenerate
/// phonemes each hitting [_maxFramesPerPhoneme] would still sum to
/// N·[_maxFramesPerPhoneme] frames and OOM the `T·128` latent buffers + the
/// `T·HOP` decoder output. At ~94 frames/s this is ~87 s of audio — far beyond
/// any real spoken reply (upstream capped by `maxOutputTokens`), so it only
/// ever truncates garbage.
const int _maxTotalFrames = 8192;

/// VITS prior noise scale (`--variation` default in `say.py`).
const double _noiseScale = 0.667;

/// Fixed default RNG seed for the product path (byte-reproducible per text).
const int _defaultSeed = 7;

String _artifactPath(Map<String, String> paths, String file) =>
    artifactPath(paths, file, owner: 'InflectTtsCore');

/// The neural OOV G2P (dp_g2p graph + its `g2p_meta.json` framing/vocab),
/// loaded only when the bundle carries it. Shared verbatim with Matcha's
/// `dp_g2p` — same graph, same meta.
class _InflectG2p {
  _InflectG2p({
    required this.graph,
    required this.char2idx,
    required this.idx2ph,
    required this.charRepeats,
    required this.start,
    required this.end,
    required this.maxT,
    required this.nPhonemes,
  });
  final LoadedGraph graph;
  final Map<String, int> char2idx;
  final Map<int, String> idx2ph;
  final int charRepeats;
  final int start;
  final int end;
  final int maxT;
  final int nPhonemes;
}

/// Synchronous native Inflect TTS core. NOT safe to share across isolates — the
/// FFI handles are process-global; create + use + [dispose] on one isolate.
class InflectTtsCore {
  InflectTtsCore._({
    required this._bindings,
    required this._environment,
    required this._textEncoder,
    required this._decoder,
    this._g2p,
  });

  final LiteRtBindings _bindings;
  final LiteRtEnvironment _environment;
  final LoadedGraph _textEncoder;
  final LoadedGraph _decoder;
  final _InflectG2p? _g2p;

  bool _disposed = false;

  /// Neural OOV G2P resolver (dp_g2p), or null if the bundle didn't include it
  /// — pass to `InflectTextFrontend` so out-of-dictionary words resolve instead
  /// of throwing. Mirrors `TtsCore.neuralG2p`.
  NeuralG2pResolver? get neuralG2p {
    if (_disposed) {
      throw StateError('InflectTtsCore is disposed');
    }
    final g = _g2p;
    if (g == null) return null;
    return (word) {
      final x = encodeG2pInput(
        word,
        g.char2idx,
        charRepeats: g.charRepeats,
        start: g.start,
        end: g.end,
        maxT: g.maxT,
      );
      final logits = runLiteRtGraph(
        _bindings,
        g.graph.compiledModel,
        0,
        [
          F32Input([1, g.maxT], x),
        ],
        [
          [1, g.maxT, g.nPhonemes],
        ],
      )[0];
      final argmax = List<int>.generate(g.maxT, (t) {
        var best = 0;
        var bestV = logits[t * g.nPhonemes];
        for (var p = 1; p < g.nPhonemes; p++) {
          final v = logits[t * g.nPhonemes + p];
          if (v > bestV) {
            bestV = v;
            best = p;
          }
        }
        return best;
      });
      return decodeG2pOutput(argmax, g.idx2ph, end: g.end);
    };
  }

  /// Output sample rate.
  int get sampleRate => inflectSampleRate;

  /// Compiles the two Inflect graphs (text-encoder + decoder) for [backend].
  /// Heavy — call once, from a background isolate. [artifactPaths] is
  /// filename -> on-disk path for the bundle (from `RuntimeConfig`).
  static Future<InflectTtsCore> load({
    required TtsModelProfile profile,
    required Map<String, String> artifactPaths,
    PreferredBackend? backend,
  }) async {
    if (profile is! InflectProfile) {
      throw UnimplementedError(
        'InflectTtsCore: only TtsPipelineKind.inflectVits is implemented here',
      );
    }
    final bindings = LiteRtBindings.open();
    final accelerator = acceleratorFor(backend);

    // Track handles as they're created so a partial failure frees everything
    // already allocated (the LiteRT native heap is process-global). Mirrors
    // `TtsCore.load`.
    LiteRtEnvironment? environment;
    final loaded = <LoadedGraph>[];
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
      loaded.add(textEncoder);

      final decoder = loadLiteRtGraph(
        bindings,
        environment,
        _artifactPath(artifactPaths, profile.decoderFile),
        accelerator,
      );
      loaded.add(decoder);

      // Optional neural OOV G2P — only when the bundle carries dp_g2p + its
      // meta (Matcha's shared G2P). Absent (e.g. the enc+dec-only verification
      // harness) → neuralG2p is null and the frontend needs dictionary-covered
      // input.
      _InflectG2p? g2p;
      // The profile always DECLARES the G2P filenames; the optionality is
      // whether the bundle actually STAGED them — gate on containsKey alone.
      final g2pFile = profile.g2pFile;
      final g2pMetaFile = profile.g2pMetaFile;
      if (artifactPaths.containsKey(g2pFile) &&
          artifactPaths.containsKey(g2pMetaFile)) {
        final dpG2p = loadLiteRtGraph(
          bindings,
          environment,
          _artifactPath(artifactPaths, g2pFile),
          accelerator,
        );
        loaded.add(dpG2p);
        final meta =
            jsonDecode(
                  await File(
                    _artifactPath(artifactPaths, g2pMetaFile),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        g2p = _InflectG2p(
          graph: dpG2p,
          char2idx: (meta['char2idx'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, (v as num).toInt()),
          ),
          idx2ph: (meta['idx2ph'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(int.parse(k), v as String),
          ),
          charRepeats: (meta['char_repeats'] as num).toInt(),
          start: (meta['start'] as num).toInt(),
          end: (meta['end'] as num).toInt(),
          maxT: (meta['MAXT'] as num).toInt(),
          nPhonemes: (meta['n_phonemes'] as num).toInt(),
        );
      }

      gemmaLog(
        '[InflectTtsCore] loaded: backend=$backend, ${loaded.length} graphs '
        'compiled (neuralG2p=${g2p != null})',
      );
      return InflectTtsCore._(
        bindings: bindings,
        environment: environment,
        textEncoder: textEncoder,
        decoder: decoder,
        g2p: g2p,
      );
    } catch (_) {
      destroyGraphs(bindings, loaded);
      if (environment != null) bindings.destroyEnvironment(environment);
      rethrow;
    }
  }

  /// Synthesize [phonemeIds] (VITS/Tacotron symbol ids) to 16-bit LE PCM at
  /// [inflectSampleRate]. [noiseOverride] (length `T*128`, row-major
  /// frame-major) replaces the internal Gaussian — used by verification to
  /// inject the reference RNG stream; production omits it and draws from a
  /// fixed [seed].
  Uint8List synthesize(
    List<int> phonemeIds, {
    int seed = _defaultSeed,
    Float32List? noiseOverride,
  }) {
    if (_disposed) {
      throw StateError('InflectTtsCore is disposed');
    }
    final n = phonemeIds.length;
    if (n == 0) return Uint8List(0);
    final ids = Int32List.fromList(phonemeIds);

    // 1. Text encoder — outputs in declared order: m_p, logs_p, logw.
    final enc = runLiteRtGraph(
      _bindings,
      _textEncoder.compiledModel,
      0,
      [
        I32Input([1, n], ids),
      ],
      [
        [1, n, 128],
        [1, n, 128],
        [1, n, 1],
      ],
    );
    final mP = enc[0]; // [N*128]
    final logsP = enc[1]; // [N*128]
    final logw = enc[2]; // [N]

    // 2. Durations + length regulator (repeat each encoder frame).
    // Defensive vs garbage model output (e.g. #214 GPU output-garbage): a
    // non-finite logw would make exp().ceil() THROW ('Infinity or NaN toInt'),
    // and a large-but-finite logw would explode tFrames into an OOM Float32List
    // (Matcha survives both via .ceilToDouble() + its MAX_MEL chunk cap; this
    // pipeline has no chunk cap). Clamp each frame to [1, _maxFramesPerPhoneme]
    // so a degenerate frame degrades that phoneme instead of crashing the turn.
    var clamped = false;
    final durations = List<int>.generate(n, (t) {
      final e = math.exp(logw[t]);
      if (!e.isFinite || e > _maxFramesPerPhoneme) {
        clamped = true;
        return e.isFinite ? _maxFramesPerPhoneme : 1;
      }
      return e.ceil();
    });
    if (clamped) {
      gemmaLog(
        '[InflectTtsCore] clamped a non-finite/oversized duration frame — '
        'model output looks degenerate; audio may be distorted for that span.',
      );
    }
    var tFrames = 0;
    for (final d in durations) {
      tFrames += d;
    }
    if (tFrames == 0) return Uint8List(0);
    // Aggregate safety cap (see [_maxTotalFrames]): the per-phoneme clamp above
    // bounds each frame, but their SUM is still unbounded, so cap the total and
    // truncate rather than OOM. Loud log (no silent masking) — this only fires
    // on degenerate output, and the audio will be cut short for that turn.
    if (tFrames > _maxTotalFrames) {
      gemmaLog(
        '[InflectTtsCore] total length-regulated frames $tFrames exceeds cap '
        '$_maxTotalFrames — truncating; model output looks degenerate, audio '
        'will be cut short.',
      );
      tFrames = _maxTotalFrames;
    }

    final total = tFrames * 128;
    final mExp = Float32List(total);
    final lsExp = Float32List(total);
    var f = 0;
    outer:
    for (var t = 0; t < n; t++) {
      final base = t * 128;
      for (var r = 0; r < durations[t]; r++) {
        if (f >= tFrames) break outer; // aggregate cap reached — stop expanding
        final off = f * 128;
        mExp.setRange(off, off + 128, mP, base);
        lsExp.setRange(off, off + 128, logsP, base);
        f++;
      }
    }

    // 3. z_p = m_p_exp + noise * exp(logs_p_exp) * NOISE_SCALE.
    final zp = Float32List(total);
    if (noiseOverride != null) {
      if (noiseOverride.length != total) {
        throw ArgumentError(
          'noiseOverride length ${noiseOverride.length} != expected $total',
        );
      }
      for (var i = 0; i < total; i++) {
        zp[i] = mExp[i] + noiseOverride[i] * math.exp(lsExp[i]) * _noiseScale;
      }
    } else {
      final rnd = math.Random(seed);
      for (var i = 0; i < total; i++) {
        zp[i] = mExp[i] + nextGaussian(rnd) * math.exp(lsExp[i]) * _noiseScale;
      }
    }

    // 4. Decoder: z_p[1,T,128] -> waveform[1, T*HOP].
    final samples = tFrames * _hop;
    final dec = runLiteRtGraph(
      _bindings,
      _decoder.compiledModel,
      0,
      [
        F32Input([1, tFrames, 128], zp),
      ],
      [
        [1, samples],
      ],
    );
    final wav = dec[0];

    // 5. float32 [-1,1] -> 16-bit little-endian PCM.
    final pcm = Uint8List(wav.length * 2);
    final bd = ByteData.sublistView(pcm);
    var nanSamples = 0;
    for (var i = 0; i < wav.length; i++) {
      var s = wav[i];
      // NaN passes BOTH comparisons (all NaN comparisons are false), so it
      // would reach .round() and throw 'Infinity or NaN toInt'. Map a
      // non-finite sample to silence instead of crashing the whole utterance.
      if (s.isNaN) {
        s = 0.0;
        nanSamples++;
      } else if (s > 1.0) {
        s = 1.0;
      } else if (s < -1.0) {
        s = -1.0;
      }
      bd.setInt16(i * 2, (s * 32767).round(), Endian.little);
    }
    // Loud once (not per-sample) — NaN-to-silence is a degrade path, not
    // normal, so a fully-silent map would mask genuinely-broken decoder output.
    if (nanSamples > 0) {
      gemmaLog(
        '[InflectTtsCore] $nanSamples/${wav.length} decoder samples were NaN '
        '— mapped to silence; model output looks degenerate.',
      );
    }
    return pcm;
  }

  /// Destroys the compiled graphs' handles + the shared environment.
  /// Idempotent — a second call is a no-op.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final g2p = _g2p;
    destroyGraphs(_bindings, [
      _textEncoder,
      _decoder,
      if (g2p != null) g2p.graph,
    ]);
    _bindings.destroyEnvironment(_environment);
  }
}
