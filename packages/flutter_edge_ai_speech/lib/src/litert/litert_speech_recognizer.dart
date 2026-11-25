// `SpeechRecognizer` facade over a background isolate, mirroring
// `litert_embedding_model.dart` (#299). The blocking LiteRT encode+decode
// forward passes run on a dedicated [SttWorker] isolate — spawned once,
// reused for every call — so the UI isolate stays free.
//
// The native code lives in `stt_core.dart` (driven inside the worker
// isolate); this file is the public, async, main-isolate API generic over
// [SttModelProfile] — moonshine/whisper/parakeet select a profile, not a
// recognizer subclass, except that a streaming profile gets
// [LiteRtStreamingSpeechRecognizer].
//
// The streaming contracts are @experimental in core (members may be added in
// a minor release): this package implements them and pins core accordingly.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import '../model/stt_model_profile.dart';
import '../streaming/detokenizer.dart' show DecodedToken, TokenIdsToUtf8;
import '../streaming/windowed_transcriber.dart';
import '../tokenizer/stt_tokenizer.dart' show SttTokenizer;
import 'stt_core.dart' show resolveSttSpecialTokens;
import 'stt_worker.dart';

/// Signature for the `onClose` callback. Same name Flutter uses.
typedef VoidCallback = void Function();

/// Convert little-endian 16-bit PCM bytes to normalized `[-1, 1]` float32
/// samples (`/32768.0`), per the verified recipe's WAV→float32 step
/// (`docs/superpowers/notes/stt-transcript-recipe.md`).
Float32List pcm16LEToFloat32(Uint8List pcm) {
  final byteData = ByteData.sublistView(pcm);
  final sampleCount = pcm.lengthInBytes ~/ 2;
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}

/// Generic LiteRT-backed [SpeechRecognizer]. Runs whichever model
/// [SttModelProfile] describes — it is NOT hardcoded to moonshine; adding a
/// new profile (+ a mel frontend for log-mel models) is enough to support a
/// new STT family without a new recognizer class.
/// Reject a [language] this model cannot use, before anything is loaded.
///
/// One home for the whole rule, called from both `LiteRtSpeechRecognizer.create`
/// (before the isolate spawns) and its `language` setter (which every retarget
/// and every direct assignment goes through). Splitting it produced the shape
/// where the create path threw and the retarget path accepted the same value,
/// then failed on every later transcription — including ones passing no
/// language at all.
///
/// `null` is always valid: it means "the model's own default".
void validateSttLanguage(String? language, {required bool supportsLanguage}) {
  if (language == null) return;
  if (!supportsLanguage) {
    throw ArgumentError.value(
      language,
      'language',
      'this model has no decoder-prompt language token; only whisper '
          'profiles accept a language',
    );
  }
  assertWhisperLanguage(language);
}

class LiteRtSpeechRecognizer extends SpeechRecognizer with CloseNotifier {
  LiteRtSpeechRecognizer._(
    this._worker,
    this.onClose,
    this._supportsLanguage,
    String? language,
  ) {
    // Through the setter, so the create path is validated by the same code as
    // every later assignment — there is no "first call is checked, the rest are
    // not" asymmetry to reason about.
    this.language = language;
    // A worker that dies on its own turns this recognizer closed and tells its
    // listeners, so core drops its cached recognizer and the next
    // `getActiveStt` builds a fresh one — instead of handing out this one,
    // whose every call would fail.
    unawaited(_worker.unexpectedExit.then(_onWorkerDied));
  }

  final SttWorker _worker;
  final VoidCallback onClose;

  /// Completes, with the reason, when the recognizer is closed or its worker
  /// dies; a running stream ends on it.
  final _closedSignal = Completer<String>();

  /// What every [close] after the first returns: completes, normally, once
  /// the one shared teardown is done — so a second caller waits for it
  /// instead of returning while it is still running.
  Future<void>? _closeFuture;

  /// Whether [onClose] and the close listeners have run; they run once,
  /// whether the recognizer was closed or its worker died.
  bool _closeNotified = false;

  /// Why the worker died, when it did; later calls quote it.
  String? _deathReason;

  /// Whether this model's decoder prompt HAS a language slot (whisper yes,
  /// moonshine/parakeet no). Captured at create from the profile, because the
  /// profile itself lives in the worker isolate and the setter has to answer
  /// synchronously.
  final bool _supportsLanguage;

  bool _isClosed = false;

  String? _language;

  /// The default output language for [transcribe] calls that pass none.
  ///
  /// The setter is where every write is validated — the shells assign here when
  /// they retarget a cached recognizer, and an app may assign directly. Putting
  /// the check anywhere else leaves a path that accepts a language the model
  /// cannot use and then fails on every subsequent transcription, including
  /// calls that pass no language at all.
  @override
  String? get language => _language;

  @override
  set language(String? value) {
    validateSttLanguage(value, supportsLanguage: _supportsLanguage);
    _language = value;
  }

  /// Load [profile]'s model + tokenizer and prepare it for transcription on
  /// a background isolate.
  ///
  /// [modelPath] points at a `.tflite` STT model; [tokenizerPath] at its HF
  /// `tokenizer.json`. [preferredBackend] selects the LiteRT hardware
  /// accelerator (defaults to CPU).
  ///
  /// Caller owns the returned instance and must call [close] when done.
  ///
  /// [engineFactory] is the worker's test seam (see [SttWorker.spawn]);
  /// production leaves it null.
  static Future<LiteRtSpeechRecognizer> create({
    required SttModelProfile profile,
    required String modelPath,
    required String tokenizerPath,
    PreferredBackend? preferredBackend,
    VoidCallback? onClose,
    String? language,
    @visibleForTesting SttWorkerEngineFactory? engineFactory,
  }) async {
    // BEFORE the spawn: the constructor's own assignment would throw only after
    // the isolate is up and the model loaded, orphaning the worker.
    validateSttLanguage(
      language,
      supportsLanguage: profile.languagePromptIndex != null,
    );
    // A streaming profile detokenizes on this isolate: read its tokenizer
    // first, so a bad file fails before a worker is spawned.
    final TokenIdsToUtf8? tokenIdsToUtf8 =
        profile.supportsStreaming && profile.decodeType == SttDecodeType.ctc
        ? await _tokenIdsToUtf8(profile, tokenizerPath)
        : null;
    final worker = await SttWorker.spawn(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      profile: profile,
      backend: preferredBackend,
      engineFactory: engineFactory,
    );
    // Kept as the mutable default rather than baked into the profile: the
    // caller may retarget it later without a reload (see [language]).
    if (tokenIdsToUtf8 != null) {
      return LiteRtStreamingSpeechRecognizer._(
        worker,
        onClose ?? () {},
        language,
        profile,
        tokenIdsToUtf8,
      );
    }
    return LiteRtSpeechRecognizer._(
      worker,
      onClose ?? () {},
      profile.languagePromptIndex != null,
      language,
    );
  }

  /// How the detokenizer turns token ids into text: the profile's own
  /// tokenizer, as the worker decodes with it.
  static Future<TokenIdsToUtf8> _tokenIdsToUtf8(
    SttModelProfile profile,
    String tokenizerPath,
  ) async {
    final json =
        jsonDecode(await File(tokenizerPath).readAsString())
            as Map<String, dynamic>;
    final tokenizer = SttTokenizer.forProfileKind(
      profile.tokenizerKind,
      json,
      eosId: resolveSttSpecialTokens(profile, json).eosId,
    );
    return (ids, {required skipSpecialTokens}) =>
        utf8.encode(tokenizer.decode(ids));
  }

  void _assertNotClosed() {
    if (_isClosed) {
      final death = _deathReason;
      throw StateError(
        death == null
            ? 'LiteRtSpeechRecognizer is closed; create a new instance to use it'
            : 'LiteRtSpeechRecognizer is closed because $death; create a new '
                  'instance to use it',
      );
    }
  }

  // `async` so a closed recognizer's error reaches the caller through the
  // returned Future, not as a synchronous throw. Nothing here awaits: the
  // request is still sent to the worker during the call, in call order.
  @override
  Future<String> transcribe(Uint8List pcm16kMono, {String? language}) async {
    _assertNotClosed();
    final samples = pcm16LEToFloat32(pcm16kMono);
    // Per-call value wins; otherwise the recognizer's current default. Both may
    // be null, which leaves the profile's own default in place.
    return _worker.transcribe(samples, language: language ?? this.language);
  }

  /// Closes the recognizer and its worker.
  ///
  /// Transcriptions that have not started fail with a "closed" [StateError];
  /// the one in flight finishes first, and this waits for it and for the
  /// native model to be disposed, however long that takes. A recognizer whose
  /// worker died is already closed — its listeners have run — and this only
  /// releases what is left. Concurrent callers share one teardown.
  @override
  Future<void> close() {
    final teardownDone = _closeFuture;
    if (teardownDone != null) return teardownDone;
    final settled = Completer<void>();
    _closeFuture = settled.future;
    // `whenComplete` hands the first caller the teardown's own outcome — a
    // throwing `onClose` or listener included — while every later caller
    // gets `settled`, which only ever completes normally once it is done.
    return _close().whenComplete(settled.complete);
  }

  Future<void> _close() async {
    _isClosed = true;
    if (!_closedSignal.isCompleted) {
      _closedSignal.complete('the recognizer was closed');
    }
    try {
      await _worker.close();
    } finally {
      _notifyClosed();
    }
  }

  void _notifyClosed() {
    if (_closeNotified) return;
    _closeNotified = true;
    try {
      onClose();
    } finally {
      // Even when `onClose` throws: core drops its cached instance on a close
      // listener, and one it never hears about is handed to every later
      // caller.
      fireCloseListeners();
    }
  }

  void _onWorkerDied(String reason) {
    _deathReason = reason;
    _isClosed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete(reason);
    try {
      _notifyClosed();
    } catch (e, st) {
      // Nobody awaits this path, so a throwing listener would otherwise be an
      // unhandled error with no context; `print`, because edgeAiLog is silent
      // in release.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_speech] WARNING: a close listener threw while a '
        'speech recognizer whose worker had died was being closed: $e\n$st',
      );
    }
  }
}

/// A [LiteRtSpeechRecognizer] whose profile streams ([SttMode.streaming]):
/// Parakeet's CTC, through overlapping windows and a timestamp merger
/// ([WindowedTranscriber]). Every window is a request on the recognizer's
/// worker, in the same queue as `transcribe`, so a transcription made during
/// a stream runs between two of its windows.
final class LiteRtStreamingSpeechRecognizer extends LiteRtSpeechRecognizer
    implements StreamingSpeechRecognizer {
  LiteRtStreamingSpeechRecognizer._(
    SttWorker worker,
    VoidCallback onClose,
    String? language,
    this._profile,
    this._tokenIdsToUtf8,
  ) : super._(worker, onClose, _profile.languagePromptIndex != null, language);

  final SttModelProfile _profile;
  final TokenIdsToUtf8 _tokenIdsToUtf8;

  /// The running stream, or null.
  _SttStream? _active;

  @override
  StreamingSttInfo get streaming => StreamingSttInfo(
    kind: StreamingKind.windowed,
    window: Duration(
      microseconds: _profile.windowSamples * 1000000 ~/ _profile.sampleRate,
    ),
  );

  @override
  Stream<TranscriptUpdate> transcribeStream(
    Stream<Uint8List> pcm16kMono, {
    String? language,
    TranscribeStreamOptions options = const TranscribeStreamOptions(),
  }) {
    if (options.maxBufferedAudio < streaming.window) {
      throw ArgumentError.value(
        options.maxBufferedAudio,
        'options.maxBufferedAudio',
        'must be at least the model window, ${streaming.window}',
      );
    }
    final stream = _SttStream(this, pcm16kMono, language, options);
    return stream.updates;
  }

  @override
  Future<void> flush() {
    final active = _active;
    if (active == null || active.inputEnded) {
      return Future.error(
        StateError('flush: no transcribeStream is running on this recognizer'),
      );
    }
    return active.flush();
  }
}

/// One `transcribeStream` call: its claim, its input, its queue of audio and
/// flush marks, and its [WindowedTranscriber].
final class _SttStream {
  _SttStream(this._owner, this._input, this._language, this._options) {
    _out = StreamController<TranscriptUpdate>(
      onListen: _start,
      onCancel: _cancel,
    );
  }

  final LiteRtStreamingSpeechRecognizer _owner;
  final Stream<Uint8List> _input;
  final String? _language;
  final TranscribeStreamOptions _options;
  late final StreamController<TranscriptUpdate> _out;

  StreamSubscription<Uint8List>? _subscription;
  WindowedTranscriber? _transcriber;

  /// Audio not handed to the transcriber yet, and flush marks, in order.
  final _queue = <Object>[];

  /// Samples in [_queue].
  int _queuedSamples = 0;

  /// Samples handed to the transcriber in this stream.
  int _analysedSamples = 0;

  /// Samples of the stream up to the last flush (its utterances' origin).
  int _utteranceOrigin = 0;

  /// A trailing byte of the last chunk: half a 16-bit sample.
  int? _oddByte;

  bool _done = false;
  bool _claimed = false;
  bool inputEnded = false;
  Future<void>? _draining;

  Stream<TranscriptUpdate> get updates => _out.stream;

  int get _rate => _owner._profile.sampleRate;

  Duration _at(int samples) =>
      Duration(microseconds: samples * 1000000 ~/ _rate);

  void _start() {
    final owner = _owner;
    if (owner._isClosed) {
      _fail(
        StateError(
          'transcribeStream: the recognizer is closed'
          '${owner._deathReason == null ? '' : ' (${owner._deathReason})'}',
        ),
      );
      return;
    }
    if (owner._active != null) {
      _fail(
        StateError(
          'transcribeStream: another stream is running on this recognizer; '
          'one runs at a time',
        ),
      );
      return;
    }
    try {
      validateSttLanguage(
        _language ?? owner.language,
        supportsLanguage: owner._supportsLanguage,
      );
    } catch (e, st) {
      _fail(e, st);
      return;
    }
    owner._active = this;
    _claimed = true;
    final profile = owner._profile;
    _transcriber = WindowedTranscriber(
      windowSamples: profile.windowSamples,
      overlapRatio: switch (_options.latency) {
        StreamingLatency.lowLatency => 0.75,
        StreamingLatency.balanced => 0.5,
      },
      tokenIdsToUtf8: owner._tokenIdsToUtf8,
      runWindow: _runWindow,
    );
    unawaited(
      owner._closedSignal.future.then((reason) {
        if (!_done) _fail(StateError('transcribeStream ended: $reason'));
      }),
    );
    try {
      _subscription = _input.listen(
        _onChunk,
        onError: _fail,
        onDone: () {
          inputEnded = true;
          _pump();
        },
        cancelOnError: true,
      );
    } catch (e, st) {
      _fail(e, st);
    }
  }

  Future<List<DecodedToken>> _runWindow(
    Float32List window, {
    required int validSamples,
    required double startFraction,
  }) async {
    final w = await _owner._worker.ctcWindow(
      window,
      validSamples: validSamples,
      startFraction: startFraction,
    );
    return [
      for (var i = 0; i < w.tokenIds.length; i++)
        DecodedToken(w.tokenIds[i], timestampMs: w.frames[i]),
      DecodedToken.endOfChunk(timestampMs: w.windowFrames),
    ];
  }

  void _onChunk(Uint8List chunk) {
    if (_done) return;
    var bytes = chunk;
    final odd = _oddByte;
    if (odd != null) {
      bytes = Uint8List(chunk.length + 1)
        ..[0] = odd
        ..setRange(1, chunk.length + 1, chunk);
      _oddByte = null;
    }
    if (bytes.length.isOdd) {
      _oddByte = bytes.last;
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    if (bytes.isEmpty) return;
    final samples = pcm16LEToFloat32(bytes);
    _queue.add(samples);
    _queuedSamples += samples.length;
    final limit = _options.maxBufferedAudio.inMicroseconds * _rate ~/ 1000000;
    if (_queuedSamples > limit) {
      _fail(
        SpeechStreamOverrunException(
          buffered: _at(_queuedSamples),
          limit: _options.maxBufferedAudio,
        ),
      );
      return;
    }
    _pump();
  }

  Future<void> flush() {
    final mark = Completer<void>();
    _queue.add(mark);
    _pump();
    return mark.future;
  }

  /// Runs the queue, one item at a time; one pump runs at once.
  void _pump() {
    if (_draining != null || _done) return;
    _draining = _drain().whenComplete(() => _draining = null);
  }

  Future<void> _drain() async {
    final transcriber = _transcriber!;
    try {
      while (!_done && _queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        if (item is Float32List) {
          _queuedSamples -= item.length;
          final result = await transcriber.add(item);
          _analysedSamples += item.length;
          _emit(result, endpoint: false);
        } else if (item is Completer<void>) {
          final pending = <Completer<void>>[item];
          // Flushes asked for before this one ran share it.
          while (_queue.isNotEmpty && _queue.first is Completer<void>) {
            pending.add(_queue.removeAt(0) as Completer<void>);
          }
          final result = await transcriber.flush();
          _emit(result, endpoint: true);
          _utteranceOrigin = _analysedSamples;
          for (final c in pending) {
            if (!c.isCompleted) c.complete();
          }
        }
      }
      if (!_done && inputEnded && _queue.isEmpty) {
        final result = await transcriber.finish();
        _emit(result, endpoint: true);
        _finish();
      }
    } catch (e, st) {
      _fail(e, st);
    }
  }

  void _emit(WindowedResult result, {required bool endpoint}) {
    if (_done) return;
    final windowSamples = _owner._profile.windowSamples;
    // Words before the newest window's start are confirmed; at an endpoint,
    // everything received.
    final confirmedUntil = endpoint
        ? _analysedSamples
        : (_analysedSamples - windowSamples).clamp(
            _utteranceOrigin,
            _analysedSamples,
          );
    _out.add(
      TranscriptUpdate(
        confirmedDelta: result.confirmed.isEmpty ? '' : ' ${result.confirmed}',
        unconfirmed: endpoint ? '' : result.unconfirmed,
        confirmedUntil: _at(confirmedUntil),
        endpoint: endpoint,
      ),
    );
  }

  void _release() {
    if (_claimed && identical(_owner._active, this)) _owner._active = null;
    _claimed = false;
    for (final item in _queue) {
      if (item is Completer<void> && !item.isCompleted) {
        item.completeError(StateError('the stream ended before this flush'));
      }
    }
    _queue.clear();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _release();
    unawaited(_out.close());
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_done) return;
    _done = true;
    unawaited(_subscription?.cancel());
    _release();
    _out.addError(error, stack);
    unawaited(_out.close());
  }

  /// The subscription's cancel: stop reading and emitting at once; the
  /// returned future completes after a window already in native code. A
  /// stream that has already ended (done or with an error) released its claim
  /// then and waits for nothing here: `Stream.toList` and the like cancel
  /// after an error and wait for this.
  Future<void> _cancel() async {
    if (_done) return;
    _done = true;
    await _subscription?.cancel();
    final draining = _draining;
    if (draining != null) await draining;
    _release();
  }
}
