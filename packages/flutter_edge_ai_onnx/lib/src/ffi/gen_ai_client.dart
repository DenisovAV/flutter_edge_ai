// ORT-GenAI text generation over `dart:ffi`, driven from a long-lived worker
// isolate — the productionized form of the throughput spike at
// `scratchpad/ort_genai_spike/bin/main.dart` (hardened plan Phase 3, Task 1).
//
// Why a long-lived worker and not `Isolate.run` per call (mirrors
// `EmbeddingWorker`'s doc, `flutter_edge_ai/lib/core/embedding/embedding_worker.dart`):
//   - Model + tokenizer load costs hundreds of ms and must happen once.
//   - FFI `Pointer`/`DynamicLibrary` cannot cross isolate boundaries — every
//     native handle (model, tokenizer, generator) is created and used
//     entirely inside the worker; only sendable values (strings, ints,
//     bools, plain data classes) cross the port. This resolves D4 by
//     construction: no FFI handle ever crosses an isolate.
//   - ORT-GenAI has no native stream callback (unlike LiteRT-LM's
//     `stream_proxy`), so the decode loop is Dart-driven. Reloading the
//     model+tokenizer on every `Isolate.run` call (~hundreds of ms) would
//     dwarf the ~18ms/token decode cost this is trying to measure/serve.
//
// The worker loop — one request at a time, close without a kill — lives in
// `gen_ai_worker.dart`; this file holds the main-isolate client and the
// `dart:ffi` engine that loop drives (`_FfiGenAiEngine`).
//
// GOTCHA (verified in the spike, and load-bearing here): on this GenAI
// version the prompt forward pass (prefill) runs INSIDE
// `OgaGenerator_AppendTokenSequences`, not the first `GenerateNextToken`.
// Every timing/stop-flag decision below assumes that.
//
// iOS shape (verified via otool -L / nm -gU on the extracted xcframework
// slice, see `hook/build.dart`'s iOS branch doc): Microsoft ships ONE image,
// `onnxruntime-genai.framework/onnxruntime-genai`, that STATICALLY links ORT
// and DYNAMICALLY EXPORTS BOTH APIs (`Oga*` here + `OrtGetApiBase` for the
// plain-ORT embedding arm in `ort_ffi_client.dart`). So [_openGenAiLibraries]
// opens a single library on iOS and returns it as both halves of its tuple —
// see that function's iOS branch.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:mutex/mutex.dart';

import 'gen_ai_protocol.dart';
import 'gen_ai_worker.dart';
import 'ort_genai_bindings.g.dart';

/// Env var override for host tests / macOS dev: a directory containing both
/// `libonnxruntime` and `libonnxruntime-genai` (platform-specific names) —
/// mirrors `ort_ffi_client.dart`'s `FLUTTER_GEMMA_ORT_LIBRARY` for the plain
/// ORT embedding arm. Production app builds never set this; `hook/build.dart`
/// (Task 4) resolves the CodeAsset bundle instead once it lands.
const genAiLibsDirEnvVar = 'FLUTTER_GEMMA_ORT_GENAI_LIBS';

/// One user turn to generate a response for. [GenAiFfiClient] applies the
/// model's own chat template (`OgaTokenizerApplyChatTemplate`) inside the
/// worker — callers (`OnnxSession`) pass raw content, never pre-formatted
/// turn markers (Task 3: onnx routes through the SDK-owns-templates path).
///
/// Must stay a plain sendable data class — it crosses the isolate port.
class GenAiTurn {
  const GenAiTurn({
    required this.userContent,
    this.systemInstruction,
    this.isFirstTurn = false,
    this.maxOutputTokens,
  });

  /// Raw user-turn content (tool responses are already folded into plain
  /// text by `Message._formatToolResponseContent` upstream, via the
  /// raw-mode `transformToChatPrompt`).
  final String userContent;

  /// System role content. Only sent (as a `system` message) on
  /// [isFirstTurn] — later turns rely on the persistent generator's KV
  /// cache to remember it, matching every other raw-mode engine's posture.
  final String? systemInstruction;

  /// True for the first turn of a session: destroys any live generator and
  /// creates a fresh one (fresh KV cache) instead of reusing it.
  final bool isFirstTurn;

  /// Cap on GENERATED tokens for this turn — distinct from the model's
  /// context-window `max_length`, which is set once when the generator is
  /// created (see [GenAiClient.load]'s `contextWindow`).
  final int? maxOutputTokens;
}

/// Prompt/decode counters for the most recently completed [GenAiClient.generate]
/// call — read via [GenAiClient.lastGenerationStats] for
/// [InferenceModelSession.getSessionMetrics].
class GenAiGenerationStats {
  const GenAiGenerationStats({
    required this.promptTokens,
    required this.generatedTokens,
    required this.decodeMs,
  });

  final int promptTokens;
  final int generatedTokens;

  /// Wall time of the decode loop only (excludes model load and prefill).
  final int decodeMs;

  double? get tokensPerSecond =>
      decodeMs > 0 ? generatedTokens * 1000.0 / decodeMs : null;
}

/// The `dart:ffi` seam for ORT-GenAI text generation. [GenAiFfiClient] is the
/// only implementation that touches native handles — see this file's doc for
/// why they live entirely inside a worker isolate. [OnnxSession] /
/// [OnnxInferenceModel] depend on this abstract type so unit tests can inject
/// a fake with zero dlopen (hardened plan Task 6).
abstract class GenAiClient {
  /// Loads the model + tokenizer from [modelDir] (an ORT-GenAI model
  /// directory: `genai_config.json` + `.onnx`(+`.onnx_data`) + tokenizer
  /// files). [contextWindow] sizes the persistent generator's `max_length` —
  /// the model's whole KV-cache budget (same number as
  /// `InferenceModel.maxTokens`), NOT the per-turn output cap (that's
  /// [GenAiTurn.maxOutputTokens]).
  Future<void> load(String modelDir, {int contextWindow = 1024});

  /// Streams decoded text for [turn]. Only one `generate()` call may be
  /// in-flight at a time — concrete clients serialize with a mutex; a second
  /// concurrent caller's stream doesn't start until the first completes.
  Stream<String> generate(GenAiTurn turn);

  /// Token count for [text] via the tokenizer's own encoder (no chat
  /// template applied) — used for [InferenceModelSession.sizeInTokens].
  Future<int> countTokens(String text);

  /// Stops the currently in-flight [generate] stream (no-op if none is
  /// active). Deliberately NOT covered by the `generate`/`countTokens`
  /// mutex — it must be able to interrupt a call that's holding it.
  Future<void> stopGeneration();

  /// Destroys the current generator so the NEXT [generate] call starts a
  /// fresh conversation (fresh KV cache) instead of continuing the live one.
  /// [OnnxSession.close] calls this so a superseded session never bleeds
  /// its history into whatever session is created next — the ORT-GenAI
  /// sibling of the `.litertlm` FFI engine's "close previous conversation
  /// before creating a new one" rule.
  Future<void> resetSession();

  /// Frees every native handle (generator, tokenizer, model) and stops the
  /// worker isolate — after the call in flight, however long it takes; the
  /// worker is never killed, because a killed worker frees nothing.
  /// Idempotent.
  Future<void> shutdown();

  /// Stats from the most recently completed [generate] call, or `null`
  /// before the first one finishes.
  GenAiGenerationStats? get lastGenerationStats;
}

/// Main-isolate handle to the ORT-GenAI worker. Spawns the isolate, performs
/// the load handshake, and multiplexes concurrent requests by id. See this
/// file's top doc for why native handles never cross the port. The message
/// protocol itself lives in `gen_ai_protocol.dart`, the worker loop in
/// `gen_ai_worker.dart`.
class GenAiFfiClient implements GenAiClient {
  /// [workerEntry] is the injection seam for tests — defaults to the real
  /// dlopen-ing `_defaultWorkerEntry`. Tests spawn a fake worker (real
  /// isolate, real ports, zero FFI) that runs the same worker loop
  /// (`serveGenAiWorker`) over a scripted engine, exercising the real
  /// dispatch/mutex/`_closed`-recheck machinery below and the real queue/close
  /// rules with no native library involved (hardened plan Task 2b) — that
  /// fake cannot speak to whether the FFI engine's native handle teardown is
  /// use-after-free-safe (only `onnx_generation_host_smoke_test.dart`, which
  /// runs against real ORT-GenAI libs, can). Never override it in production
  /// code.
  GenAiFfiClient({@visibleForTesting GenAiWorkerEntry? workerEntry})
    : _workerEntry = workerEntry ?? _defaultWorkerEntry;

  /// How long [shutdown] waits before saying it is still waiting. It keeps
  /// waiting afterwards: the only way to stop sooner is to kill the isolate,
  /// and a killed isolate never frees its native model.
  static const _slowCloseNotice = Duration(seconds: 30);

  final GenAiWorkerEntry _workerEntry;

  SendPort? _commandPort;
  ReceivePort? _fromWorker;
  StreamSubscription<dynamic>? _sub;

  /// The model directory [load] was given; names the model in warnings.
  String? _modelDir;

  /// Serializes `generate`/`countTokens` calls. [stopGeneration] is
  /// deliberately NOT gated by this — see its doc.
  final Mutex _mutex = Mutex();

  bool _loaded = false;

  /// True from the moment [shutdown] is called, or the worker dies; every
  /// call refuses from then on.
  bool _closed = false;

  /// Why the worker is gone when it went without being asked to — the text
  /// every later call fails with. Null otherwise.
  String? _deathReason;

  /// The error an uncaught exception in the worker reported through the
  /// spawn's `onError` port, kept until the `onExit` that follows it.
  String? _crashError;

  /// True once the worker's [CloseAck] arrived; the `onExit` after it is the
  /// normal end, not a death.
  bool _acked = false;

  /// Completes when the worker is gone: its [CloseAck], or its onExit.
  final _gone = Completer<void>();

  /// Completes, with the reason, when the worker exits without acking a
  /// [shutdown]; read through [unexpectedExitOf].
  final _unexpectedExit = Completer<String>();

  /// The one teardown every [shutdown] call shares.
  Future<void>? _shutdownFuture;

  int _nextId = 0;
  final Map<int, StreamController<String>> _activeStreams = {};
  final Map<int, Completer<void>> _streamDone = {};
  final Map<int, Completer<int>> _countPending = {};
  Completer<void>? _resetAck;

  GenAiGenerationStats? _lastStats;
  @override
  GenAiGenerationStats? get lastGenerationStats => _lastStats;

  @override
  Future<void> load(String modelDir, {int contextWindow = 1024}) async {
    if (_closed) {
      throw StateError('GenAiFfiClient is closed');
    }
    if (_loaded) {
      throw StateError('GenAiFfiClient is already loaded');
    }

    final fromWorker = ReceivePort();
    final readyCompleter = Completer<Ready>();

    // First message from the worker is either Ready or a String error. A
    // two-element List is an uncaught error (the onError port), and a `null`
    // is the isolate's onExit signal — if either arrives before Ready, the
    // worker died during load, so fail the completer instead of hanging.
    late final StreamSubscription<dynamic> sub;
    sub = fromWorker.listen((msg) {
      if (readyCompleter.isCompleted) return;
      if (msg is Ready) {
        readyCompleter.complete(msg);
      } else if (msg is String) {
        readyCompleter.completeError(StateError(msg));
      } else if (msg is List) {
        readyCompleter.completeError(
          StateError(
            'ONNX GenAI worker isolate failed during load: ${msg.first}',
          ),
        );
      } else if (msg == null) {
        readyCompleter.completeError(
          StateError('ONNX GenAI worker isolate exited during load'),
        );
      }
    });

    final envLibsDir = Platform.environment[genAiLibsDirEnvVar];
    final Ready ready;
    try {
      await Isolate.spawn(
        _workerEntry,
        WorkerInit(
          replyTo: fromWorker.sendPort,
          modelDir: modelDir,
          contextWindow: contextWindow,
          libsDir: (envLibsDir != null && envLibsDir.isNotEmpty)
              ? envLibsDir
              : null,
          logLevel: edgeAiLogLevel,
        ),
        // onError + onExit post to fromWorker so we never wait on a dead
        // isolate, and learn why it died when it says.
        onError: fromWorker.sendPort,
        onExit: fromWorker.sendPort,
        debugName: 'onnx-genai-worker',
      );
      ready = await readyCompleter.future;
    } catch (_) {
      // Nothing to kill. A worker that fails to load frees whatever it
      // allocated and leaves through `Isolate.exit` carrying the error, and
      // the onExit `null` means it is already gone. Killing it here instead
      // could land before that cleanup.
      await sub.cancel();
      fromWorker.close();
      rethrow;
    }

    _fromWorker = fromWorker;
    _commandPort = ready.commandPort;
    _modelDir = modelDir;
    _loaded = true;
    sub.onData(_dispatch);
    _sub = sub;
  }

  void _dispatch(dynamic msg) {
    if (msg is Chunk) {
      _activeStreams[msg.id]?.add(msg.text);
    } else if (msg is GenerateDone) {
      _lastStats = GenAiGenerationStats(
        promptTokens: msg.promptTokens,
        generatedTokens: msg.generatedTokens,
        decodeMs: msg.decodeMs,
      );
      final controller = _activeStreams.remove(msg.id);
      unawaited(controller?.close());
      _streamDone.remove(msg.id)?.complete();
    } else if (msg is GenerateError) {
      final controller = _activeStreams.remove(msg.id);
      controller?.addError(StateError(msg.error));
      unawaited(controller?.close());
      _streamDone.remove(msg.id)?.complete();
    } else if (msg is CountTokensReply) {
      final completer = _countPending.remove(msg.id);
      if (completer == null) return;
      if (msg.error != null) {
        completer.completeError(StateError(msg.error!));
      } else {
        completer.complete(msg.count!);
      }
    } else if (msg is ResetSessionAck) {
      _completeResetAck();
    } else if (msg is CloseAck) {
      _acked = true;
      if (msg.error case final error?) {
        _warn(
          'the ONNX GenAI model $_modelDir failed to close; its native model '
          'may still be resident: $error',
        );
      }
      if (!_gone.isCompleted) _gone.complete();
      _completeResetAck();
    } else if (msg is List) {
      // onError: an uncaught error is about to take the worker down. The
      // onExit `null` that follows reports it.
      _crashError = '${msg.first}';
    } else if (msg == null) {
      if (_acked) return; // the normal exit after a CloseAck.
      // The worker died without acking — an uncaught error, or an isolate
      // killed from outside. Its model may still be resident; fail everything
      // in flight rather than leave callers hanging, and refuse new calls
      // with the reason.
      final crash = _crashError;
      final what = _shutdownFuture == null
          ? 'exited unexpectedly'
          : 'exited while shutting down';
      final reason =
          'the ONNX GenAI worker isolate $what'
          '${crash == null ? '' : ': $crash'}';
      _deathReason = reason;
      _closed = true;
      _failAllPending(StateError(reason));
      _fromWorker?.close();
      _warn(
        '$reason (model $_modelDir); its native model may still be resident',
      );
      if (!_gone.isCompleted) _gone.complete();
      _completeResetAck();
      if (!_unexpectedExit.isCompleted) _unexpectedExit.complete(reason);
    }
  }

  void _completeResetAck() {
    if (_resetAck case final ack? when !ack.isCompleted) ack.complete();
  }

  void _failAllPending(StateError error) {
    for (final id in _activeStreams.keys.toList()) {
      final controller = _activeStreams.remove(id);
      controller?.addError(error);
      unawaited(controller?.close());
      _streamDone.remove(id)?.complete();
    }
    for (final c in _countPending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _countPending.clear();
  }

  /// The error a call gets once the client cannot serve it: [shutdown] ran,
  /// the worker died ([_deathReason]), or [load] never succeeded.
  StateError _unusable(String whenShutDown) {
    final death = _deathReason;
    return StateError(
      death == null ? whenShutDown : 'GenAiFfiClient is closed: $death',
    );
  }

  @override
  Stream<String> generate(GenAiTurn turn) {
    // If the consumer cancels its subscription (a plain `break` out of
    // `await for`, or a voice-loop barge-in) WITHOUT calling
    // [stopGeneration] itself, nothing would otherwise tell the worker to
    // stop decoding — it would keep generating to `max_length` while
    // `_runGenerateGuarded` sits on `done.future`, wedging `_mutex` for the
    // whole abandoned decode. Mirrors the litertlm engine's "StreamController
    // onCancel -> native cancel" fix (commit 93a5298). `stopGeneration` is
    // idempotent/cheap when the turn already finished normally.
    final controller = StreamController<String>(
      onCancel: () => unawaited(stopGeneration()),
    );
    unawaited(_runGenerateGuarded(controller, turn));
    return controller.stream;
  }

  Future<void> _runGenerateGuarded(
    StreamController<String> controller,
    GenAiTurn turn,
  ) async {
    if (_closed || !_loaded) {
      controller.addError(_unusable('GenAiFfiClient is not loaded'));
      await controller.close();
      return;
    }
    await _mutex.acquire();
    // Recheck AFTER acquiring: a caller that passed the check above can park
    // on the mutex behind an in-flight generate() while shutdown() runs to
    // completion (the worker stops the holder, frees its handles and exits,
    // the ports close) — without this recheck, the send below would go into
    // a dead port and `done.future` would never complete, hanging this stream
    // forever AND wedging the mutex for every caller behind it (hardened plan
    // Task 2, the FLAG fix — see `gen_ai_client_lifecycle_test.dart`'s
    // shutdown-while-generating test).
    final commandPort = _commandPort;
    if (_closed || commandPort == null) {
      _mutex.release();
      controller.addError(_unusable('GenAiFfiClient shut down'));
      await controller.close();
      return;
    }
    final id = _nextId++;
    final done = _streamDone[id] = Completer<void>();
    _activeStreams[id] = controller;
    try {
      commandPort.send(GenerateRequest(id, turn));
      await done.future;
    } catch (e) {
      if (_activeStreams.containsKey(id)) {
        controller.addError(e);
        _activeStreams.remove(id);
        await controller.close();
      }
    } finally {
      _streamDone.remove(id);
      _mutex.release();
    }
  }

  @override
  Future<int> countTokens(String text) {
    if (_closed || !_loaded) {
      throw _unusable('GenAiFfiClient is not loaded');
    }
    return _mutex.protect(() {
      // Same recheck as `_runGenerateGuarded` — see its comment. A caller
      // can pass the check above and then park on the mutex behind a
      // `shutdown()` that runs to completion before this callback gets the
      // mutex.
      final commandPort = _commandPort;
      if (_closed || commandPort == null) {
        throw _unusable('GenAiFfiClient shut down');
      }
      final id = _nextId++;
      final completer = Completer<int>();
      _countPending[id] = completer;
      commandPort.send(CountTokensRequest(id, text));
      return completer.future;
    });
  }

  @override
  Future<void> stopGeneration() async {
    _commandPort?.send(const StopSignal());
  }

  @override
  Future<void> resetSession() async {
    final commandPort = _commandPort;
    if (_closed || commandPort == null) return;
    final ack = _resetAck = Completer<void>();
    commandPort.send(const ResetSessionRequest());
    try {
      await ack.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // The worker is still busy with the call ahead of the reset — a long
      // prefill. Nothing more to do here: the reset stays queued in front of
      // any later request, so it still runs before the next turn.
    }
  }

  /// Stops the worker without abandoning its native model.
  ///
  /// Requests the worker has not started fail with a "shut down"
  /// [StateError]. A generation in flight stops at its next token and its
  /// stream ends normally; a token count in flight finishes. Then the worker
  /// frees the generator, tokenizer and model, acks and exits, and this
  /// returns.
  ///
  /// It waits for all of that however long the call in flight takes (a
  /// prefill is one synchronous native call), and never kills the isolate: a
  /// killed isolate runs no more Dart code, so its handles are never freed
  /// and the model stays resident for the life of the process. After
  /// [_slowCloseNotice] it says what it is waiting for, once.
  ///
  /// Idempotent; concurrent callers share one teardown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _shutDown();

  Future<void> _shutDown() async {
    _closed = true;
    final commandPort = _commandPort;
    if (commandPort == null) {
      // Never loaded (or load failed) — nothing native to tear down.
      return;
    }
    if (!_gone.isCompleted) {
      commandPort.send(const Close());
      final notice = Timer(
        _slowCloseNotice,
        () => _warn(
          'GenAiFfiClient.shutdown() has waited '
          '${_slowCloseNotice.inSeconds} s for the ONNX GenAI worker of '
          '$_modelDir to finish the call it is running, if any, and free its '
          'native model. It keeps waiting rather than kill the worker, '
          'because a killed worker never frees its native model.',
        ),
      );
      try {
        await _gone.future;
      } finally {
        notice.cancel();
      }
    }
    await _sub?.cancel();
    _fromWorker?.close();
    // The worker answers every request it received before it acks, and the
    // port delivers in order, so this is empty — unless the worker died, and
    // then onExit has already failed them. A net, not a path.
    _failAllPending(StateError('GenAiFfiClient shut down'));
  }

  /// `print`, not [edgeAiLog]: edgeAiLog is silent in release, and release is
  /// where a leaked native model or a hung shutdown gets debugged. Both are
  /// abnormal, so this costs nothing in the normal case.
  static void _warn(String message) {
    // ignore: avoid_print
    print('[flutter_edge_ai_onnx] WARNING: $message');
  }
}

/// Completes, with the reason, when [client]'s worker exits without being
/// asked to — an uncaught error, or an isolate killed from outside — and never
/// after a clean [GenAiClient.shutdown]. Null for a client that has no worker
/// of its own (any [GenAiClient] that is not a [GenAiFfiClient]).
///
/// `OnnxInferenceModel` listens to it to turn itself closed and fire its
/// close listeners (R5 W6). A top-level function rather than a member, and
/// not exported, so the public [GenAiClient] and [GenAiFfiClient] surface
/// stays as it is.
Future<String>? unexpectedExitOf(GenAiClient client) => switch (client) {
  GenAiFfiClient() => client._unexpectedExit.future,
  _ => null,
};

// ---------------------------------------------------------------------------
// Worker isolate: library loading and the dart:ffi engine.
// ---------------------------------------------------------------------------

/// Candidate paths/names to try opening [libraryName] (bare, no `lib`
/// prefix/extension) with, in priority order, for the current platform.
///
/// On macOS the FIRST candidate is the CodeAsset's framework leaf name
/// (`hook/build.dart` registers each dylib under a bare asset name; Flutter's
/// macOS build wraps every CodeAsset in its own `<name>.framework`, renaming
/// the binary inside to `<name>.framework/<name>`) — Task 4's framework-wrap
/// risk: GenAI dlopens `libonnxruntime.dylib` by BARE LEAF NAME at runtime,
/// which does not automatically resolve to an already-loaded framework-wrapped
/// image unless something opens it by its real (framework) path FIRST, putting
/// it in dyld's loaded-image set before GenAI's own lookup runs. The bare
/// `lib<name>.dylib` names are a fallback for host runs that bypass the
/// CodeAsset bundle (`flutter test`, the macOS host smoke test's `libsDir`
/// override takes priority over all of this — see [_openGenAiLibraries]).
///
/// iOS gets its OWN branch, deliberately NOT grouped with macOS: iOS dyld 4
/// cannot resolve a bare `<name>.framework/<name>` leaf name the way macOS's
/// dyld does — it needs an explicit anchor, exactly the
/// `@executable_path/Frameworks/<name>.framework/<name>` shape
/// `flutter_edge_ai_litertlm/lib/src/ffi/litert_lm_client.dart` already uses
/// (and documents, with the same "dyld 4 cannot resolve from .framework
/// names alone" reasoning) for `LiteRtLm.framework`/`StreamProxy.framework`.
/// A bare leaf name here would dlopen-fail on every real iPhone (and the
/// simulator — verified: unanchored fails there too). This list is only ever
/// consulted for `'onnxruntime-genai'` on iOS — the platform ships one image
/// serving both APIs (see [_openGenAiLibraries]'s iOS branch), so
/// `'onnxruntime'` is never opened there.
List<String> _candidateNames(String libraryName) {
  if (Platform.isIOS) {
    return [
      '@executable_path/Frameworks/$libraryName.framework/$libraryName',
      'lib$libraryName.dylib',
    ];
  }
  if (Platform.isMacOS) {
    return ['$libraryName.framework/$libraryName', 'lib$libraryName.dylib'];
  }
  if (Platform.isLinux || Platform.isAndroid) return ['lib$libraryName.so'];
  if (Platform.isWindows) return ['$libraryName.dll'];
  throw UnsupportedError(
    'ONNX GenAI is not available on ${Platform.operatingSystem}',
  );
}

ffi.DynamicLibrary _openFirst(List<String> candidates) {
  Object? lastError;
  for (final path in candidates) {
    try {
      return ffi.DynamicLibrary.open(path);
    } catch (e) {
      lastError = e;
    }
  }
  throw StateError('Could not open any of $candidates. Last error: $lastError');
}

/// POSIX `Dl_info` — only `dli_fname` (the absolute on-disk path of the image
/// a symbol lives in) is used here.
final class _DlInfo extends ffi.Struct {
  external ffi.Pointer<pkg_ffi.Utf8> dli_fname;
  external ffi.Pointer<ffi.Void> dli_fbase;
  external ffi.Pointer<pkg_ffi.Utf8> dli_sname;
  external ffi.Pointer<ffi.Void> dli_saddr;
}

typedef _DladdrNative =
    ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_DlInfo>);
typedef _DladdrDart = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_DlInfo>);
typedef _SetenvNative =
    ffi.Int32 Function(
      ffi.Pointer<pkg_ffi.Utf8>,
      ffi.Pointer<pkg_ffi.Utf8>,
      ffi.Int32,
    );
typedef _SetenvDart =
    int Function(ffi.Pointer<pkg_ffi.Utf8>, ffi.Pointer<pkg_ffi.Utf8>, int);

/// Resolves the absolute on-disk path of the already-loaded [ortLib] via
/// `dladdr` on its `OrtGetApiBase` symbol, then exports it as `ORT_LIB_PATH`.
///
/// This is the fix for the framework-wrap co-location blocker: onnxruntime-genai
/// resolves onnxruntime at runtime by a bare `dlopen("libonnxruntime.dylib")`
/// (a string constant, not a Mach-O load command — nothing for install_name_tool
/// to patch) with a `dladdr`-based "next to my own binary" fallback. Under
/// Flutter's Native-Assets `.framework` wrapping the two libs land in SEPARATE
/// `.framework` bundles, so that fallback fails. But GenAI's `InitApi()` checks
/// the `ORT_LIB_PATH` env var FIRST and unconditionally `dlopen`s that absolute
/// path — Microsoft's own sanctioned override. We set it before GenAI's dylib
/// static initializer runs (i.e. before opening its library), pointing at ORT's
/// real path (whatever Flutter named the framework), so resolution succeeds with
/// zero packaging/Podfile/hook changes. No-op on platforms without
/// dladdr/setenv. iOS keeps the `Platform.isIOS` gate below (this function IS
/// harmless there — genai's iOS build is static, so `ORT_LIB_PATH` is simply
/// never consulted) but [_openGenAiLibraries]'s iOS branch never calls this
/// function at all — see its doc for why an explicit skip is cleaner than
/// relying on this being a no-op.
void _exportOrtLibPath(ffi.DynamicLibrary ortLib) {
  if (!(Platform.isMacOS || Platform.isIOS || Platform.isLinux)) return;
  final proc = ffi.DynamicLibrary.process();
  final dladdr = proc.lookupFunction<_DladdrNative, _DladdrDart>('dladdr');
  final setenv = proc.lookupFunction<_SetenvNative, _SetenvDart>('setenv');
  final info = pkg_ffi.calloc<_DlInfo>();
  final namePtr = 'ORT_LIB_PATH'.toNativeUtf8();
  ffi.Pointer<pkg_ffi.Utf8>? valuePtr;
  try {
    final sym = ortLib.lookup<ffi.Void>('OrtGetApiBase');
    if (dladdr(sym, info) == 0 || info.ref.dli_fname == ffi.nullptr) return;
    final ortPath = info.ref.dli_fname.toDartString();
    valuePtr = ortPath.toNativeUtf8();
    setenv(namePtr, valuePtr, 1); // overwrite
    edgeAiLog('[OnnxGenAi] ORT_LIB_PATH=$ortPath');
  } catch (_) {
    // Best-effort: if the env override can't be set, GenAI still tries its
    // bare-name + self-directory paths (works for the flat host-test layout).
  } finally {
    pkg_ffi.calloc.free(info);
    pkg_ffi.calloc.free(namePtr);
    if (valuePtr != null) pkg_ffi.calloc.free(valuePtr);
  }
}

(ffi.DynamicLibrary, ffi.DynamicLibrary) _openGenAiLibraries(String? libsDir) {
  if (Platform.isIOS && libsDir == null) {
    // iOS ships ONE self-contained framework: onnxruntime-genai statically
    // links ORT and exports both APIs (`Oga*` + `OrtGetApiBase`) from the
    // same binary — verified via `otool -L` (zero LC_LOAD_DYLIB on
    // onnxruntime) and `nm -gU` (both symbol sets present) on the extracted
    // xcframework slice. See `hook/build.dart`'s iOS branch (single
    // CodeAsset, `ort: null`) and this file's top doc. Skip the two-library
    // open/`ORT_LIB_PATH` dance entirely: there is no separate onnxruntime
    // dylib to co-locate with, and genai does no runtime dlopen of ORT on
    // iOS (a static build, unlike macOS's `MACOS_USE_DLOPEN` path) — calling
    // `_exportOrtLibPath` here would be a harmless no-op (its own
    // `Platform.isIOS` gate stays for that reason) but an explicit skip is
    // cleaner than relying on it.
    final genaiLib = _openFirst(_candidateNames('onnxruntime-genai'));
    return (genaiLib, genaiLib);
  }

  final ffi.DynamicLibrary ortLib;
  if (libsDir != null) {
    // Host-test override (FLUTTER_GEMMA_ORT_GENAI_LIBS / the macOS host
    // smoke test): exact spike layout, bare platform-default names in one
    // directory — bypasses the CodeAsset bundle entirely.
    final ortName = _candidateNames('onnxruntime').last;
    ortLib = ffi.DynamicLibrary.open('$libsDir/$ortName');
  } else {
    ortLib = _openFirst(_candidateNames('onnxruntime'));
  }
  ortLib.providesSymbol('OrtGetApiBase'); // keep ortLib reachable/loaded

  // Point GenAI's InitApi() at ORT's real absolute path BEFORE its dylib static
  // initializer (which resolves ORT) runs — i.e. before we open the GenAI lib.
  _exportOrtLibPath(ortLib);

  final genaiLib = libsDir != null
      ? ffi.DynamicLibrary.open(
          '$libsDir/${_candidateNames('onnxruntime-genai').last}',
        )
      : _openFirst(_candidateNames('onnxruntime-genai'));
  return (ortLib, genaiLib);
}

Future<void> _defaultWorkerEntry(WorkerInit init) =>
    serveGenAiWorker(init, _FfiGenAiEngine(init));

/// The production [GenAiWorkerEngine]: every native handle — model,
/// tokenizer, generator — is created, used and destroyed here, on the worker
/// isolate.
final class _FfiGenAiEngine implements GenAiWorkerEngine {
  _FfiGenAiEngine(this._init);

  final WorkerInit _init;

  /// Null until [load] opened the libraries. Every handle below is created
  /// through it, so a non-null handle implies non-null bindings.
  OrtGenAiBindings? _oga;
  ffi.Pointer<OgaModel>? _model;
  ffi.Pointer<OgaTokenizer>? _tokenizer;
  ffi.Pointer<OgaGenerator>? _generator;

  OrtGenAiBindings get _bindings =>
      _oga ?? (throw StateError('ORT-GenAI engine used before it was loaded'));

  ffi.Pointer<OgaModel> get _loadedModel =>
      _model ?? (throw StateError('ORT-GenAI model is not loaded'));

  ffi.Pointer<OgaTokenizer> get _loadedTokenizer =>
      _tokenizer ?? (throw StateError('ORT-GenAI tokenizer is not loaded'));

  void _check(ffi.Pointer<OgaResult> result, String step) {
    if (result == ffi.nullptr) return;
    final oga = _bindings;
    // Free the result in `finally` — mirrors `ort_ffi_client.dart`'s
    // `_check()` — so a non-UTF-8 error message (toDartString() throwing)
    // can't leak the native OgaResult handle.
    try {
      final errPtr = oga.OgaResultGetError(result);
      final message = errPtr == ffi.nullptr
          ? '<no message>'
          : errPtr.cast<pkg_ffi.Utf8>().toDartString();
      throw StateError('ORT-GenAI $step failed: $message');
    } finally {
      oga.OgaDestroyResult(result);
    }
  }

  @override
  Future<void> load() async {
    final (ortLib, genaiLib) = _openGenAiLibraries(_init.libsDir);
    // ignore: unused_local_variable — kept reachable so the image isn't GC'd.
    final keepOrtLibLoaded = ortLib;
    final oga = _oga = OrtGenAiBindings(genaiLib);

    final configPathC = _init.modelDir.toNativeUtf8();
    final modelOut = pkg_ffi.calloc<ffi.Pointer<OgaModel>>();
    try {
      _check(
        oga.OgaCreateModel(configPathC.cast(), modelOut),
        'OgaCreateModel',
      );
      _model = modelOut.value;
    } finally {
      pkg_ffi.calloc.free(configPathC);
      pkg_ffi.calloc.free(modelOut);
    }

    final tokenizerOut = pkg_ffi.calloc<ffi.Pointer<OgaTokenizer>>();
    try {
      _check(
        oga.OgaCreateTokenizer(_loadedModel, tokenizerOut),
        'OgaCreateTokenizer',
      );
      _tokenizer = tokenizerOut.value;
    } finally {
      pkg_ffi.calloc.free(tokenizerOut);
    }
  }

  /// Runs one turn: (re)creates the generator if needed, applies the chat
  /// template, prefills, then decodes token-by-token, passing pieces to
  /// [emit] as they arrive. The `await Future(() {})` yields are what let a
  /// queued `StopSignal`/`ResetSessionRequest`/`Close` flip [stopRequested].
  @override
  Future<GenAiGenerationStats> generate(
    GenAiTurn turn, {
    required void Function(String piece) emit,
    required bool Function() stopRequested,
  }) async {
    final oga = _bindings;
    final model = _loadedModel;
    final tokenizer = _loadedTokenizer;
    ffi.Pointer<OgaTokenizerStream>? tokenizerStream;
    try {
      if (turn.isFirstTurn) resetGenerator();

      final generator = _generator ?? _createGenerator(oga, model);
      _generator = generator;

      // --- Chat template (SDK-owns-templates, Task 3) ----------------------
      final messages = <Map<String, String>>[
        if (turn.isFirstTurn && (turn.systemInstruction?.isNotEmpty ?? false))
          {'role': 'system', 'content': turn.systemInstruction!},
        {'role': 'user', 'content': turn.userContent},
      ];
      final messagesJsonC = jsonEncode(messages).toNativeUtf8();
      final templatedOut = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>();
      final String templated;
      try {
        _check(
          oga.OgaTokenizerApplyChatTemplate(
            tokenizer,
            ffi.nullptr, // template_str: use the tokenizer's own built-in
            messagesJsonC.cast(),
            ffi.nullptr, // tools
            true, // add_generation_prompt
            templatedOut,
          ),
          'OgaTokenizerApplyChatTemplate',
        );
        templated = templatedOut.value.cast<pkg_ffi.Utf8>().toDartString();
      } finally {
        pkg_ffi.calloc.free(messagesJsonC);
        if (templatedOut.value != ffi.nullptr) {
          oga.OgaDestroyString(templatedOut.value);
        }
        pkg_ffi.calloc.free(templatedOut);
      }

      // --- Encode + prefill (AppendTokenSequences) -------------------------
      // Prefill runs INSIDE AppendTokenSequences on this GenAI version, not
      // the first GenerateNextToken (verified spike gotcha).
      final sequencesOut = pkg_ffi.calloc<ffi.Pointer<OgaSequences>>();
      final ffi.Pointer<OgaSequences> sequences;
      try {
        _check(oga.OgaCreateSequences(sequencesOut), 'OgaCreateSequences');
        sequences = sequencesOut.value;
      } finally {
        pkg_ffi.calloc.free(sequencesOut);
      }
      final promptC = templated.toNativeUtf8();
      final int promptTokens;
      try {
        _check(
          oga.OgaTokenizerEncode(tokenizer, promptC.cast(), sequences),
          'OgaTokenizerEncode',
        );
        promptTokens = oga.OgaSequencesGetSequenceCount(sequences, 0);
        _check(
          oga.OgaGenerator_AppendTokenSequences(generator, sequences),
          'OgaGenerator_AppendTokenSequences (prefill)',
        );
      } finally {
        pkg_ffi.calloc.free(promptC);
        oga.OgaDestroySequences(sequences);
      }

      final streamOut = pkg_ffi.calloc<ffi.Pointer<OgaTokenizerStream>>();
      try {
        _check(
          oga.OgaCreateTokenizerStream(tokenizer, streamOut),
          'OgaCreateTokenizerStream',
        );
        tokenizerStream = streamOut.value;
      } finally {
        pkg_ffi.calloc.free(streamOut);
      }
      final stream = tokenizerStream;

      var generatedCount = 0;
      final cap = turn.maxOutputTokens;

      void decodeAndEmit() {
        final outPtr = pkg_ffi.calloc<ffi.Pointer<ffi.Int32>>();
        final outCount = pkg_ffi.calloc<ffi.Size>();
        final int token;
        try {
          _check(
            oga.OgaGenerator_GetNextTokens(generator, outPtr, outCount),
            'OgaGenerator_GetNextTokens',
          );
          token = outPtr.value[outCount.value - 1];
        } finally {
          pkg_ffi.calloc.free(outPtr);
          pkg_ffi.calloc.free(outCount);
        }
        final decodedOut = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>();
        try {
          _check(
            oga.OgaTokenizerStreamDecode(stream, token, decodedOut),
            'OgaTokenizerStreamDecode',
          );
          // `out` from OgaTokenizerStreamDecode is owned by the stream — do
          // NOT OgaDestroyString it (unlike OgaTokenizerDecode's out_string).
          final piece = decodedOut.value == ffi.nullptr
              ? ''
              : decodedOut.value.cast<pkg_ffi.Utf8>().toDartString();
          if (piece.isNotEmpty) emit(piece);
        } finally {
          pkg_ffi.calloc.free(decodedOut);
        }
        generatedCount++;
      }

      // Prefill above is one long synchronous FFI call with no `await` in
      // it — a `StopSignal` sent while it was running sits unprocessed in
      // the isolate's mailbox the whole time (the worker's port listener
      // can't file it until this function yields), so it would otherwise
      // ALWAYS survive to force one unconditional token out of the
      // just-primed generator. Yield once here, mirroring the decode loop's
      // own per-token yield below, so that already-queued stop lands before
      // (not after) the first token is spent.
      await Future<void>(() {});
      if (!stopRequested()) {
        _check(
          oga.OgaGenerator_GenerateNextToken(generator),
          'OgaGenerator_GenerateNextToken (first token)',
        );
        decodeAndEmit();
      }

      // Timed separately from prefill+first-token, matching the spike: the
      // first token's forward pass rides along with AppendTokenSequences.
      final swDecode = Stopwatch()..start();
      while (!oga.OgaGenerator_IsDone(generator) &&
          (cap == null || generatedCount < cap)) {
        // Yield one event-loop turn per token so a queued StopSignal can
        // flip `stopRequested` before the next token is generated.
        await Future<void>(() {});
        if (stopRequested()) break;
        _check(
          oga.OgaGenerator_GenerateNextToken(generator),
          'OgaGenerator_GenerateNextToken (decode)',
        );
        decodeAndEmit();
      }
      swDecode.stop();

      return GenAiGenerationStats(
        promptTokens: promptTokens,
        generatedTokens: generatedCount,
        decodeMs: swDecode.elapsedMilliseconds,
      );
    } finally {
      if (tokenizerStream != null) {
        oga.OgaDestroyTokenizerStream(tokenizerStream);
      }
    }
  }

  ffi.Pointer<OgaGenerator> _createGenerator(
    OrtGenAiBindings oga,
    ffi.Pointer<OgaModel> model,
  ) {
    final paramsOut = pkg_ffi.calloc<ffi.Pointer<OgaGeneratorParams>>();
    final ffi.Pointer<OgaGeneratorParams> params;
    try {
      _check(
        oga.OgaCreateGeneratorParams(model, paramsOut),
        'OgaCreateGeneratorParams',
      );
      params = paramsOut.value;
    } finally {
      pkg_ffi.calloc.free(paramsOut);
    }
    final maxLengthNameC = 'max_length'.toNativeUtf8();
    try {
      _check(
        oga.OgaGeneratorParamsSetSearchNumber(
          params,
          maxLengthNameC.cast(),
          _init.contextWindow.toDouble(),
        ),
        'OgaGeneratorParamsSetSearchNumber(max_length)',
      );
      final genOut = pkg_ffi.calloc<ffi.Pointer<OgaGenerator>>();
      try {
        _check(
          oga.OgaCreateGenerator(model, params, genOut),
          'OgaCreateGenerator',
        );
        return genOut.value;
      } finally {
        pkg_ffi.calloc.free(genOut);
      }
    } finally {
      pkg_ffi.calloc.free(maxLengthNameC);
      oga.OgaDestroyGeneratorParams(params);
    }
  }

  @override
  int countTokens(String text) {
    final oga = _bindings;
    final sequencesOut = pkg_ffi.calloc<ffi.Pointer<OgaSequences>>();
    final ffi.Pointer<OgaSequences> sequences;
    try {
      _check(oga.OgaCreateSequences(sequencesOut), 'OgaCreateSequences');
      sequences = sequencesOut.value;
    } finally {
      pkg_ffi.calloc.free(sequencesOut);
    }
    final textC = text.toNativeUtf8();
    try {
      _check(
        oga.OgaTokenizerEncode(_loadedTokenizer, textC.cast(), sequences),
        'OgaTokenizerEncode',
      );
      return oga.OgaSequencesGetSequenceCount(sequences, 0);
    } finally {
      pkg_ffi.calloc.free(textC);
      oga.OgaDestroySequences(sequences);
    }
  }

  @override
  void resetGenerator() {
    final generator = _generator;
    if (generator == null) return;
    // Forgotten first, so a throw below cannot hand the next turn a
    // generator that is half destroyed.
    _generator = null;
    _bindings.OgaDestroyGenerator(generator);
  }

  /// Destroys generator, tokenizer and model — whichever exist, so a load
  /// that failed halfway is cleaned up too.
  @override
  void close() {
    final oga = _oga;
    if (oga == null) return; // the libraries never opened: nothing to free.
    final generator = _generator;
    final tokenizer = _tokenizer;
    final model = _model;
    _generator = null;
    _tokenizer = null;
    _model = null;
    if (generator != null) oga.OgaDestroyGenerator(generator);
    if (tokenizer != null) oga.OgaDestroyTokenizer(tokenizer);
    if (model != null) oga.OgaDestroyModel(model);
  }
}
