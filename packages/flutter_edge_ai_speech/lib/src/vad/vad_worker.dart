// The VAD worker: a long-lived isolate that owns the Silero graph. It has its
// own isolate, separate from speech-to-text, so a 32 ms frame never waits
// behind a speech-to-text window (hundreds of ms) or a 30 s Whisper batch.
//
// The rules are those of the STT and TTS workers (stt_worker.dart): only
// sendable values cross the port; the worker frees its native model itself
// and exits, and is never killed, because a killed isolate runs no more Dart
// code and its model would stay resident. Unlike those workers it needs no
// queue of its own: every request is synchronous, so the isolate serves its
// port in order and a close is reached only after every request sent before
// it has been answered.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';

import 'silero_vad_core.dart';
import 'vad_endpointer.dart' show vadFrameSamples;

/// What the worker drives. Production is [SileroVadCore]; tests pass a fake
/// through [VadWorker.spawn]'s `engineFactory`.
abstract interface class VadWorkerEngine {
  /// Loads the model. When it throws, nothing is left to free.
  void load();

  /// The probability of one 512-sample frame, carrying the state.
  double probability(Float32List frame);

  /// Starts a new stream.
  void reset();

  /// Frees the model. Called once, after a successful [load].
  void dispose();
}

/// Builds the engine inside the worker isolate. Must be a top-level or static
/// function (it crosses the isolate boundary in the spawn message), and must
/// allocate nothing native: that is [VadWorkerEngine.load]'s job.
typedef VadWorkerEngineFactory = VadWorkerEngine Function(String modelPath);

final class _Init {
  _Init(this.replyTo, this.modelPath, this.logLevel, this.engineFactory);
  final SendPort replyTo;
  final String modelPath;
  final EdgeAiLogLevel logLevel;
  final VadWorkerEngineFactory engineFactory;
}

final class _Ready {
  _Ready(this.commandPort);
  final SendPort commandPort;
}

final class _LoadFailed {
  _LoadFailed(this.error);
  final String error;
}

final class _Request {
  _Request(this.id, this.samples, this.reset);
  final int id;
  final Float32List samples;
  final bool reset;
}

final class _Reply {
  _Reply(this.id, this.probabilities, this.error);
  final int id;
  final Float32List? probabilities;
  final String? error;
}

final class _Close {
  const _Close();
}

final class _CloseAck {
  _CloseAck(this.error);
  final String? error;
}

/// Main-isolate handle of the VAD worker.
final class VadWorker {
  VadWorker._(this._commandPort, this._fromWorker, this._modelPath);

  final SendPort _commandPort;
  final ReceivePort _fromWorker;
  final String _modelPath;
  final _pending = <int, Completer<Float32List>>{};
  int _nextId = 0;
  bool _closing = false;
  bool _acked = false;
  String? _deathReason;
  String? _crash;
  final _gone = Completer<void>();
  final _unexpectedExit = Completer<String>();
  Future<void>? _closeFuture;

  /// Completes, with the reason, if the worker ends without being closed.
  Future<String> get unexpectedExit => _unexpectedExit.future;

  /// Whether [close] was called or the worker died.
  bool get isClosed => _closing;

  /// Why the worker ended without being closed, or null.
  String? get deathReason => _deathReason;

  /// Spawns the worker and loads [modelPath] in it. Throws [StateError] with
  /// the worker's message when the load fails.
  static Future<VadWorker> spawn({
    required String modelPath,
    VadWorkerEngineFactory? engineFactory,
  }) async {
    final fromWorker = ReceivePort();
    final ready = Completer<_Ready>();
    String? crash;
    late final StreamSubscription<dynamic> sub;
    sub = fromWorker.listen((msg) {
      if (msg is _Ready) {
        if (!ready.isCompleted) ready.complete(msg);
      } else if (msg is _LoadFailed) {
        if (!ready.isCompleted) ready.completeError(StateError(msg.error));
      } else if (msg is List) {
        crash = _describeUncaught(msg);
      } else if (msg == null && !ready.isCompleted) {
        ready.completeError(
          StateError(
            'VAD worker isolate exited during load'
            '${crash == null ? '' : ': $crash'}',
          ),
        );
      }
    });
    final _Ready handshake;
    try {
      await Isolate.spawn(
        _workerEntry,
        _Init(
          fromWorker.sendPort,
          modelPath,
          edgeAiLogLevel,
          engineFactory ?? _sileroEngine,
        ),
        onError: fromWorker.sendPort,
        onExit: fromWorker.sendPort,
        debugName: 'litert-vad-worker',
      );
      handshake = await ready.future;
    } catch (_) {
      await sub.cancel();
      fromWorker.close();
      rethrow;
    }
    final worker = VadWorker._(handshake.commandPort, fromWorker, modelPath);
    sub.onData(worker._onMessage);
    return worker;
  }

  /// Speech probabilities of [samples], a whole number of 512-sample frames
  /// of 16 kHz audio in [-1, 1], one per frame. [reset] starts a new stream
  /// first.
  Future<Float32List> probabilities(Float32List samples, {bool reset = false}) {
    if (_closing) {
      final death = _deathReason;
      return Future.error(
        StateError(
          death == null
              ? 'VoiceActivityDetector is closed'
              : 'VoiceActivityDetector is closed: $death',
        ),
      );
    }
    if (samples.length % vadFrameSamples != 0) {
      return Future.error(
        ArgumentError.value(
          samples.length,
          'samples.length',
          'must be a multiple of $vadFrameSamples',
        ),
      );
    }
    final id = _nextId++;
    final completer = Completer<Float32List>();
    _pending[id] = completer;
    _commandPort.send(_Request(id, samples, reset));
    return completer.future;
  }

  /// Frees the model and ends the worker. Requests sent before are answered
  /// first; later ones fail with [StateError]. Waits however long the native
  /// call in flight takes, printing a notice after [slowCloseNotice]; never
  /// kills the worker. Completes normally even when the native dispose
  /// failed: that is printed as a warning. Idempotent.
  Future<void> close() => _closeFuture ??= _shutDown();

  /// How long [close] waits before it says what it is waiting for.
  static Duration slowCloseNotice = const Duration(seconds: 10);

  Future<void> _shutDown() async {
    _closing = true;
    if (!_gone.isCompleted) {
      _commandPort.send(const _Close());
      // Never killed (its model would stay resident): wait, and say once
      // what for when it takes long.
      final notice = Timer(
        slowCloseNotice,
        () => _warn(
          'closing the VAD model $_modelPath has taken '
          '${slowCloseNotice.inSeconds} s: the worker is still inside a '
          'native call. It keeps waiting rather than kill the worker, '
          'because a killed worker never frees its native model.',
        ),
      );
      try {
        await _gone.future;
      } finally {
        notice.cancel();
      }
    }
    _fromWorker.close();
    _failPending('the VAD worker for $_modelPath stopped without answering');
  }

  void _onMessage(dynamic msg) {
    if (msg is _Reply) {
      final completer = _pending.remove(msg.id);
      if (completer == null) return;
      final error = msg.error;
      if (error != null) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(msg.probabilities!);
      }
    } else if (msg is _CloseAck) {
      _acked = true;
      final error = msg.error;
      if (error != null) {
        _warn(
          'the VAD model $_modelPath failed to dispose; its native model may '
          'still be resident: $error',
        );
      }
      if (!_gone.isCompleted) _gone.complete();
    } else if (msg is List) {
      _crash = _describeUncaught(msg);
    } else if (msg == null) {
      if (_acked) return;
      final reason =
          'the VAD worker isolate exited unexpectedly'
          '${_crash == null ? '' : ': $_crash'}';
      _deathReason = reason;
      _closing = true;
      if (!_unexpectedExit.isCompleted) _unexpectedExit.complete(reason);
      _failPending(reason);
      _fromWorker.close();
      _warn('$reason (model $_modelPath); its native model may be resident');
      if (!_gone.isCompleted) _gone.complete();
    }
  }

  void _failPending(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(reason));
    }
    _pending.clear();
  }

  static String _describeUncaught(List<dynamic> message) {
    final error = message.isNotEmpty ? message[0] : null;
    final stack = message.length > 1 ? message[1] : null;
    return stack == null ? '$error' : '$error\n$stack';
  }

  // `print`, not edgeAiLog: edgeAiLog is silent in release builds, and a
  // model that may stay resident is worth saying there too.
  static void _warn(String message) {
    // ignore: avoid_print
    print('[flutter_edge_ai_speech] WARNING: $message');
  }
}

void _workerEntry(_Init init) {
  edgeAiLogLevel = init.logLevel;
  final engine = init.engineFactory(init.modelPath);
  try {
    engine.load();
  } catch (e) {
    // spawn wraps it in a StateError: send the message alone, not
    // "Bad state: ..." twice.
    init.replyTo.send(_LoadFailed(e is StateError ? e.message : '$e'));
    return;
  }
  final commands = ReceivePort();
  commands.listen((msg) {
    if (msg is _Request) {
      init.replyTo.send(_serve(engine, msg));
    } else if (msg is _Close) {
      String? error;
      try {
        engine.dispose();
      } catch (e) {
        error = '$e';
      }
      commands.close();
      Isolate.exit(init.replyTo, _CloseAck(error));
    }
  });
  init.replyTo.send(_Ready(commands.sendPort));
}

_Reply _serve(VadWorkerEngine engine, _Request request) {
  try {
    if (request.reset) engine.reset();
    final frames = request.samples.length ~/ vadFrameSamples;
    final out = Float32List(frames);
    for (var f = 0; f < frames; f++) {
      out[f] = engine.probability(
        Float32List.sublistView(
          request.samples,
          f * vadFrameSamples,
          (f + 1) * vadFrameSamples,
        ),
      );
    }
    return _Reply(request.id, out, null);
  } catch (e) {
    return _Reply(request.id, null, '$e');
  }
}

final class _SileroEngine implements VadWorkerEngine {
  _SileroEngine(this.modelPath);
  final String modelPath;
  SileroVadCore? _core;

  @override
  void load() => _core = SileroVadCore.load(modelPath);

  @override
  double probability(Float32List frame) => _core!.probability(frame);

  @override
  void reset() => _core!.reset();

  @override
  void dispose() => _core?.dispose();
}

VadWorkerEngine _sileroEngine(String modelPath) => _SileroEngine(modelPath);
