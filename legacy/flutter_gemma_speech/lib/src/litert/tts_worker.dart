// Long-lived background isolate that owns the entire Matcha-TTS pipeline:
// both the text frontend (`TtsTextFrontend`: dictionary G2P + host embedding
// gather) and the native LiteRT core (`TtsCore`: 4 compiled graphs + the
// CFM/vocoder forward passes). The forward passes are blocking synchronous
// FFI calls; running them (and the frontend's dictionary lookups +
// 275k-entry load) here keeps the UI isolate's event loop free. Direct
// analog of `stt_worker.dart` — see that file's header for the "why a
// long-lived worker and not `Isolate.run`" rationale (FFI handles can't
// cross isolate boundaries; the compiled models are expensive to build but
// cheap to run).
//
// Unlike `SttWorker` (which owns only `SttCore`, tokenizer included inside
// the core), this worker owns TWO objects: `TtsTextFrontend` and `TtsCore`.
// Setup loads both plus a `TtsTextNormalizer` (for `splitClauses`, needs no
// symbols). Each request splits `text` into clauses so the CFM decoder's
// `MAX_MEL` cap (and its perceptual quality — the model was trained on
// clause-length utterances) doesn't get exceeded by long replies: every
// clause is `frontend.encodeChunks`d (itself possibly >1 sub-chunk, for a
// clause too long to fit MAX_TEXT at a word boundary) and each resulting
// input is `core.synthesize`d with its own CFM seed (`ttsCfmSeed +
// clauseIndex`, so a single-clause single-chunk request's seed is
// unchanged). ALL resulting PCM segments — across clauses AND across a
// clause's own sub-chunks — are spliced with the same short silence gap
// (`concatPcmWithSilence`, `tts_chunk.dart`): the inter-clause gap is the
// intended pause, while an inter-sub-chunk gap (only for a pathological
// over-long clause, a MAX_TEXT split) is an acceptable ~0.12 s mid-sentence
// pause — unlike the MAX_MEL split inside `TtsCore.synthesize`, which is
// seamless (`TtsCore.concatSegments`, no silence). Only `TtsCore` holds
// native handles, so only `core.dispose()` runs in the teardown `finally`.
//
// Only sendable values cross the port: file paths + profile + backend
// (setup), a `String` (request), and a `Uint8List` of 16-bit PCM samples
// (reply).
//
// `_workerEntry` branches on `init.profile.pipeline` into `_runMatchaWorker`
// (the above, unchanged) or `_runQwen3Worker`: Qwen3-TTS is a from-scratch
// autoregressive codec-token LM (`Qwen3TtsCore`) with its own KV cache and
// no CFM step, so it needs neither
// `TtsTextFrontend`/`TtsTextNormalizer` (Matcha's dictionary G2P + host
// embedding gather + clause splitter) nor `TtsCore` (Matcha's native
// core) — it does its own byte-level BPE tokenization
// (`Qwen2BpeEncoder`, inside `Qwen3TtsCore`) and consumes a request's full
// text in ONE AR pass (no clause-splitting, no per-clause CFM seed, no
// inter-clause silence — see `_runQwen3Worker`'s doc for why those three
// Matcha-specific behaviors don't apply here).

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/utils/gemma_log.dart';

import '../model/tts_model_profile.dart';
import '../qwen3/npy_reader.dart';
import '../qwen3/qwen3_tts_core.dart';
import '../tts/inflect_text_frontend.dart';
import '../tts/tts_text_frontend.dart';
import '../tts/tts_text_normalizer.dart';
import 'inflect_tts_core.dart';
import 'tts_chunk.dart';
import 'tts_core.dart';

/// Handshake payload the worker sends back once the frontend + native model
/// are loaded. Carries [sampleRate] (read from `TtsCore` after load) so the
/// `LiteRtSpeechSynthesizer` facade can expose it synchronously without a
/// round-trip.
class _Ready {
  _Ready(this.commandPort, this.sampleRate);
  final SendPort commandPort;
  final int sampleRate;
}

/// Request: synthesize [text]. [id] correlates the reply.
class _SynthRequest {
  _SynthRequest(this.id, this.text);
  final int id;
  final String text;
}

/// Reply carrying the synthesized 16-bit LE mono PCM (or an error message).
class _SynthReply {
  _SynthReply(this.id, this.pcm, this.error);
  final int id;
  final Uint8List? pcm;
  final String? error;
}

/// Sentinel asking the worker to tear down the native model and exit.
class _Close {
  const _Close();
}

/// Ack the worker sends after [TtsCore.dispose] completes, so the main
/// isolate can kill the isolate without racing native teardown.
class _CloseAck {
  const _CloseAck();
}

/// Parameters needed to boot the worker isolate. Must be fully sendable.
class _WorkerInit {
  _WorkerInit({
    required this.replyTo,
    required this.profile,
    required this.artifactPaths,
    required this.backend,
    required this.logLevel,
    required this.language,
    required this.voice,
  });
  final SendPort replyTo;
  final TtsModelProfile profile;
  final Map<String, String> artifactPaths;
  final PreferredBackend? backend;

  /// Snapshot of the main-isolate [gemmaLogLevel] at spawn — the worker
  /// isolate gets its own copy of the per-isolate top-level (default info),
  /// so it must be seeded explicitly.
  final GemmaLogLevel logLevel;

  /// Qwen3-only: the `Qwen3Prompt.languageIds` key (case-insensitive) or
  /// `'auto'`, forwarded verbatim to every `Qwen3TtsCore.synthesizePcm16`
  /// call. Ignored by [_runMatchaWorker] (Matcha has no language parameter —
  /// its locale comes from [TtsModelProfile.locale] instead). Validated by
  /// `LiteRtSpeechSynthesizer.create` before the worker is even spawned, so
  /// by the time it reaches here it is always a supported value.
  final String language;

  /// Qwen3-only: forward-compat speaker x-vector override (`[1024]`); null
  /// uses the bundle's single demo voice (`voices/demo_speaker.npy`, read in
  /// [_runQwen3Worker]). Ignored by [_runMatchaWorker]. See
  /// `LiteRtSpeechSynthesizer.create`'s [voice] doc — v1 does not surface a
  /// voice picker anywhere; this only exists so a future multi-voice release
  /// doesn't need a breaking signature change.
  final Float32List? voice;
}

/// Main-isolate handle to the TTS worker. Spawns the isolate, performs the
/// load handshake, and multiplexes concurrent requests by id.
class TtsWorker {
  TtsWorker._(
    this._isolate,
    this._commandPort,
    this._fromWorker,
    this._sampleRate,
  );

  final Isolate _isolate;
  final SendPort _commandPort;
  final ReceivePort _fromWorker;
  final int _sampleRate;

  final _pending = <int, Completer<Uint8List>>{};
  int _nextId = 0;
  bool _closed = false;
  Completer<void>? _closeAck;

  /// Spawn the worker and wait until the frontend + native model are loaded.
  ///
  /// [language] is Qwen3-only (see [_WorkerInit.language]'s doc); Matcha
  /// ignores it. Defaults to `'english'` so every existing (Matcha) caller
  /// is unaffected. [voice] is Qwen3-only (see [_WorkerInit.voice]'s doc);
  /// null (the default) uses the bundle's demo voice.
  static Future<TtsWorker> spawn({
    required TtsModelProfile profile,
    required Map<String, String> artifactPaths,
    PreferredBackend? backend,
    String language = 'english',
    Float32List? voice,
  }) async {
    final fromWorker = ReceivePort();
    final readyCompleter = Completer<_Ready>();

    // First message from the worker is either _Ready or a String error. A
    // `null` is the isolate's onExit signal — if it arrives before _Ready,
    // the worker died during load (e.g. a native crash compiling a corrupt
    // model), so fail the completer instead of hanging forever.
    late final StreamSubscription sub;
    sub = fromWorker.listen((msg) {
      if (msg is _Ready) {
        readyCompleter.complete(msg);
      } else if (msg is String) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(StateError(msg));
        }
      } else if (msg == null) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(
            StateError('TTS worker isolate exited during load'),
          );
        }
      }
    });

    // Wrap BOTH the spawn and the ready-wait: if Isolate.spawn itself throws
    // (e.g. resource exhaustion) fromWorker/sub would otherwise leak.
    Isolate? isolate;
    final _Ready ready;
    try {
      isolate = await Isolate.spawn(
        _workerEntry,
        _WorkerInit(
          replyTo: fromWorker.sendPort,
          profile: profile,
          artifactPaths: artifactPaths,
          backend: backend,
          logLevel: gemmaLogLevel,
          language: language,
          voice: voice,
        ),
        // onExit posts `null` to fromWorker so we never wait on a dead isolate.
        onExit: fromWorker.sendPort,
        debugName: 'litert-tts-worker',
      );
      ready = await readyCompleter.future;
    } catch (_) {
      await sub.cancel();
      fromWorker.close();
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    }

    final worker = TtsWorker._(
      isolate,
      ready.commandPort,
      fromWorker,
      ready.sampleRate,
    );
    // Re-point the subscription at the steady-state reply handler.
    sub.onData(worker._onReply);
    return worker;
  }

  /// Output sample rate (Hz), learned from the load handshake.
  int get sampleRate => _sampleRate;

  void _onReply(dynamic msg) {
    if (msg is _SynthReply) {
      final completer = _pending.remove(msg.id);
      if (completer == null) return;
      if (msg.error != null) {
        completer.completeError(StateError(msg.error!));
      } else {
        completer.complete(msg.pcm!);
      }
    } else if (msg is _CloseAck) {
      if (_closeAck?.isCompleted == false) _closeAck?.complete();
    } else if (msg == null) {
      // onExit: the worker isolate died. If this is part of a normal close,
      // the ack path already handled it; otherwise it's an unexpected crash
      // — fail every in-flight request rather than leave callers hanging.
      _failAllPending('TTS worker isolate exited unexpectedly');
      _closed = true;
      if (_closeAck?.isCompleted == false) _closeAck?.complete();
    }
  }

  void _failAllPending(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(reason));
    }
    _pending.clear();
  }

  /// Synthesize [text] → 16-bit LE mono PCM. The frontend encode + native
  /// forward passes run in the worker; the UI isolate stays free.
  Future<Uint8List> synthesize(String text) {
    if (_closed) {
      return Future.error(StateError('TtsWorker is closed'));
    }
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    _commandPort.send(_SynthRequest(id, text));
    return completer.future;
  }

  /// Tear down the native model + frontend and stop the isolate. Waits for
  /// the worker to finish native teardown (a _CloseAck, or the isolate's
  /// onExit) before killing it, so handles are never freed mid-dispose.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closeAck = Completer<void>();
    _commandPort.send(const _Close());
    // Wait for the worker's dispose ack / exit; cap the wait so a wedged
    // native teardown can't hang close() forever.
    try {
      await _closeAck!.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Timed out or errored — fall through to a forced kill below.
      gemmaLog(
        '⚠️  TtsWorker.close(): native teardown ack timed out — forcing kill',
      );
    }
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _failAllPending('TtsWorker closed mid-request');
  }
}

/// Isolate entry point. Seeds the per-isolate log level, then dispatches to
/// the pipeline-specific arm ([_runMatchaWorker] / [_runQwen3Worker]) —
/// see this file's header for why the two pipelines don't share a request
/// loop.
Future<void> _workerEntry(_WorkerInit init) async {
  // Seed this isolate's per-isolate log level from the main-isolate snapshot.
  gemmaLogLevel = init.logLevel;
  switch (init.profile.pipeline) {
    case TtsPipelineKind.matchaCfm:
      await _runMatchaWorker(init);
    case TtsPipelineKind.qwen3ArCodec:
      await _runQwen3Worker(init);
    case TtsPipelineKind.inflectVits:
      await _runInflectWorker(init);
  }
}

/// Matcha-CFM arm of [_workerEntry] — loads `TtsTextFrontend` + `TtsCore`
/// and serves requests via the clause-split / per-clause-CFM-seed /
/// inter-clause-silence loop described in this file's header. Qwen3-TTS
/// dispatches to [_runQwen3Worker] instead.
Future<void> _runMatchaWorker(_WorkerInit init) async {
  final TtsCore core;
  final TtsTextFrontend frontend;
  final TtsTextNormalizer normalizer;
  // Tracks the core once TtsCore.load succeeds, purely so the catch block
  // below can free it if a LATER step (frontend or normalizer) throws —
  // otherwise a fully-loaded native core (4 compiled graphs + environment)
  // would be abandoned: isolate exit does not free FFI/native allocations.
  TtsCore? loadedCore;
  try {
    // Core loads first: the frontend needs `core.neuralG2p` (the dp_g2p
    // graph) to resolve out-of-vocabulary words that aren't in the
    // dictionary. Loading order doesn't affect output — only which OOV
    // words the frontend can resolve without throwing.
    core = await TtsCore.load(
      profile: init.profile,
      artifactPaths: init.artifactPaths,
      backend: init.backend,
    );
    loadedCore = core;
    frontend = await TtsTextFrontend.load(
      init.profile,
      init.artifactPaths,
      neuralG2p: core.neuralG2p,
    );
    // splitClauses only reads punctuation, so an empty symbol set is fine —
    // the normalizer is built purely to reuse the locale-selected clause
    // splitter, not to normalize/encode text (that stays `frontend.encode`).
    // Built inside the try so a future non-`en` locale's UnimplementedError
    // surfaces as a descriptive load-failure reply instead of a bare
    // isolate exit.
    normalizer = TtsTextNormalizer.forLocale(init.profile.locale, {});
  } catch (e, st) {
    loadedCore?.dispose();
    gemmaLog('[TtsWorker] load failed: $e\n$st');
    init.replyTo.send('TTS worker failed to load: $e');
    return;
  }

  final commandPort = ReceivePort();
  init.replyTo.send(_Ready(commandPort.sendPort, core.sampleRate));

  try {
    await for (final msg in commandPort) {
      if (msg is _SynthRequest) {
        try {
          final clauses = normalizer.splitClauses(msg.text);
          final units = clauses.isEmpty ? <String>[msg.text] : clauses;
          final segs = <Uint8List>[];
          for (var i = 0; i < units.length; i++) {
            for (final input in frontend.encodeChunks(units[i])) {
              if (input.realLen <= 1) continue; // empty chunk → no audio.
              segs.add(core.synthesize(input, seed: ttsCfmSeed + i));
            }
          }
          final pcm = segs.isEmpty
              ? Uint8List(0)
              : concatPcmWithSilence(
                  segs,
                  silenceSamples: (core.sampleRate * 0.12).round(),
                );
          init.replyTo.send(_SynthReply(msg.id, pcm, null));
        } catch (e) {
          init.replyTo.send(_SynthReply(msg.id, null, e.toString()));
        }
      } else if (msg is _Close) {
        commandPort.close();
        break;
      }
    }
  } finally {
    // Only the native core holds handles to free — the frontend is pure
    // Dart (dictionary map + embedding table), nothing to dispose there.
    // Always dispose even if the loop exits unexpectedly, then ack so the
    // main isolate can kill us without racing teardown.
    core.dispose();
    init.replyTo.send(const _CloseAck());
  }
}

/// Inflect-Nano-v2 arm of [_workerEntry]. Loads `InflectTtsCore` (the VITS
/// text-encoder + decoder, plus the shared dp_g2p neural OOV G2P when the
/// bundle carries it) + `InflectTextFrontend`, and serves each request by
/// splitting into clauses, phonemizing (dictionary + neural OOV), synthesizing
/// per clause, and splicing with a short inter-clause silence — the same shape
/// as [_runMatchaWorker] minus the CFM-seed (Inflect's noise is a fixed-seed
/// Gaussian inside `InflectTtsCore.synthesize`) and minus `encodeChunks` (the
/// encoder/decoder are dynamic-length, no MAX_MEL cap to chunk under).
Future<void> _runInflectWorker(_WorkerInit init) async {
  final InflectTtsCore core;
  final InflectTextFrontend frontend;
  final TtsTextNormalizer normalizer;
  InflectTtsCore? loadedCore;
  try {
    core = await InflectTtsCore.load(
      profile: init.profile,
      artifactPaths: init.artifactPaths,
      backend: init.backend,
    );
    loadedCore = core;
    frontend = await InflectTextFrontend.load(
      init.profile,
      init.artifactPaths,
      neuralG2p: core.neuralG2p,
    );
    normalizer = TtsTextNormalizer.forLocale(init.profile.locale, {});
  } catch (e, st) {
    loadedCore?.dispose();
    gemmaLog('[TtsWorker] inflect load failed: $e\n$st');
    init.replyTo.send('TTS worker failed to load: $e');
    return;
  }

  final commandPort = ReceivePort();
  init.replyTo.send(_Ready(commandPort.sendPort, core.sampleRate));

  try {
    await for (final msg in commandPort) {
      if (msg is _SynthRequest) {
        try {
          final clauses = normalizer.splitClauses(msg.text);
          final units = clauses.isEmpty ? <String>[msg.text] : clauses;
          final segs = <Uint8List>[];
          for (final unit in units) {
            final ids = frontend.encode(unit);
            if (ids.isEmpty) continue; // non-speech clause → no audio.
            segs.add(core.synthesize(ids));
          }
          final pcm = segs.isEmpty
              ? Uint8List(0)
              : concatPcmWithSilence(
                  segs,
                  silenceSamples: (core.sampleRate * 0.12).round(),
                );
          init.replyTo.send(_SynthReply(msg.id, pcm, null));
        } catch (e) {
          init.replyTo.send(_SynthReply(msg.id, null, e.toString()));
        }
      } else if (msg is _Close) {
        commandPort.close();
        break;
      }
    }
  } finally {
    core.dispose();
    init.replyTo.send(const _CloseAck());
  }
}

/// Qwen3-TTS arm of [_workerEntry]. Loads `Qwen3TtsCore` (the talker/MTP/
/// codec graphs + host tables + BPE encoder) and the bundle's one
/// demo-voice x-vector, then serves requests with exactly ONE
/// `core.synthesizePcm16` call per request.
///
/// Deliberately does NOT reuse [_runMatchaWorker]'s clause-split / CFM-seed
/// / inter-clause-silence loop — none of those three apply here:
/// - No clause-splitting (`TtsTextNormalizer.splitClauses`): that exists
///   only to keep each chunk under the CFM decoder's `MAX_MEL` cap. Qwen3 is
///   autoregressive over its own KV cache and has no such per-call length
///   ceiling — it consumes a request's full text in one AR pass
///   (`Qwen3TtsCore.synthesize`'s `maxFrames`, not a text-length limit).
/// - No CFM seed (`ttsCfmSeed + clauseIndex`): Qwen3 has no CFM step; its
///   only randomness is `pickSampled`'s token sampling (see
///   [Qwen3TtsCore.synthesizePcm16]'s sampling path), seeded once per call
///   via `Qwen3TtsCore.synthesizePcm16`'s own `seed` param (left unset
///   here — see `doSample`'s doc below).
/// - No `concatPcmWithSilence`: there is only ever one segment per request
///   (no per-clause splitting to splice back together).
///
/// [Qwen3TtsCore.load] uses its default `talkerFileName`
/// (`talker_int4.tflite`, the quantized runtime artifact — NOT the fp32
/// artifact the golden-gate tests load) — this is the runtime path real
/// users hit, not a correctness gate.
///
/// `doSample: true` on every call (the runtime default is varied, natural
/// prosody; a fixed `seed` would make every synthesis of the same text
/// sound identical). The fp32-greedy
/// byte-for-byte golden gate lives in `qwen3_synthesize_test.dart`
/// (`Qwen3TtsCore.synthesize` driven directly with `doSample: false`), not
/// here — this worker never runs greedy.
///
/// v1 ships exactly one voice: the bundle's `demo_speaker.npy` x-vector
/// (the model bundle's asset manifest), read once at load time via
/// [readNpyF32] unless [_WorkerInit.voice] overrides it — no voice PICKER
/// yet (`init.voice` is forward-compat-only; the UI never sets it, see
/// [_WorkerInit.voice]'s doc). `init.language` is the per-call knob this
/// worker threads through to `Qwen3TtsCore.synthesizePcm16`, validated up
/// front by `LiteRtSpeechSynthesizer.create` (`assertQwen3LanguageSupported`),
/// which is also what surfaces a real language picker (via
/// `qwen3SupportedLanguages`); see [_WorkerInit.language]'s doc.
///
/// Fail-loud (per Global Constraints / the project's no-masking-fallback
/// rule): if [Qwen3TtsCore.load] or the demo-voice read throws, this sends
/// the error back to the main isolate exactly like [_runMatchaWorker]'s
/// load failure does — it NEVER falls back to the Matcha path.
Future<void> _runQwen3Worker(_WorkerInit init) async {
  final Qwen3TtsCore core;
  final Float32List demoVoice;
  // Same "track the core once load succeeds" rationale as
  // [_runMatchaWorker]'s `loadedCore` — a fully-loaded native core (3
  // compiled graphs + environment + tables) must not be leaked if the
  // demo-voice read fails right after.
  Qwen3TtsCore? loadedCore;
  try {
    core = await Qwen3TtsCore.load(
      artifactPaths: init.artifactPaths,
      backend: init.backend,
    );
    loadedCore = core;
    final demoVoicePath = init.artifactPaths['demo_speaker.npy'];
    if (demoVoicePath == null) {
      throw StateError(
        'TtsWorker: qwen3 bundle is missing "demo_speaker.npy" in '
        'artifactPaths',
      );
    }
    // [_WorkerInit.voice] overrides the bundle's demo voice when set
    // (forward-compat only — v1's UI never sets it). The manifest presence
    // check above stays unconditional even then: the bundle always ships
    // demo_speaker.npy in v1, so its absence is still a load-time bug worth
    // surfacing regardless of whether an override happens to be in play.
    demoVoice = init.voice ?? readNpyF32(demoVoicePath);
  } catch (e, st) {
    loadedCore?.dispose();
    gemmaLog('[TtsWorker] qwen3 load failed: $e\n$st');
    init.replyTo.send('TTS worker failed to load: $e');
    return;
  }

  final commandPort = ReceivePort();
  init.replyTo.send(_Ready(commandPort.sendPort, core.sampleRate));

  try {
    await for (final msg in commandPort) {
      if (msg is _SynthRequest) {
        try {
          final pcm = core.synthesizePcm16(
            msg.text,
            speaker: demoVoice,
            language: init.language,
            doSample: true,
          );
          init.replyTo.send(_SynthReply(msg.id, pcm, null));
        } catch (e) {
          init.replyTo.send(_SynthReply(msg.id, null, e.toString()));
        }
      } else if (msg is _Close) {
        commandPort.close();
        break;
      }
    }
  } finally {
    // Qwen3TtsCore.dispose() also frees the tables/tokenizer it owns
    // internally (unlike Matcha, where the frontend is separate pure-Dart
    // state) — only the core needs disposing here.
    core.dispose();
    init.replyTo.send(const _CloseAck());
  }
}
