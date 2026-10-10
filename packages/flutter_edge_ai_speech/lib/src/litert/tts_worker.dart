// Long-lived background isolate that owns the entire Matcha-TTS pipeline:
// both the text frontend (`TtsTextFrontend`: dictionary G2P + host embedding
// gather) and the native LiteRT core (`TtsCore`: 4 compiled graphs + the
// CFM/vocoder forward passes). The forward passes are blocking synchronous
// FFI calls; running them (and the frontend's dictionary lookups +
// 275k-entry load) here keeps the UI isolate's event loop free. Direct
// analog of `stt_worker.dart` — see that file's header for the "why a
// long-lived worker and not `Isolate.run`" rationale (FFI handles can't
// cross isolate boundaries; the compiled models are expensive to build but
// cheap to run) and for why close never kills the isolate.
//
// Unlike `SttWorker` (which owns only `SttCore`, tokenizer included inside
// the core), the Matcha engine owns TWO objects: `TtsTextFrontend` and
// `TtsCore`. Setup loads both plus a `TtsTextNormalizer` (for
// `splitClauses`, needs no symbols). Each request splits `text` into clauses
// so the CFM decoder's `MAX_MEL` cap (and its perceptual quality — the model
// was trained on clause-length utterances) doesn't get exceeded by long
// replies: every clause is `frontend.encodeChunks`d (itself possibly >1
// sub-chunk, for a clause too long to fit MAX_TEXT at a word boundary) and
// each resulting input is `core.synthesize`d with its own CFM seed
// (`ttsCfmSeed + clauseIndex`, so a single-clause single-chunk request's seed
// is unchanged). ALL resulting PCM segments — across clauses AND across a
// clause's own sub-chunks — are spliced with the same short silence gap
// (`concatPcmWithSilence`, `tts_chunk.dart`): the inter-clause gap is the
// intended pause, while an inter-sub-chunk gap (only for a pathological
// over-long clause, a MAX_TEXT split) is an acceptable ~0.12 s mid-sentence
// pause — unlike the MAX_MEL split inside `TtsCore.synthesize`, which is
// seamless (`TtsCore.concatSegments`, no silence). Only `TtsCore` holds
// native handles, so only `core.dispose()` runs at teardown.
//
// Only sendable values cross the port: file paths + profile + backend
// (setup), a `String` (request), and a `Uint8List` of 16-bit PCM samples
// (reply).
//
// The worker loop is one for every pipeline; what differs is the
// [TtsWorkerEngine] it drives, chosen by `init.profile.pipeline`:
// [_MatchaEngine] (the above), [_InflectEngine], or [_Qwen3Engine]. Qwen3-TTS
// is a from-scratch autoregressive codec-token LM (`Qwen3TtsCore`) with its
// own KV cache and no CFM step, so it needs neither
// `TtsTextFrontend`/`TtsTextNormalizer` (Matcha's dictionary G2P + host
// embedding gather + clause splitter) nor `TtsCore` (Matcha's native core) —
// it does its own byte-level BPE tokenization (`Qwen2BpeEncoder`, inside
// `Qwen3TtsCore`) and consumes a request's full text in ONE AR pass (no
// clause-splitting, no per-clause CFM seed, no inter-clause silence — see
// [_Qwen3Engine]'s doc for why those three Matcha-specific behaviors don't
// apply here).

import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import '../model/tts_model_profile.dart';
import '../qwen3/npy_reader.dart';
import '../qwen3/qwen3_tts_core.dart';
import '../tts/inflect_text_frontend.dart';
import '../tts/tts_text_frontend.dart';
import '../tts/tts_text_normalizer.dart';
import 'inflect_tts_core.dart';
import 'tts_chunk.dart';
import 'tts_core.dart';

/// What [TtsWorker] drives inside its isolate. Production picks one per
/// [TtsPipelineKind] (`_productionTtsEngine`); tests inject a fake through
/// [TtsWorker.spawn]'s `engineFactory`.
abstract interface class TtsWorkerEngine {
  /// Loads the frontend and native model. When it throws, the worker calls
  /// [dispose] before it reports the error, so whatever loaded is freed.
  Future<void> load();

  /// Output sample rate (Hz). Read once, right after [load].
  int get sampleRate;

  /// Synthesizes [text] into 16-bit LE mono PCM. May block the isolate in
  /// synchronous FFI.
  Uint8List synthesize(String text);

  /// Frees every native handle. Called exactly once, also after a failed
  /// [load], so it must cope with a partial one.
  void dispose();
}

/// Builds the engine inside the worker isolate. Must be a top-level function
/// or a static method: it crosses the isolate boundary inside the spawn
/// message. Construction must not allocate anything native — that is
/// [TtsWorkerEngine.load]'s job, so a failure there can be cleaned up.
typedef TtsWorkerEngineFactory =
    TtsWorkerEngine Function({
      required TtsModelProfile profile,
      required Map<String, String> artifactPaths,
      PreferredBackend? backend,
      required String language,
      Float32List? voice,
    });

/// Handshake payload the worker sends back once the frontend + native model
/// are loaded. Carries [sampleRate] (read from the engine after load) so the
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

/// Sentinel asking the worker to stop: fail every request that has not
/// started, let the one in flight finish, dispose the model, ack, exit.
class _Close {
  const _Close();
}

/// The worker's last message, sent through `Isolate.exit` once
/// [TtsWorkerEngine.dispose] has returned — so nothing of the worker runs
/// after it. [error] is set when that dispose threw: the native model may then
/// still be resident, and the main isolate says so.
class _CloseAck {
  const _CloseAck(this.error);
  final String? error;
}

/// The error a request gets when the worker closed before it started.
const _closedBeforeRunMessage = 'TtsWorker closed before this request ran';

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
    required this.engineFactory,
  });
  final SendPort replyTo;
  final TtsModelProfile profile;
  final Map<String, String> artifactPaths;
  final PreferredBackend? backend;

  /// Snapshot of the main-isolate [edgeAiLogLevel] at spawn — the worker
  /// isolate gets its own copy of the per-isolate top-level (default info),
  /// so it must be seeded explicitly.
  final EdgeAiLogLevel logLevel;

  /// Qwen3-only: the `Qwen3Prompt.languageIds` key (case-insensitive) or
  /// `'auto'`, forwarded verbatim to every `Qwen3TtsCore.synthesizePcm16`
  /// call. Ignored by [_MatchaEngine] (Matcha has no language parameter —
  /// its locale comes from [TtsModelProfile.locale] instead). Validated by
  /// `LiteRtSpeechSynthesizer.create` before the worker is even spawned, so
  /// by the time it reaches here it is always a supported value.
  final String language;

  /// Qwen3-only: forward-compat speaker x-vector override (`[1024]`); null
  /// uses the bundle's single demo voice (`voices/demo_speaker.npy`, read in
  /// [_Qwen3Engine.load]). Ignored by [_MatchaEngine]. See
  /// `LiteRtSpeechSynthesizer.create`'s [voice] doc — v1 does not surface a
  /// voice picker anywhere; this only exists so a future multi-voice release
  /// doesn't need a breaking signature change.
  final Float32List? voice;

  final TtsWorkerEngineFactory engineFactory;
}

/// Main-isolate handle to the TTS worker. Spawns the isolate, performs the
/// load handshake, and multiplexes concurrent requests by id.
class TtsWorker {
  TtsWorker._(
    this._commandPort,
    this._fromWorker,
    this._sampleRate,
    this._modelName,
  );

  /// How long [close] waits before saying it is still waiting. It keeps
  /// waiting afterwards: the only way to stop sooner is to kill the isolate,
  /// and a killed isolate never frees its native model.
  static const _slowCloseNotice = Duration(seconds: 30);

  final SendPort _commandPort;
  final ReceivePort _fromWorker;
  final int _sampleRate;

  /// Names the model in the warnings this class prints.
  final String _modelName;

  final _pending = <int, Completer<Uint8List>>{};
  int _nextId = 0;

  /// True from the moment [close] is called, or the worker dies; [synthesize]
  /// refuses from then on.
  bool _closing = false;

  /// Why the worker is gone when it went without being asked to — the text
  /// every later [synthesize] fails with. Null otherwise.
  String? _deathReason;

  /// The error an uncaught exception in the worker reported through the
  /// spawn's `onError` port, kept until the `onExit` that follows it.
  String? _crashError;

  /// True once the worker's [_CloseAck] arrived; the `onExit` after it is the
  /// normal end, not a death.
  bool _acked = false;

  /// Completes when the worker is gone: its [_CloseAck], or its onExit.
  final _gone = Completer<void>();

  /// The one teardown every [close] call shares.
  Future<void>? _closeFuture;

  /// Spawn the worker and wait until the frontend + native model are loaded.
  ///
  /// [language] is Qwen3-only (see [_WorkerInit.language]'s doc); Matcha
  /// ignores it. Defaults to `'english'` so every existing (Matcha) caller
  /// is unaffected. [voice] is Qwen3-only (see [_WorkerInit.voice]'s doc);
  /// null (the default) uses the bundle's demo voice. [engineFactory] is the
  /// test seam; production leaves it null and gets the engine for
  /// [profile]'s pipeline.
  static Future<TtsWorker> spawn({
    required TtsModelProfile profile,
    required Map<String, String> artifactPaths,
    PreferredBackend? backend,
    String language = 'english',
    Float32List? voice,
    @visibleForTesting TtsWorkerEngineFactory? engineFactory,
  }) async {
    final fromWorker = ReceivePort();
    final readyCompleter = Completer<_Ready>();

    // First message from the worker is either _Ready or a String error. A
    // two-element List is an uncaught error (the onError port), and a `null`
    // is the isolate's onExit signal — if either arrives before _Ready, the
    // worker died during load (e.g. a native crash compiling a corrupt
    // model), so fail the completer instead of hanging forever.
    late final StreamSubscription<dynamic> sub;
    sub = fromWorker.listen((msg) {
      if (readyCompleter.isCompleted) return;
      if (msg is _Ready) {
        readyCompleter.complete(msg);
      } else if (msg is String) {
        readyCompleter.completeError(StateError(msg));
      } else if (msg is List) {
        readyCompleter.completeError(
          StateError('TTS worker isolate failed during load: ${msg.first}'),
        );
      } else if (msg == null) {
        readyCompleter.completeError(
          StateError('TTS worker isolate exited during load'),
        );
      }
    });

    final _Ready ready;
    try {
      await Isolate.spawn(
        _workerEntry,
        _WorkerInit(
          replyTo: fromWorker.sendPort,
          profile: profile,
          artifactPaths: artifactPaths,
          backend: backend,
          logLevel: edgeAiLogLevel,
          language: language,
          voice: voice,
          engineFactory: engineFactory ?? _productionTtsEngine,
        ),
        // onError + onExit post to fromWorker so we never wait on a dead
        // isolate, and learn why it died when it says.
        onError: fromWorker.sendPort,
        onExit: fromWorker.sendPort,
        debugName: 'litert-tts-worker',
      );
      ready = await readyCompleter.future;
    } catch (_) {
      // Nothing to kill. A worker that fails to load disposes whatever it
      // built and leaves through `Isolate.exit` carrying the error, and the
      // onExit `null` means it is already gone. Killing it here instead could
      // land before that dispose — the leak [close] no longer has.
      await sub.cancel();
      fromWorker.close();
      rethrow;
    }

    final worker = TtsWorker._(
      ready.commandPort,
      fromWorker,
      ready.sampleRate,
      _describeModel(profile, artifactPaths),
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
      _acked = true;
      final error = msg.error;
      if (error != null) {
        _warn(
          '$_modelName failed to dispose; its native model may still be '
          'resident: $error',
        );
      }
      if (!_gone.isCompleted) _gone.complete();
    } else if (msg is List) {
      // onError: an uncaught error is about to take the worker down. The
      // onExit `null` that follows reports it.
      _crashError = '${msg.first}';
    } else if (msg == null) {
      if (_acked) return; // the normal exit after a _CloseAck.
      // The worker died without acking — an uncaught error, or an isolate
      // killed from outside. Its model may still be resident; fail every
      // pending request rather than leave callers hanging, and refuse new
      // ones with the reason.
      final crash = _crashError;
      final what = _closeFuture == null
          ? 'exited unexpectedly'
          : 'exited while closing';
      final reason =
          'the TTS worker isolate $what${crash == null ? '' : ': $crash'}';
      _deathReason = reason;
      _closing = true;
      _failAllPending(reason);
      _fromWorker.close();
      _warn('$reason ($_modelName); its native model may still be resident');
      if (!_gone.isCompleted) _gone.complete();
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
    if (_closing) {
      final death = _deathReason;
      return Future.error(
        StateError(
          death == null ? 'TtsWorker is closed' : 'TtsWorker is closed: $death',
        ),
      );
    }
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    _commandPort.send(_SynthRequest(id, text));
    return completer.future;
  }

  /// Stops the worker without abandoning its native model.
  ///
  /// Requests that have not started fail with a "closed" [StateError]. The one
  /// in flight — the worker serves one at a time — finishes and gets its PCM.
  /// Then the worker disposes the model, acks and exits, and this returns.
  ///
  /// It waits for all of that however long the call in flight takes, and
  /// never kills the isolate: a killed isolate runs no more Dart code, so its
  /// model is never disposed and stays resident for the life of the process.
  /// After [_slowCloseNotice] it says what it is waiting for, once.
  ///
  /// Idempotent; concurrent callers share one teardown.
  Future<void> close() => _closeFuture ??= _shutDown();

  Future<void> _shutDown() async {
    _closing = true;
    if (!_gone.isCompleted) {
      _commandPort.send(const _Close());
      final notice = Timer(
        _slowCloseNotice,
        () => _warn(
          'TtsWorker.close() has waited ${_slowCloseNotice.inSeconds} s for '
          'the worker of $_modelName to finish the synthesis it is running, '
          'if any, and dispose its native model. It keeps waiting rather than '
          'kill the worker, because a killed worker never frees its native '
          'model.',
        ),
      );
      try {
        await _gone.future;
      } finally {
        notice.cancel();
      }
    }
    _fromWorker.close();
    // The worker answers every request it received before it acks, and the
    // port delivers in order, so this is empty — unless the worker died, and
    // then onExit has already failed them. A net, not a path.
    _failAllPending(_closedBeforeRunMessage);
  }

  /// `print`, not [edgeAiLog]: edgeAiLog is silent in release, and release is
  /// where a leaked native model or a hung close gets debugged. Both are
  /// abnormal, so this costs nothing in the normal case.
  static void _warn(String message) {
    // ignore: avoid_print
    print('[flutter_edge_ai_speech] WARNING: $message');
  }
}

/// Names a model in warnings: its pipeline, and the directory its files are
/// in when there are any.
String _describeModel(
  TtsModelProfile profile,
  Map<String, String> artifactPaths,
) {
  final files = artifactPaths.values;
  final where = files.isEmpty ? '' : ' in ${File(files.first).parent.path}';
  return 'the ${profile.pipeline.name} TTS model$where';
}

/// The production engine for [profile]'s pipeline. Fail-loud: each pipeline
/// gets its own engine and NEVER falls back to another one.
TtsWorkerEngine _productionTtsEngine({
  required TtsModelProfile profile,
  required Map<String, String> artifactPaths,
  PreferredBackend? backend,
  required String language,
  Float32List? voice,
}) => switch (profile.pipeline) {
  TtsPipelineKind.matchaCfm => _MatchaEngine(profile, artifactPaths, backend),
  TtsPipelineKind.qwen3ArCodec => _Qwen3Engine(
    artifactPaths,
    backend,
    language,
    voice,
  ),
  TtsPipelineKind.inflectVits => _InflectEngine(
    profile,
    artifactPaths,
    backend,
  ),
};

/// Thrown by an engine used before its [TtsWorkerEngine.load] completed — the
/// worker never does that, so this is a bug, not a user error.
StateError _notLoaded() => StateError('TTS engine used before it was loaded');

/// Matcha-CFM engine — loads `TtsTextFrontend` + `TtsCore` and serves
/// requests via the clause-split / per-clause-CFM-seed / inter-clause-silence
/// loop described in this file's header.
final class _MatchaEngine implements TtsWorkerEngine {
  _MatchaEngine(this._profile, this._artifactPaths, this._backend);

  final TtsModelProfile _profile;
  final Map<String, String> _artifactPaths;
  final PreferredBackend? _backend;

  /// Set the moment `TtsCore.load` returns, so [dispose] frees it if a LATER
  /// step (frontend or normalizer) throws — otherwise a fully-loaded native
  /// core (4 compiled graphs + environment) would be abandoned: isolate exit
  /// does not free FFI/native allocations.
  TtsCore? _core;

  ({TtsCore core, TtsTextFrontend frontend, TtsTextNormalizer normalizer})?
  _loaded;

  @override
  Future<void> load() async {
    // Core loads first: the frontend needs `core.neuralG2p` (the dp_g2p
    // graph) to resolve out-of-vocabulary words that aren't in the
    // dictionary. Loading order doesn't affect output — only which OOV
    // words the frontend can resolve without throwing.
    final core = _core = await TtsCore.load(
      profile: _profile,
      artifactPaths: _artifactPaths,
      backend: _backend,
    );
    final frontend = await TtsTextFrontend.load(
      _profile,
      _artifactPaths,
      neuralG2p: core.neuralG2p,
    );
    // splitClauses only reads punctuation, so an empty symbol set is fine —
    // the normalizer is built purely to reuse the locale-selected clause
    // splitter, not to normalize/encode text (that stays `frontend.encode`).
    // Built inside load so a future non-`en` locale's UnimplementedError
    // surfaces as a descriptive load-failure reply instead of a bare
    // isolate exit.
    final normalizer = TtsTextNormalizer.forLocale(_profile.locale, {});
    _loaded = (core: core, frontend: frontend, normalizer: normalizer);
  }

  @override
  int get sampleRate => (_loaded ?? (throw _notLoaded())).core.sampleRate;

  @override
  Uint8List synthesize(String text) {
    final (:core, :frontend, :normalizer) = _loaded ?? (throw _notLoaded());
    final clauses = normalizer.splitClauses(text);
    final units = clauses.isEmpty ? <String>[text] : clauses;
    final segs = <Uint8List>[];
    for (var i = 0; i < units.length; i++) {
      for (final input in frontend.encodeChunks(units[i])) {
        if (input.realLen <= 1) continue; // empty chunk → no audio.
        segs.add(core.synthesize(input, seed: ttsCfmSeed + i));
      }
    }
    return segs.isEmpty
        ? Uint8List(0)
        : concatPcmWithSilence(
            segs,
            silenceSamples: (core.sampleRate * 0.12).round(),
          );
  }

  /// Only the native core holds handles to free — the frontend is pure Dart
  /// (dictionary map + embedding table), nothing to dispose there.
  @override
  void dispose() => _core?.dispose();
}

/// Inflect-Nano-v2 engine. Loads `InflectTtsCore` (the VITS text-encoder +
/// decoder, plus the shared dp_g2p neural OOV G2P when the bundle carries it)
/// + `InflectTextFrontend`, and serves each request by splitting into
/// clauses, phonemizing (dictionary + neural OOV), synthesizing per clause,
/// and splicing with a short inter-clause silence — the same shape as
/// [_MatchaEngine] minus the CFM-seed (Inflect's noise is a fixed-seed
/// Gaussian inside `InflectTtsCore.synthesize`) and minus `encodeChunks` (the
/// encoder/decoder are dynamic-length, no MAX_MEL cap to chunk under).
final class _InflectEngine implements TtsWorkerEngine {
  _InflectEngine(this._profile, this._artifactPaths, this._backend);

  final TtsModelProfile _profile;
  final Map<String, String> _artifactPaths;
  final PreferredBackend? _backend;

  /// Same "track the core once its load succeeds" rationale as
  /// [_MatchaEngine._core].
  InflectTtsCore? _core;

  ({
    InflectTtsCore core,
    InflectTextFrontend frontend,
    TtsTextNormalizer normalizer,
  })?
  _loaded;

  @override
  Future<void> load() async {
    final core = _core = await InflectTtsCore.load(
      profile: _profile,
      artifactPaths: _artifactPaths,
      backend: _backend,
    );
    final frontend = await InflectTextFrontend.load(
      _profile,
      _artifactPaths,
      neuralG2p: core.neuralG2p,
    );
    final normalizer = TtsTextNormalizer.forLocale(_profile.locale, {});
    _loaded = (core: core, frontend: frontend, normalizer: normalizer);
  }

  @override
  int get sampleRate => (_loaded ?? (throw _notLoaded())).core.sampleRate;

  @override
  Uint8List synthesize(String text) {
    final (:core, :frontend, :normalizer) = _loaded ?? (throw _notLoaded());
    final clauses = normalizer.splitClauses(text);
    final units = clauses.isEmpty ? <String>[text] : clauses;
    final segs = <Uint8List>[];
    for (final unit in units) {
      final ids = frontend.encode(unit);
      if (ids.isEmpty) continue; // non-speech clause → no audio.
      segs.add(core.synthesize(ids));
    }
    return segs.isEmpty
        ? Uint8List(0)
        : concatPcmWithSilence(
            segs,
            silenceSamples: (core.sampleRate * 0.12).round(),
          );
  }

  @override
  void dispose() => _core?.dispose();
}

/// Qwen3-TTS engine. Loads `Qwen3TtsCore` (the talker/MTP/codec graphs + host
/// tables + BPE encoder) and the bundle's one demo-voice x-vector, then
/// serves requests with exactly ONE `core.synthesizePcm16` call per request.
///
/// Deliberately does NOT reuse [_MatchaEngine]'s clause-split / CFM-seed /
/// inter-clause-silence loop — none of those three apply here:
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
/// engine threads through to `Qwen3TtsCore.synthesizePcm16`, validated up
/// front by `LiteRtSpeechSynthesizer.create` (`assertQwen3LanguageSupported`),
/// which is also what surfaces a real language picker (via
/// `qwen3SupportedLanguages`); see [_WorkerInit.language]'s doc.
///
/// Fail-loud (per Global Constraints / the project's no-masking-fallback
/// rule): if [Qwen3TtsCore.load] or the demo-voice read throws, the worker
/// reports the error back to the main isolate exactly like a Matcha load
/// failure — it NEVER falls back to the Matcha path.
final class _Qwen3Engine implements TtsWorkerEngine {
  _Qwen3Engine(this._artifactPaths, this._backend, this._language, this._voice);

  final Map<String, String> _artifactPaths;
  final PreferredBackend? _backend;
  final String _language;
  final Float32List? _voice;

  /// Same "track the core once its load succeeds" rationale as
  /// [_MatchaEngine._core] — a fully-loaded native core (3 compiled graphs +
  /// environment + tables) must not be leaked if the demo-voice read fails
  /// right after.
  Qwen3TtsCore? _core;

  ({Qwen3TtsCore core, Float32List voice})? _loaded;

  @override
  Future<void> load() async {
    final core = _core = await Qwen3TtsCore.load(
      artifactPaths: _artifactPaths,
      backend: _backend,
    );
    final demoVoicePath = _artifactPaths['demo_speaker.npy'];
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
    final voice = _voice ?? readNpyF32(demoVoicePath);
    _loaded = (core: core, voice: voice);
  }

  @override
  int get sampleRate => (_loaded ?? (throw _notLoaded())).core.sampleRate;

  @override
  Uint8List synthesize(String text) {
    final (:core, :voice) = _loaded ?? (throw _notLoaded());
    return core.synthesizePcm16(
      text,
      speaker: voice,
      language: _language,
      doSample: true,
    );
  }

  /// `Qwen3TtsCore.dispose()` also frees the tables/tokenizer it owns
  /// internally (unlike Matcha, where the frontend is separate pure-Dart
  /// state) — only the core needs disposing here.
  @override
  void dispose() => _core?.dispose();
}

/// Disposes [engine], reporting a failure as text instead of throwing, so the
/// caller still sends its last message. Null means it disposed cleanly.
String? _disposeEngine(TtsWorkerEngine engine) {
  try {
    engine.dispose();
    return null;
  } catch (e, st) {
    edgeAiLog('[TtsWorker] dispose failed: $e\n$st');
    return '$e';
  }
}

/// Isolate entry point. Seeds the per-isolate log level, loads the engine for
/// the profile's pipeline, then serves requests until _Close.
Future<void> _workerEntry(_WorkerInit init) async {
  // Seed this isolate's per-isolate log level from the main-isolate snapshot.
  edgeAiLogLevel = init.logLevel;

  final TtsWorkerEngine engine;
  final int sampleRate;
  // Nullable twin of `engine`, so the failure path can tell "never built"
  // from "built, then failed" — and dispose the second.
  TtsWorkerEngine? built;
  try {
    built = init.engineFactory(
      profile: init.profile,
      artifactPaths: init.artifactPaths,
      backend: init.backend,
      language: init.language,
      voice: init.voice,
    );
    await built.load();
    // Read inside the try: a getter that throws is a failed load too, and
    // the model is loaded by now.
    sampleRate = built.sampleRate;
    engine = built;
  } catch (e, st) {
    edgeAiLog('[TtsWorker] ${init.profile.pipeline.name} load failed: $e\n$st');
    // Disposed BEFORE the error is sent — the main isolate gives up on this
    // worker the moment the error arrives.
    final disposeError = built == null ? null : _disposeEngine(built);
    Isolate.exit(
      init.replyTo,
      disposeError == null
          ? 'TTS worker failed to load: $e'
          : 'TTS worker failed to load: $e (disposing what it had loaded '
                'also failed, so native memory may still be held: '
                '$disposeError)',
    );
  }

  final commandPort = ReceivePort();
  final queued = Queue<_SynthRequest>();
  var closeRequested = false;
  Completer<void>? wake;

  // The listener only files messages; the loop below does the work. That
  // split is what lets a close overtake a queue: the listener sees _Close as
  // soon as the event loop is free, not after every request ahead of it ran.
  commandPort.listen((msg) {
    if (msg is _SynthRequest) {
      queued.add(msg);
    } else if (msg is _Close) {
      closeRequested = true;
      commandPort.close();
      // Only what has not started. The request in flight, if any, was taken
      // off the queue when it started, and it finishes on its own terms.
      while (queued.isNotEmpty) {
        final request = queued.removeFirst();
        init.replyTo.send(
          _SynthReply(request.id, null, _closedBeforeRunMessage),
        );
      }
    }
    final waiting = wake;
    wake = null;
    waiting?.complete();
  });

  init.replyTo.send(_Ready(commandPort.sendPort, sampleRate));

  final String? disposeError;
  try {
    // One request in flight at a time, in arrival order.
    while (!closeRequested) {
      if (queued.isEmpty) {
        final idle = wake = Completer<void>();
        await idle.future;
        continue;
      }
      // Yield to the event loop before every request. A synthesis blocks this
      // isolate inside synchronous native calls, so a _Close sent meanwhile is
      // still in the message queue when it returns — and awaiting a completed
      // future only drains microtasks, never that queue. A zero-duration
      // timer is posted to the BACK of the same queue, so by the time it
      // fires the listener has filed the close and emptied `queued`.
      await Future<void>.delayed(Duration.zero);
      if (closeRequested || queued.isEmpty) continue;
      _serve(queued.removeFirst(), engine, init.replyTo);
    }
  } finally {
    // Also on an unexpected throw out of the loop: the native model is freed
    // either way, and the throw then takes the isolate down, which the main
    // isolate's onError/onExit handling reports.
    disposeError = _disposeEngine(engine);
  }
  // Ack and exit in one step: nothing of this worker runs after the ack, so
  // the main isolate never has to kill it.
  Isolate.exit(init.replyTo, _CloseAck(disposeError));
}

/// Runs one request and replies — with the PCM, or with the error. Never
/// throws, so one bad input cannot stop the loop that serves the rest.
void _serve(_SynthRequest msg, TtsWorkerEngine engine, SendPort replyTo) {
  try {
    replyTo.send(_SynthReply(msg.id, engine.synthesize(msg.text), null));
  } catch (e) {
    replyTo.send(_SynthReply(msg.id, null, e.toString()));
  }
}
