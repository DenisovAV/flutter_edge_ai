// ORT-GenAI text generation over `dart:ffi`, driven from a long-lived worker
// isolate — the productionized form of the throughput spike at
// `scratchpad/ort_genai_spike/bin/main.dart` (hardened plan Phase 3, Task 1).
//
// Why a long-lived worker and not `Isolate.run` per call (mirrors
// `EmbeddingWorker`'s doc, `flutter_gemma/lib/core/embedding/embedding_worker.dart`):
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
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:mutex/mutex.dart';

import 'gen_ai_protocol.dart';
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

  /// Frees every native handle (generator, tokenizer, model) and kills the
  /// worker isolate. Idempotent.
  Future<void> shutdown();

  /// Stats from the most recently completed [generate] call, or `null`
  /// before the first one finishes.
  GenAiGenerationStats? get lastGenerationStats;
}

/// Main-isolate handle to the ORT-GenAI worker. Spawns the isolate, performs
/// the load handshake, and multiplexes concurrent requests by id. See this
/// file's top doc for why native handles never cross the port. The message
/// protocol itself lives in `gen_ai_protocol.dart`.
class GenAiFfiClient implements GenAiClient {
  /// [workerEntry] is the injection seam for tests — defaults to the real
  /// dlopen-ing `_defaultWorkerEntry`. Tests spawn a scripted fake worker
  /// (real isolate, real ports, zero FFI) that speaks the same
  /// `gen_ai_protocol.dart` message shapes, exercising the real dispatch/
  /// mutex/`_closed`-recheck machinery below with no native library involved
  /// (hardened plan Task 2b) — that fake cannot speak to whether the real
  /// worker's native handle teardown is use-after-free-safe (only
  /// `onnx_generation_host_smoke_test.dart`, which runs against real ORT-GenAI
  /// libs, can). Never override it in production code.
  GenAiFfiClient({@visibleForTesting GenAiWorkerEntry? workerEntry})
    : _workerEntry = workerEntry ?? _defaultWorkerEntry;

  final GenAiWorkerEntry _workerEntry;

  Isolate? _isolate;
  SendPort? _commandPort;
  ReceivePort? _fromWorker;
  StreamSubscription? _sub;

  /// Serializes `generate`/`countTokens` calls. [stopGeneration] is
  /// deliberately NOT gated by this — see its doc.
  final Mutex _mutex = Mutex();

  bool _loaded = false;
  bool _closed = false;

  int _nextId = 0;
  final Map<int, StreamController<String>> _activeStreams = {};
  final Map<int, Completer<void>> _streamDone = {};
  final Map<int, Completer<int>> _countPending = {};
  Completer<void>? _closeAck;
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

    late final StreamSubscription sub;
    sub = fromWorker.listen((msg) {
      if (msg is Ready) {
        if (!readyCompleter.isCompleted) readyCompleter.complete(msg);
      } else if (msg is String) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(StateError(msg));
        }
      } else if (msg == null) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(
            StateError('ONNX GenAI worker isolate exited during load'),
          );
        }
      }
    });

    final envLibsDir = Platform.environment[genAiLibsDirEnvVar];
    final isolate = await Isolate.spawn(
      _workerEntry,
      WorkerInit(
        replyTo: fromWorker.sendPort,
        modelDir: modelDir,
        contextWindow: contextWindow,
        libsDir: (envLibsDir != null && envLibsDir.isNotEmpty)
            ? envLibsDir
            : null,
        logLevel: gemmaLogLevel,
      ),
      onExit: fromWorker.sendPort,
      debugName: 'onnx-genai-worker',
    );

    final Ready ready;
    try {
      ready = await readyCompleter.future;
    } catch (_) {
      await sub.cancel();
      fromWorker.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }

    _isolate = isolate;
    _fromWorker = fromWorker;
    _commandPort = ready.commandPort;
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
      if (_resetAck case final ack? when !ack.isCompleted) ack.complete();
    } else if (msg is CloseAck) {
      if (_closeAck case final ack? when !ack.isCompleted) ack.complete();
    } else if (msg == null) {
      // Worker died unexpectedly (onExit signal). Fail everything in-flight
      // rather than leave callers hanging forever.
      final err = StateError('ONNX GenAI worker isolate exited unexpectedly');
      for (final id in _activeStreams.keys.toList()) {
        final controller = _activeStreams.remove(id);
        controller?.addError(err);
        unawaited(controller?.close());
        _streamDone.remove(id)?.complete();
      }
      for (final c in _countPending.values) {
        if (!c.isCompleted) c.completeError(err);
      }
      _countPending.clear();
      _closed = true;
      if (_closeAck case final ack? when !ack.isCompleted) ack.complete();
      if (_resetAck case final ack? when !ack.isCompleted) ack.complete();
    }
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
      controller.addError(StateError('GenAiFfiClient is not loaded'));
      await controller.close();
      return;
    }
    await _mutex.acquire();
    // Recheck AFTER acquiring: a caller that passed the check above can park
    // on the mutex behind an in-flight generate() while shutdown() runs to
    // completion (drains the holder, kills the worker isolate, closes the
    // ports) — without this recheck, `_commandPort!.send(...)` below would
    // send into a dead port and `done.future` would never complete, hanging
    // this stream forever AND wedging the mutex for every caller behind it
    // (hardened plan Task 2, the FLAG fix — see
    // `gen_ai_client_lifecycle_test.dart`'s shutdown-while-generating test).
    if (_closed) {
      _mutex.release();
      controller.addError(StateError('GenAiFfiClient shut down'));
      await controller.close();
      return;
    }
    final id = _nextId++;
    final done = _streamDone[id] = Completer<void>();
    _activeStreams[id] = controller;
    try {
      _commandPort!.send(GenerateRequest(id, turn));
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
      throw StateError('GenAiFfiClient is not loaded');
    }
    return _mutex.protect(() {
      // Same recheck as `_runGenerateGuarded` — see its comment. A caller
      // can pass the check above and then park on the mutex behind a
      // `shutdown()` that runs to completion before this callback gets the
      // mutex.
      if (_closed) {
        throw StateError('GenAiFfiClient shut down');
      }
      final id = _nextId++;
      final completer = Completer<int>();
      _countPending[id] = completer;
      _commandPort!.send(CountTokensRequest(id, text));
      return completer.future;
    });
  }

  @override
  Future<void> stopGeneration() async {
    if (_commandPort == null) return;
    _commandPort!.send(const StopSignal());
  }

  @override
  Future<void> resetSession() async {
    if (_closed || _commandPort == null) return;
    final ack = _resetAck = Completer<void>();
    _commandPort!.send(const ResetSessionRequest());
    try {
      await ack.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Timed out or the worker died — fall through, nothing more to do.
    }
  }

  @override
  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    if (_commandPort == null) {
      // Never loaded (or load failed) — nothing native to tear down.
      return;
    }
    final ack = _closeAck = Completer<void>();
    _commandPort!.send(const Close());
    try {
      await ack.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Timed out or the worker already died — fall through to a forced kill.
    }
    await _sub?.cancel();
    _fromWorker?.close();
    _isolate?.kill(priority: Isolate.beforeNextEvent);

    final err = StateError('GenAiFfiClient shut down');
    for (final id in _activeStreams.keys.toList()) {
      final controller = _activeStreams.remove(id);
      controller?.addError(err);
      unawaited(controller?.close());
      _streamDone.remove(id)?.complete();
    }
    for (final c in _countPending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _countPending.clear();
  }
}

// ---------------------------------------------------------------------------
// Worker isolate entry point.
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
/// `flutter_gemma_litertlm/lib/src/ffi/litert_lm_client.dart` already uses
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
    gemmaLog('[OnnxGenAi] ORT_LIB_PATH=$ortPath');
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

Future<void> _defaultWorkerEntry(WorkerInit init) async {
  gemmaLogLevel = init.logLevel;

  late final OrtGenAiBindings oga;

  void check(ffi.Pointer<OgaResult> result, String step) {
    if (result == ffi.nullptr) return;
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

  ffi.Pointer<OgaModel>? model;
  ffi.Pointer<OgaTokenizer>? tokenizer;
  ffi.Pointer<OgaGenerator>? generator;

  try {
    final (ortLib, genaiLib) = _openGenAiLibraries(init.libsDir);
    // ignore: unused_local_variable — kept reachable so the image isn't GC'd.
    final keepOrtLibLoaded = ortLib;
    oga = OrtGenAiBindings(genaiLib);

    final configPathC = init.modelDir.toNativeUtf8();
    final modelOut = pkg_ffi.calloc<ffi.Pointer<OgaModel>>();
    try {
      check(oga.OgaCreateModel(configPathC.cast(), modelOut), 'OgaCreateModel');
      model = modelOut.value;
    } finally {
      pkg_ffi.calloc.free(configPathC);
      pkg_ffi.calloc.free(modelOut);
    }

    final tokenizerOut = pkg_ffi.calloc<ffi.Pointer<OgaTokenizer>>();
    try {
      check(oga.OgaCreateTokenizer(model, tokenizerOut), 'OgaCreateTokenizer');
      tokenizer = tokenizerOut.value;
    } finally {
      pkg_ffi.calloc.free(tokenizerOut);
    }
  } catch (e, st) {
    gemmaLog('[GenAiFfiClient/worker] load failed: $e\n$st');
    if (model != null) {
      try {
        oga.OgaDestroyModel(model);
      } catch (_) {}
    }
    init.replyTo.send('ONNX GenAI worker failed to load: $e');
    return;
  }

  final commandPort = ReceivePort();
  init.replyTo.send(Ready(commandPort.sendPort));

  var stopRequested = false;

  /// The in-flight [runGenerate] call, if any — the command loop below is
  /// `unawaited` on purpose (so a queued `StopSignal` can interleave via the
  /// decode loop's per-token yield), but that also means a teardown message
  /// arriving while a generation is still running would otherwise race it:
  /// `ResetSessionRequest`/`Close` destroy `generator`/`tokenizer`/`model`
  /// out from under the suspended decode loop, which then resumes and hands
  /// the freed pointer straight to native calls (use-after-free). Every
  /// teardown branch below sets [stopRequested] (so the decode loop unwinds
  /// promptly, bounded to ~one token) and awaits this future FIRST, so
  /// `runGenerate`'s own `finally` (which destroys its `tokenizerStream`) has
  /// already run before any generator/tokenizer/model handle is freed.
  Future<void>? activeGeneration;

  /// Runs one turn: (re)creates the generator if needed, applies the chat
  /// template, prefills, then decodes token-by-token, streaming pieces back
  /// as they arrive. Deliberately NOT awaited by the command loop below —
  /// the `await Future(() {})` yield inside the decode loop is what lets a
  /// queued `StopSignal` interleave and flip [stopRequested].
  Future<void> runGenerate(int id, GenAiTurn turn) async {
    stopRequested = false;
    ffi.Pointer<OgaTokenizerStream>? tokenizerStream;
    try {
      if (turn.isFirstTurn && generator != null) {
        oga.OgaDestroyGenerator(generator!);
        generator = null;
      }

      if (generator == null) {
        final paramsOut = pkg_ffi.calloc<ffi.Pointer<OgaGeneratorParams>>();
        final ffi.Pointer<OgaGeneratorParams> params;
        try {
          check(
            oga.OgaCreateGeneratorParams(model!, paramsOut),
            'OgaCreateGeneratorParams',
          );
          params = paramsOut.value;
        } finally {
          pkg_ffi.calloc.free(paramsOut);
        }
        final maxLengthNameC = 'max_length'.toNativeUtf8();
        try {
          check(
            oga.OgaGeneratorParamsSetSearchNumber(
              params,
              maxLengthNameC.cast(),
              init.contextWindow.toDouble(),
            ),
            'OgaGeneratorParamsSetSearchNumber(max_length)',
          );
          final genOut = pkg_ffi.calloc<ffi.Pointer<OgaGenerator>>();
          try {
            check(
              oga.OgaCreateGenerator(model, params, genOut),
              'OgaCreateGenerator',
            );
            generator = genOut.value;
          } finally {
            pkg_ffi.calloc.free(genOut);
          }
        } finally {
          pkg_ffi.calloc.free(maxLengthNameC);
          oga.OgaDestroyGeneratorParams(params);
        }
      }

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
        check(
          oga.OgaTokenizerApplyChatTemplate(
            tokenizer!,
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
        check(oga.OgaCreateSequences(sequencesOut), 'OgaCreateSequences');
        sequences = sequencesOut.value;
      } finally {
        pkg_ffi.calloc.free(sequencesOut);
      }
      final promptC = templated.toNativeUtf8();
      final int promptTokens;
      try {
        check(
          oga.OgaTokenizerEncode(tokenizer, promptC.cast(), sequences),
          'OgaTokenizerEncode',
        );
        promptTokens = oga.OgaSequencesGetSequenceCount(sequences, 0);
        check(
          oga.OgaGenerator_AppendTokenSequences(generator!, sequences),
          'OgaGenerator_AppendTokenSequences (prefill)',
        );
      } finally {
        pkg_ffi.calloc.free(promptC);
        oga.OgaDestroySequences(sequences);
      }

      final streamOut = pkg_ffi.calloc<ffi.Pointer<OgaTokenizerStream>>();
      try {
        check(
          oga.OgaCreateTokenizerStream(tokenizer, streamOut),
          'OgaCreateTokenizerStream',
        );
        tokenizerStream = streamOut.value;
      } finally {
        pkg_ffi.calloc.free(streamOut);
      }

      var generatedCount = 0;
      final cap = turn.maxOutputTokens;

      void decodeAndEmit() {
        final outPtr = pkg_ffi.calloc<ffi.Pointer<ffi.Int32>>();
        final outCount = pkg_ffi.calloc<ffi.Size>();
        final int token;
        try {
          check(
            oga.OgaGenerator_GetNextTokens(generator!, outPtr, outCount),
            'OgaGenerator_GetNextTokens',
          );
          token = outPtr.value[outCount.value - 1];
        } finally {
          pkg_ffi.calloc.free(outPtr);
          pkg_ffi.calloc.free(outCount);
        }
        final decodedOut = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>();
        try {
          check(
            oga.OgaTokenizerStreamDecode(tokenizerStream!, token, decodedOut),
            'OgaTokenizerStreamDecode',
          );
          // `out` from OgaTokenizerStreamDecode is owned by the stream — do
          // NOT OgaDestroyString it (unlike OgaTokenizerDecode's out_string).
          final piece = decodedOut.value == ffi.nullptr
              ? ''
              : decodedOut.value.cast<pkg_ffi.Utf8>().toDartString();
          if (piece.isNotEmpty) init.replyTo.send(Chunk(id, piece));
        } finally {
          pkg_ffi.calloc.free(decodedOut);
        }
        generatedCount++;
      }

      // Prefill above is one long synchronous FFI call with no `await` in
      // it — a `StopSignal` sent while it was running sits unprocessed in
      // the isolate's mailbox the whole time (the outer command loop can't
      // dispatch it until this function yields), so it would otherwise
      // ALWAYS survive to force one unconditional token out of the
      // just-primed generator. Yield once here, mirroring the decode loop's
      // own per-token yield below, so that already-queued stop lands before
      // (not after) the first token is spent.
      await Future<void>(() {});
      if (!stopRequested) {
        check(
          oga.OgaGenerator_GenerateNextToken(generator!),
          'OgaGenerator_GenerateNextToken (first token)',
        );
        decodeAndEmit();
      }

      // Timed separately from prefill+first-token, matching the spike: the
      // first token's forward pass rides along with AppendTokenSequences.
      final swDecode = Stopwatch()..start();
      while (!oga.OgaGenerator_IsDone(generator!) &&
          (cap == null || generatedCount < cap)) {
        // Yield one event-loop turn per token so a queued StopSignal can
        // flip `stopRequested` before the next token is generated.
        await Future<void>(() {});
        if (stopRequested) break;
        check(
          oga.OgaGenerator_GenerateNextToken(generator!),
          'OgaGenerator_GenerateNextToken (decode)',
        );
        decodeAndEmit();
      }
      swDecode.stop();

      init.replyTo.send(
        GenerateDone(
          id,
          stopRequested,
          promptTokens,
          generatedCount,
          swDecode.elapsedMilliseconds,
        ),
      );
    } catch (e, st) {
      gemmaLog('[GenAiFfiClient/worker] generate failed: $e\n$st');
      init.replyTo.send(GenerateError(id, e.toString()));
    } finally {
      if (tokenizerStream != null) {
        oga.OgaDestroyTokenizerStream(tokenizerStream);
      }
      stopRequested = false;
    }
  }

  try {
    await for (final msg in commandPort) {
      if (msg is GenerateRequest) {
        final future = runGenerate(msg.id, msg.turn);
        activeGeneration = future;
        unawaited(
          future.whenComplete(() {
            if (identical(activeGeneration, future)) activeGeneration = null;
          }),
        );
      } else if (msg is CountTokensRequest) {
        try {
          final sequencesOut = pkg_ffi.calloc<ffi.Pointer<OgaSequences>>();
          final ffi.Pointer<OgaSequences> sequences;
          try {
            check(oga.OgaCreateSequences(sequencesOut), 'OgaCreateSequences');
            sequences = sequencesOut.value;
          } finally {
            pkg_ffi.calloc.free(sequencesOut);
          }
          final textC = msg.text.toNativeUtf8();
          try {
            check(
              oga.OgaTokenizerEncode(tokenizer, textC.cast(), sequences),
              'OgaTokenizerEncode',
            );
            final count = oga.OgaSequencesGetSequenceCount(sequences, 0);
            init.replyTo.send(CountTokensReply(msg.id, count, null));
          } finally {
            pkg_ffi.calloc.free(textC);
            oga.OgaDestroySequences(sequences);
          }
        } catch (e) {
          init.replyTo.send(CountTokensReply(msg.id, null, e.toString()));
        }
      } else if (msg is StopSignal) {
        stopRequested = true;
      } else if (msg is ResetSessionRequest) {
        // Unwind any in-flight decode loop (bounded — one more token at
        // most) and wait for its `finally` to finish BEFORE freeing the
        // generator it's still holding a reference to. See [activeGeneration]'s
        // doc.
        stopRequested = true;
        if (activeGeneration case final active?) await active;
        if (generator != null) {
          oga.OgaDestroyGenerator(generator!);
          generator = null;
        }
        init.replyTo.send(const ResetSessionAck());
      } else if (msg is Close) {
        // Same race as `ResetSessionRequest` above, but for the full
        // tokenizer/model teardown in this function's own `finally` below —
        // without this await, a generation suspended on its per-token yield
        // would resume and touch `generator`/`tokenizer` handles freed by
        // that `finally` right after `break`.
        stopRequested = true;
        if (activeGeneration case final active?) await active;
        commandPort.close();
        break;
      }
    }
  } finally {
    if (generator != null) oga.OgaDestroyGenerator(generator!);
    oga.OgaDestroyTokenizer(tokenizer);
    oga.OgaDestroyModel(model);
    init.replyTo.send(const CloseAck());
  }
}
