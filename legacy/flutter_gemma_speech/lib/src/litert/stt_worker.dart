// Long-lived background isolate that owns the entire LiteRT STT native
// lifecycle (lib open, model compile, encode+decode forward passes,
// teardown) and the HF tokenizer. The forward passes (`LiteRtRunCompiledModel`,
// called once for encode and once per decode step) are blocking synchronous
// FFI calls; running them here keeps the UI isolate's event loop free,
// mirroring `litert_embedding_worker.dart` (#299).
//
// Why a long-lived worker and not `Isolate.run` per call:
//   - The compiled model is expensive to build but cheap to run, so it MUST
//     be compiled once and reused — `Isolate.run` would recompile every
//     call.
//   - FFI `Pointer`/`DynamicLibrary` cannot cross isolate boundaries
//     (flutter/flutter#169431). Keeping all handles inside the one worker
//     means nothing crosses the boundary.
//
// Only sendable values cross the port: file paths + profile + backend
// (setup), a `Float32List` of samples (request), and a transcript `String`
// (reply).

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/utils/gemma_log.dart';

import '../model/stt_model_profile.dart';
import 'stt_core.dart';

/// Handshake payload the worker sends back once the native model is loaded.
class _Ready {
  _Ready(this.commandPort);
  final SendPort commandPort;
}

/// Request: transcribe [samples] (already `[-1,1]`-normalized float32,
/// window-sized by the caller or by `SttCore.transcribe`'s pad/trim). [id]
/// correlates the reply. [language] overrides the loaded profile's default
/// decoder-prompt language for this one request (`null` = use the default);
/// a plain `String?` is sendable, so it crosses the port like [id] does.
class _TranscribeRequest {
  _TranscribeRequest(this.id, this.samples, this.language);
  final int id;
  final Float32List samples;
  final String? language;
}

/// Reply carrying the transcript (or an error message).
class _TranscribeReply {
  _TranscribeReply(
    this.id,
    this.text,
    this.error, {
    this.badArgument = false,
    this.argName,
    this.argValue,
  });
  final int id;
  final String? text;
  final String? error;

  /// [ArgumentError.name] and [ArgumentError.invalidValue], carried separately
  /// so the rebuilt error keeps them. Rebuilding from `toString()` alone gives
  /// `name == null`, `invalidValue == null` and a doubled `Invalid argument(s):`
  /// prefix, so no caller downstream of the port could assert on the field that
  /// says WHICH argument was wrong.
  final String? argName;
  final String? argValue;

  /// The worker rejected the CALLER's input (an [ArgumentError]) rather than
  /// failing at runtime. Carried as a flag because an exception object is not
  /// sendable across a port — without it every error arrives as a `StateError`,
  /// so `transcribe(language: 'zz')` could not be caught as the argument error
  /// it is. Only the type is reconstructed; the worker-side stack is already
  /// lost here (pre-existing).
  /// Deliberately NOT set for a [RangeError]: `RangeError` and `IndexError`
  /// both EXTEND `ArgumentError` in dart:core, so a plain `e is ArgumentError`
  /// reports every out-of-range index in the decode path — a mismatched mel
  /// filterbank, a short logits row — to the app as a bad `language` argument.
  final bool badArgument;
}

/// Sentinel asking the worker to tear down the native model and exit.
class _Close {
  const _Close();
}

/// Ack the worker sends after [SttCore.dispose] completes, so the main
/// isolate can kill the isolate without racing native teardown.
class _CloseAck {
  const _CloseAck();
}

/// Parameters needed to boot the worker isolate. Must be fully sendable.
class _WorkerInit {
  _WorkerInit({
    required this.replyTo,
    required this.modelPath,
    required this.tokenizerPath,
    required this.profile,
    required this.backend,
    required this.logLevel,
  });
  final SendPort replyTo;
  final String modelPath;
  final String tokenizerPath;
  final SttModelProfile profile;
  final PreferredBackend? backend;

  /// Snapshot of the main-isolate [gemmaLogLevel] at spawn — the worker
  /// isolate gets its own copy of the per-isolate top-level (default info),
  /// so it must be seeded explicitly.
  final GemmaLogLevel logLevel;
}

/// Main-isolate handle to the STT worker. Spawns the isolate, performs the
/// load handshake, and multiplexes concurrent requests by id.
class SttWorker {
  SttWorker._(this._isolate, this._commandPort, this._fromWorker);

  final Isolate _isolate;
  final SendPort _commandPort;
  final ReceivePort _fromWorker;

  final _pending = <int, Completer<String>>{};
  int _nextId = 0;
  bool _closed = false;
  Completer<void>? _closeAck;

  /// Spawn the worker and wait until the native model is loaded.
  static Future<SttWorker> spawn({
    required String modelPath,
    required String tokenizerPath,
    required SttModelProfile profile,
    PreferredBackend? backend,
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
            StateError('STT worker isolate exited during load'),
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
          modelPath: modelPath,
          tokenizerPath: tokenizerPath,
          profile: profile,
          backend: backend,
          logLevel: gemmaLogLevel,
        ),
        // onExit posts `null` to fromWorker so we never wait on a dead isolate.
        onExit: fromWorker.sendPort,
        debugName: 'litert-stt-worker',
      );
      ready = await readyCompleter.future;
    } catch (_) {
      await sub.cancel();
      fromWorker.close();
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    }

    final worker = SttWorker._(isolate, ready.commandPort, fromWorker);
    // Re-point the subscription at the steady-state reply handler.
    sub.onData(worker._onReply);
    return worker;
  }

  void _onReply(dynamic msg) {
    if (msg is _TranscribeReply) {
      final completer = _pending.remove(msg.id);
      if (completer == null) return;
      if (msg.error != null) {
        completer.completeError(
          msg.badArgument
              ? ArgumentError.value(msg.argValue, msg.argName, msg.error)
              : StateError(msg.error!),
        );
      } else {
        completer.complete(msg.text!);
      }
    } else if (msg is _CloseAck) {
      _closeAck?.complete();
    } else if (msg == null) {
      // onExit: the worker isolate died. If this is part of a normal close,
      // the ack path already handled it; otherwise it's an unexpected crash
      // — fail every in-flight request rather than leave callers hanging.
      _failAllPending('STT worker isolate exited unexpectedly');
      _closed = true;
      _closeAck?.complete();
    }
  }

  void _failAllPending(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(reason));
    }
    _pending.clear();
  }

  /// Transcribe one window of already-normalized `[-1,1]` float32 [samples].
  /// The forward passes run in the worker; the UI isolate stays free.
  ///
  /// [language] retargets the decoder prompt for this request only. It does
  /// NOT reload anything — the worker keeps its language→id map from load, so
  /// consecutive requests may each use a different language.
  Future<String> transcribe(Float32List samples, {String? language}) {
    if (_closed) {
      return Future.error(StateError('SttWorker is closed'));
    }
    final id = _nextId++;
    final completer = Completer<String>();
    _pending[id] = completer;
    _commandPort.send(_TranscribeRequest(id, samples, language));
    return completer.future;
  }

  /// Tear down the native model and stop the isolate. Waits for the worker
  /// to finish native teardown (a _CloseAck, or the isolate's onExit) before
  /// killing it, so handles are never freed mid-dispose.
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
    }
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _failAllPending('SttWorker closed mid-request');
  }
}

/// Isolate entry point. Loads the model, then serves requests until _Close.
Future<void> _workerEntry(_WorkerInit init) async {
  // Seed this isolate's per-isolate log level from the main-isolate snapshot.
  gemmaLogLevel = init.logLevel;
  final SttCore core;
  try {
    core = await SttCore.load(
      modelPath: init.modelPath,
      tokenizerPath: init.tokenizerPath,
      profile: init.profile,
      backend: init.backend,
    );
  } catch (e, st) {
    gemmaLog('[SttWorker] load failed: $e\n$st');
    init.replyTo.send('STT worker failed to load: $e');
    return;
  }

  final commandPort = ReceivePort();
  init.replyTo.send(_Ready(commandPort.sendPort));

  try {
    await for (final msg in commandPort) {
      if (msg is _TranscribeRequest) {
        try {
          final text = core.transcribe(msg.samples, language: msg.language);
          init.replyTo.send(_TranscribeReply(msg.id, text, null));
        } catch (e) {
          // Bound once, as a typed local, rather than re-tested per field: a
          // `bool` flag leaves `e` an Object, so every read needs a cast — and
          // whether the analyzer calls that cast redundant differs by SDK.
          //
          // `e is! RangeError` is load-bearing — see _TranscribeReply.badArgument.
          final argError = e is ArgumentError && e is! RangeError ? e : null;
          init.replyTo.send(
            _TranscribeReply(
              msg.id,
              null,
              argError?.message?.toString() ?? '$e',
              badArgument: argError != null,
              argName: argError?.name,
              argValue: argError?.invalidValue?.toString(),
            ),
          );
        }
      } else if (msg is _Close) {
        commandPort.close();
        break;
      }
    }
  } finally {
    // Always free native handles, even if the loop exits unexpectedly, then
    // ack so the main isolate can kill us without racing teardown.
    core.dispose();
    init.replyTo.send(const _CloseAck());
  }
}
