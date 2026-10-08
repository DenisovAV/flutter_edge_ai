import 'dart:async';

import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mutex/mutex.dart';

import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_edge_ai/core/parsing/sdk_text_extractor.dart';

import '../npu_stacks.dart';
import 'litert_default_scope.dart';
import 'litert_lm_bindings.dart';
import '../thinking_context.dart';

/// The per-turn `extra_context` JSON that sets thinking for this turn; see
/// [thinkingContext].
String thinkingExtraContext(bool enableThinking) =>
    jsonEncode(thinkingContext(enableThinking));

/// Callback typedef with Uint8 for bool (C _Bool = 1 byte)
typedef _StreamCallbackNative =
    Void Function(
      Pointer<Void> callbackData,
      Pointer<Char> chunk,
      Uint8 isFinal,
      Pointer<Char> errorMsg,
    );

/// stream_proxy_create: creates a proxy that strdup's strings before
/// forwarding to the Dart callback (prevents use-after-free).
typedef _ProxyCreateNative =
    Pointer<Void> Function(
      Pointer<NativeFunction<_StreamCallbackNative>> dartCallback,
      Pointer<Void> dartData,
      Pointer<Pointer<NativeFunction<_StreamCallbackNative>>> outProxyFn,
    );
typedef _ProxyCreateDart =
    Pointer<Void> Function(
      Pointer<NativeFunction<_StreamCallbackNative>> dartCallback,
      Pointer<Void> dartData,
      Pointer<Pointer<NativeFunction<_StreamCallbackNative>>> outProxyFn,
    );

/// Free a strdup'd string from the proxy callback.
typedef _ProxyFreeStringNative = Void Function(Pointer<Char> str);
typedef _ProxyFreeStringDart = void Function(Pointer<Char> str);

/// Decode a NUL-terminated native string without throwing on malformed bytes.
///
/// `Utf8Pointer.toDartString` throws [FormatException] the moment the buffer
/// isn't valid UTF-8, which is the worst possible behaviour on the error path:
/// a native failure then surfaces as a complaint about character encoding, and
/// the actual message — the only thing that would explain the failure — is
/// lost. That misdirection cost real debugging time when LiteRT-LM v0.15.0
/// changed the stream-callback ABI and this path started receiving register
/// garbage. Decoding leniently keeps whatever the native layer did send
/// readable, with U+FFFD standing in for the unreadable bytes.
String _decodeNativeString(Pointer<Char> ptr, {int maxBytes = 64 * 1024}) {
  final bytes = ptr.cast<Uint8>();
  var length = 0;
  while (length < maxBytes && bytes[length] != 0) {
    length++;
  }
  return utf8.decode(bytes.asTypedList(length), allowMalformed: true);
}

/// Per-conversation operations a session needs from the FFI layer.
///
/// [LiteRtLmConversationHandle] is the real implementation backed by a
/// native `LiteRtLmConversation*`. Tests inject a fake implementing this
/// interface so [FfiInferenceModelSession] orchestration (query buffering,
/// raw-response capture, Gemma 4 tool-call extraction) can be exercised on
/// the host VM with no native engine.
abstract class ConversationHandle {
  /// Token count for [text] from the model's own tokenizer, or null when it
  /// cannot be obtained (no engine, native call failed). Callers must handle
  /// null rather than assume a number — this feeds context budgeting, and the
  /// four-chars-per-token estimate it replaced undercounts Chinese by more than
  /// half (measured 0.44x on gemma-4-E2B-it) while looking authoritative.
  Future<int?> tokenCount(String text);

  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking,
  });

  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking,
  });

  /// Streams raw SDK JSON for a prebuilt message. This is how tool results go
  /// back: [chatRaw] always sends role `user`, and a tool result has to be role
  /// `tool` for the model to read it as the answer to its call.
  Stream<String> chatRawMessage(String messageJson, {bool enableThinking});

  void cancelGeneration();

  SessionMetrics getSessionMetrics();

  void close();
}

/// One conversation owned by a [LiteRtLmFfiClient]. Each call to
/// [LiteRtLmFfiClient.createConversationHandle] returns a fresh handle:
/// the engine pointer is shared across handles, the conversation pointer
/// is private to this handle. The handle owns that pointer's lifetime and
/// routes every per-conversation native call through the client's private
/// `_…On(conv, …)` methods.
///
/// What the handle does NOT give you is simultaneity. The engine allows
/// only ONE live conversation at a time today (upstream LiteRT-LM #966),
/// so any prior conversation must be deleted before
/// [LiteRtLmFfiClient.createConversationHandle] is called again.
/// Concurrent sessions come from the virtual-session multiplexer, which
/// tears the native conversation down and rebuilds it seeded with the
/// active session's history — not from several `LiteRtLmConversation*`
/// coexisting on one engine.
///
/// Lifetime contract: the caller must call [close] when done. The owning
/// client closes any remaining handles on [LiteRtLmFfiClient.shutdown].
class LiteRtLmConversationHandle implements ConversationHandle {
  LiteRtLmConversationHandle._(this._client, this._conversation);

  final LiteRtLmFfiClient _client;
  Pointer<LiteRtLmConversation>? _conversation;

  bool get isClosed => _conversation == null;

  /// Token count from the model's own tokenizer, or null when unavailable.
  /// Engine-level, so it works on a closed conversation too.
  @override
  Future<int?> tokenCount(String text) => _client.tokenCount(text);

  void _assertOpen() {
    if (_conversation == null) {
      throw StateError('Conversation handle is closed');
    }
  }

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _assertOpen();
    return _client._chatOn(
      _conversation!,
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    );
  }

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _assertOpen();
    return _client._chatRawOn(
      _conversation!,
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    );
  }

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
  }) {
    _assertOpen();
    return _client._sendMessageStreamRawOn(
      _conversation!,
      messageJson,
      extraContext: thinkingExtraContext(enableThinking),
    );
  }

  Future<String> sendMessage(String messageJson, {String? extraContext}) {
    _assertOpen();
    return _client._sendMessageOn(
      _conversation!,
      messageJson,
      extraContext: extraContext,
    );
  }

  Stream<String> sendMessageStreamRaw(
    String messageJson, {
    String? extraContext,
  }) {
    _assertOpen();
    return _client._sendMessageStreamRawOn(
      _conversation!,
      messageJson,
      extraContext: extraContext,
    );
  }

  @override
  void cancelGeneration() {
    if (_conversation == null) return;
    _client._cancelOn(_conversation!);
  }

  @override
  SessionMetrics getSessionMetrics() {
    if (_conversation == null) return SessionMetrics();
    return _client._getMetricsOn(_conversation!);
  }

  @override
  void close() {
    if (_conversation == null) return;
    // Cancel any in-flight native decode before deleting: conversation_delete
    // blocks in ~SessionBasic → ThreadPool::WaitUntilDone until the generation
    // drains naturally, which under GPU throttle is tens of seconds and ANRs
    // the platform thread (#364). Cancelling first collapses the drain to
    // milliseconds. `_cancelOn` is lock-free so it can interrupt a generation
    // that holds `_nativeMutex`. The virtual-session path already does this in
    // `releaseVirtualConversation`; this brings the single-session path in line.
    _client._cancelOn(_conversation!);
    _client._deleteConversation(_conversation!);
    _conversation = null;
    _client._handles.remove(this);
  }
}

/// Opens the LiteRT-LM shared library for the current platform.
///
/// Top-level so it can be called from a spawned isolate, which cannot capture
/// `this` or any other non-const closure state.
///
/// Deliberately a plain open, and safe only because of an ordering invariant:
/// both callers run inside `initialize()`, which calls `_ensureBindings()` —
/// and therefore `openLiteRtLmRequiringDefaultScope` — first. On Android a
/// plain open cannot DEMOTE an already-global soinfo, so arriving second is
/// harmless. If a future caller can reach this before `_ensureBindings`, it
/// must go through litert_default_scope.dart instead or it reintroduces #447.
DynamicLibrary _openLiteRtLmLibrary() {
  if (Platform.isIOS) {
    return DynamicLibrary.open(
      '@executable_path/Frameworks/LiteRtLm.framework/LiteRtLm',
    );
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('LiteRtLm.framework/LiteRtLm');
  }
  if (Platform.isAndroid) {
    // Through the helper rather than relying on the ordering invariant above.
    // Best-effort variant: an isolate must not throw here, and by the time
    // this runs the LLM path has already required the strict one.
    return openLiteRtLmPreferringDefaultScope('libLiteRtLm.so');
  }
  if (Platform.isLinux) {
    return DynamicLibrary.open('libLiteRtLm.so');
  }
  return DynamicLibrary.open('LiteRtLm.dll');
}

/// Calls native `litert_lm_conversation_create` on a spawned isolate.
///
/// For multimodal models this compiles the vision encoder's OpenCL kernels
/// (`clBuildProgram`), which costs ~8s on a mid-range mobile GPU. Recent
/// Flutter runs the Dart UI thread on Android's platform thread, so calling
/// this inline blocks input dispatch and the OS raises an
/// "Input dispatching timed out" ANR.
///
/// Native pointers are process-wide, so the conversation can be built on any
/// isolate and used from this one. This mirrors what `litert_lm_engine_create`
/// already does.
Future<int> _createConversationOffMainIsolate({
  required int engineAddr,
  required int configAddr,
}) {
  final isolateLogLevel = edgeAiLogLevel;
  return Isolate.run(() {
    edgeAiLogLevel = isolateLogLevel;
    final create = _openLiteRtLmLibrary()
        .lookupFunction<
          Pointer Function(Pointer, Pointer),
          Pointer Function(Pointer, Pointer)
        >('litert_lm_conversation_create');
    return create(
      Pointer.fromAddress(engineAddr),
      Pointer.fromAddress(configAddr),
    ).address;
  });
}

/// High-level Dart wrapper around the LiteRT-LM C API.
///
/// Provides a clean async interface over the native C functions,
/// managing memory and translating C callbacks into Dart Streams.
///
/// Conversation lifetime is owned by [LiteRtLmConversationHandle] —
/// the client holds the engine and tracks live handles for shutdown.
/// Legacy single-session methods ([createConversation], [chat],
/// [sendMessageStreamRaw], etc.) route through an internal
/// [_legacyHandle] for backward compatibility.
class LiteRtLmFfiClient {
  LiteRtLmBindings? _bindings;
  // Holding a reference prevents the proxy DynamicLibrary from being GC'd
  // while function pointers obtained via lookupFunction are still in use.
  // ignore: unused_field
  DynamicLibrary? _proxyLib;
  _ProxyCreateDart? _proxyCreate;
  _ProxyFreeStringDart? _proxyFreeString;
  Pointer<LiteRtLmEngine>? _engine;
  bool _isInitialized = false;
  String? _nativeLogPath;

  /// Backend the engine was initialised with, as the wire string ('cpu' /
  /// 'gpu' / 'npu'). Read only to warn that the NPU executor discards sampler
  /// params — it must never gate what we send again.
  String? _backend;

  /// Conversation creates currently suspended across an `await`.
  ///
  /// `litert_lm_conversation_create` runs on a spawned isolate, so the calling
  /// isolate's event loop is free for the duration — long enough for [shutdown]
  /// to run `litert_lm_engine_delete` while native code is still dereferencing
  /// the engine pointer. [shutdown] waits for this to reach zero, and creates
  /// re-check [_isShuttingDown] before publishing anything.
  int _createsInFlight = 0;
  Completer<void>? _createsQuiescent;
  bool _isShuttingDown = false;

  void _enterCreate() => _createsInFlight++;

  void _exitCreate() {
    if (--_createsInFlight == 0) {
      _createsQuiescent?.complete();
      _createsQuiescent = null;
    }
  }

  /// Runs [body] while [shutdown] is held off. Everything the create publishes
  /// (the conversation pointer, its handle) must happen inside [body];
  /// [shutdown] may proceed the moment it returns.
  Future<T> _guardCreate<T>(Future<T> Function() body) async {
    if (_isShuttingDown) {
      throw StateError('Client is shutting down; cannot create a conversation');
    }
    _enterCreate();
    try {
      return await body();
    } finally {
      _exitCreate();
    }
  }

  /// All live conversation handles created on this client. Closed in bulk
  /// by [shutdown]. Each handle removes itself on its own [close].
  final Set<LiteRtLmConversationHandle> _handles = {};

  /// Every conversation pointer currently alive (minted by
  /// [_createRawConversation], removed by [_deleteConversation]). [_cancelOn]
  /// consults this before dereferencing a pointer: a raw-stream or virtual-turn
  /// onCancel can fire after model/handle/engine teardown already freed the
  /// conversation, and cancelling a dangling pointer is a use-after-free SIGSEGV
  /// in native `Conversation::CancelProcess` (#379). A freed conversation is not
  /// in this set, so the late cancel no-ops.
  ///
  /// ABA note — this is keyed on the raw pointer *address*, so it DOWNGRADES,
  /// not eliminates, the hazard: if the allocator re-mints a conversation at a
  /// just-freed address, a stale `_cancelOn` for the old one would cancel the
  /// NEW one (a wrong-target cancel, not a UAF). That window stays closed today
  /// only because every create and every raw-stream cancel is serialized under
  /// [_nativeMutex], and internal consumers use `await for` (no deferred
  /// `subscription.cancel()`). Keep that discipline. A generation-keyed map
  /// (`Map<Pointer,int>`, id captured per onCancel) would make it structural.
  final Set<Pointer<LiteRtLmConversation>> _liveConvs = {};

  /// Test seam (read-only): is this conversation currently tracked as live?
  @visibleForTesting
  bool isConversationLiveForTest(Pointer<LiteRtLmConversation> conv) =>
      _liveConvs.contains(conv);

  /// Test seam: seed a live conversation without a native engine — mirrors the
  /// registration [_createRawConversation] performs.
  @visibleForTesting
  void registerLiveForTest(Pointer<LiteRtLmConversation> conv) =>
      _liveConvs.add(conv);

  /// Test seam: drive the real [_deleteConversation] without a native binding.
  @visibleForTesting
  void deleteConversationForTest(Pointer<LiteRtLmConversation> conv) =>
      _deleteConversation(conv);

  /// Backing handle for the legacy single-conversation API
  /// ([createConversation] / [closeConversation] / [chat] / etc.). Kept so
  /// existing single-session call sites work unchanged while the new
  /// handle-based multi-session path is wired up.
  LiteRtLmConversationHandle? _legacyHandle;

  /// Serializes native send_message / send_message_stream calls across
  /// conversations. The LiteRT-LM C API is not documented as reentrant on
  /// one engine — two conversations generating at once could race inside
  /// liblitert_lm. The mutex makes concurrent sessions safe (each waits
  /// its turn); it is uncontended when only one session is active, so the
  /// single-session fast path pays only an acquire/release on an empty
  /// lock. Cancel does NOT take the lock — it must interrupt an in-flight
  /// streaming call.
  final Mutex _nativeMutex = Mutex();

  /// Reads back the native log file (set by stream_proxy_redirect_stderr) and
  /// pipes its contents through debugPrint in 800-char chunks. Surfaces
  /// absl/glog output (model load timing, accelerator init, sampler dlopen,
  /// KV-cache prefill, etc.) that's redirected to a file by
  /// [stream_proxy_redirect_stderr] and wouldn't otherwise reach the Flutter
  /// console / test harness.
  ///
  /// Called automatically after every successful and failed engine_create
  /// (debug builds only) so timing breakdowns are visible in `flutter run`.
  /// Also exposed publicly via [dumpNativeLog] for callers that want to dump
  /// at arbitrary points (e.g. after prefill, after a slow generate).
  ///
  /// Truncates the log file after reading so subsequent dumps only show new
  /// output — otherwise every dump would re-print everything since app start.
  void dumpNativeLog() => _dumpNativeLog();

  void _dumpNativeLog() {
    final p = _nativeLogPath;
    if (p == null) return;
    try {
      final f = File(p);
      if (!f.existsSync()) {
        edgeAiLog('[LiteRtLmFfi/native] log file missing: $p');
        return;
      }
      final content = f.readAsStringSync();
      if (content.isEmpty) {
        edgeAiLog('[LiteRtLmFfi/native] (no new native log output)');
        return;
      }
      edgeAiLog(
        '[LiteRtLmFfi/native] === BEGIN native log ($p, ${content.length} bytes) ===',
      );
      const chunkSize = 800;
      for (var i = 0; i < content.length; i += chunkSize) {
        final end = (i + chunkSize < content.length)
            ? i + chunkSize
            : content.length;
        edgeAiLog(content.substring(i, end), level: EdgeAiLogLevel.verbose);
      }
      edgeAiLog('[LiteRtLmFfi/native] === END native log ===');
      // Truncate so the next dump only shows new output. If truncation fails
      // (read-only fs etc.), next dump just re-prints — non-fatal.
      try {
        f.writeAsStringSync('');
      } catch (_) {}
    } catch (e) {
      edgeAiLog('[LiteRtLmFfi/native] failed to read $p: $e');
    }
  }

  /// Extracts the first `section_backend_constraint` value from the native SDK
  /// log without truncating it (unlike [_dumpNativeLog]) — the value is the
  /// lowercase wire backend name (`gpu`/`cpu`/`npu`). Lets an opaque
  /// engine_create failure become an actionable "this model needs a specific
  /// backend" error — e.g. Gemma 4 12B is GPU-only. Returns null when the log
  /// is unavailable (release / Android / Windows, where stderr isn't wired) or
  /// the model declares no constraint.
  String? _backendConstraintFromNativeLog() {
    final p = _nativeLogPath;
    if (p == null) return null;
    try {
      final f = File(p);
      if (!f.existsSync()) return null;
      final match = RegExp(
        r'section_backend_constraint:\s*(\w+)',
      ).firstMatch(f.readAsStringSync());
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  bool get isInitialized => _isInitialized;

  /// Path to the redirected native stderr log (LiteRT-LM absl/glog output).
  /// Set after [_ensureBindings] runs the stderr redirect; null on platforms
  /// where redirection isn't wired (currently it works on macOS + iOS).
  String? get nativeLogPath => _nativeLogPath;

  /// Load the native library and create bindings.
  void _ensureBindings() {
    if (_bindings != null) return;

    final loadSw = Stopwatch()..start();
    edgeAiLog('[LiteRtLmFfi] Loading native libraries...');
    final DynamicLibrary lib;
    final DynamicLibrary proxyLib;
    if (Platform.isIOS) {
      // On iOS, Native Assets bundles dylibs in Frameworks/ inside Runner.app.
      // The host app's Xcode project must also copy raw lib*.dylib files
      // alongside the .framework bundles (see "Setup LiteRT-LM iOS" build
      // phase in example/ios/Runner.xcodeproj/project.pbxproj) — needed
      // because gpu_registry.cc uses relative-basename dlopen which iOS
      // dyld 4 cannot resolve from .framework names alone.
      lib = DynamicLibrary.open(
        '@executable_path/Frameworks/LiteRtLm.framework/LiteRtLm',
      );
      proxyLib = DynamicLibrary.open(
        '@executable_path/Frameworks/StreamProxy.framework/StreamProxy',
      );
    } else if (Platform.isMacOS) {
      lib = DynamicLibrary.open('LiteRtLm.framework/LiteRtLm');
      proxyLib = DynamicLibrary.open('StreamProxy.framework/StreamProxy');
    } else if (Platform.isLinux) {
      // Load order matters: libLiteRt.so must be loaded first with
      // RTLD_GLOBAL so libLiteRtLm.so (built with
      // litert_runtime_link_mode=dynamic) and the WebGPU accelerator can
      // resolve LiteRt* C API symbols
      // against it. StreamProxy exposes a dlopen helper because Dart's
      // DynamicLibrary.open uses RTLD_LOCAL which hides symbols.
      //
      // Native Assets places .so files in <bundle>/lib/. Dart's
      // DynamicLibrary.open finds them by basename via Flutter-set RPATH,
      // but a raw C dlopen via stream_proxy_load_global doesn't see that
      // path — pass an absolute path so it resolves regardless of
      // LD_LIBRARY_PATH / RPATH inheritance.
      final libDir = '${File(Platform.resolvedExecutable).parent.path}/lib';
      proxyLib = DynamicLibrary.open('libStreamProxy.so');
      final loadGlobal = proxyLib
          .lookupFunction<
            Pointer Function(Pointer<Utf8>),
            Pointer Function(Pointer<Utf8>)
          >('stream_proxy_load_global');
      // Preload sequence:
      // - libLiteRt.so first (provides LiteRt C API used by the WebGPU
      //   accelerator at registration)
      // - libGemmaModelConstraintProvider.so (libLiteRtLm.so has a
      //   SONAME-level dependency on it)
      // - libLiteRtWebGpuAccelerator.so so gpu_registry.cc:162 can find it
      //   via the loader's already-loaded modules table when it does
      //   basename-only dlopen
      // - libLiteRtLm.so itself
      //
      // libLiteRtTopKWebGpuSampler.so is intentionally NOT preloaded:
      // its Create() holds a process-static wgpu::Instance and rejects
      // any second engine_create with `wgpu::Instance already set`,
      // making model swap and multi-session tests impossible. With the
      // sampler not preloaded, sampler_factory.cc:443's dlopen returns
      // Unavailable and the factory falls back to the static / CPU
      // sampler chain — inference itself still runs on the GPU
      // accelerator, only the per-token argmax happens on CPU
      // (negligible perf hit, ~1-5ms/token).
      for (final name in const [
        'libLiteRt.so',
        'libGemmaModelConstraintProvider.so',
        'libLiteRtWebGpuAccelerator.so',
        'libLiteRtLm.so',
      ]) {
        final fullPath = '$libDir/$name';
        final pathPtr = fullPath.toNativeUtf8();
        final handle = loadGlobal(pathPtr);
        calloc.free(pathPtr);
        if (handle == nullptr) {
          throw Exception('Failed to load $fullPath with RTLD_GLOBAL');
        }
      }
      lib = DynamicLibrary.open('libLiteRtLm.so');
    } else if (Platform.isWindows) {
      // Preload LiteRt.dll first so the WebGPU accelerator and TopK sampler
      // can resolve LiteRt* C API + their own exports through the process
      // module list before sampler_factory does its LoadLibrary lookup
      // (mirrors the Linux/Android RTLD_GLOBAL pattern).
      proxyLib = DynamicLibrary.open('StreamProxy.dll');
      final loadGlobal = proxyLib
          .lookupFunction<
            Pointer Function(Pointer<Utf8>),
            Pointer Function(Pointer<Utf8>)
          >('stream_proxy_load_global');
      for (final name in const [
        'LiteRt.dll',
        'libLiteRtTopKWebGpuSampler.dll',
        'libLiteRtWebGpuAccelerator.dll',
        'LiteRtLm.dll',
      ]) {
        final pathPtr = name.toNativeUtf8();
        final handle = loadGlobal(pathPtr);
        calloc.free(pathPtr);
        if (handle == nullptr) {
          throw Exception('Failed to preload $name (LoadLibraryEx)');
        }
      }
      lib = DynamicLibrary.open('LiteRtLm.dll');
    } else if (Platform.isAndroid) {
      // LiteRT-LM ships native libs only for android_arm64 — bail with a
      // typed message before dlopen surfaces a generic ENOENT on x86_64
      // emulators / armeabi-v7a devices (#250). MediaPipe `.task` text
      // inference still works on those ABIs through the Kotlin path; only
      // `.litertlm` (FFI) requires arm64.
      if (Abi.current() != Abi.androidArm64) {
        throw UnsupportedError(
          'flutter_edge_ai .litertlm models require an arm64-v8a Android device '
          '(got ${Abi.current()}). Use a `.task` MediaPipe model on this ABI '
          'or run on an arm64-v8a device / Apple Silicon emulator.',
        );
      }
      proxyLib = DynamicLibrary.open('libStreamProxy.so');
      // Load LiteRtLm into the default search scope so stream_proxy's ABI
      // probe can resolve the v0.15 chunk accessors through
      // dlsym(RTLD_DEFAULT); Dart's DynamicLibrary.open uses RTLD_LOCAL, which
      // hides them. That probe is the ONLY verified consumer of ambient
      // visibility here: measured on the shipped android_arm64 bundle, the GPU
      // and OpenCL accelerators have zero undefined LiteRt* symbols, and the
      // TopK samplers resolve theirs through DT_NEEDED, not RTLD_DEFAULT.
      //
      // Shared with the embeddings/speech entry point (litert_bindings.dart)
      // because the two race for "first to open", and the loser used to decide
      // the outcome silently. The helper also verifies the load rather than
      // trusting a non-NULL handle — see its header and #447.
      lib = openLiteRtLmRequiringDefaultScope('libLiteRtLm.so');
    } else {
      throw UnsupportedError(
        'Platform not supported for FFI: ${Platform.operatingSystem}',
      );
    }

    _bindings = LiteRtLmBindings(lib);
    _proxyLib = proxyLib;
    _proxyCreate = proxyLib
        .lookupFunction<_ProxyCreateNative, _ProxyCreateDart>(
          'stream_proxy_create',
        );
    _proxyFreeString = proxyLib
        .lookupFunction<_ProxyFreeStringNative, _ProxyFreeStringDart>(
          'stream_proxy_free_string',
        );

    // DEBUG-only: redirect native stderr to a file so we can dump absl/glog
    // output through debugPrint after engine_create failure. Skipped in
    // release builds — production users see crashes via os_log/Crashlytics
    // streams (or systemd journal on Linux); redirecting stderr would
    // silently swallow those.
    //
    // Linux: flutter test does not surface child-process stderr, so without
    // this Linux integration tests get the same opaque 'Failed to create
    // engine' as iOS without any native diagnostics.
    if (kDebugMode &&
        (Platform.isIOS || Platform.isLinux || Platform.isMacOS)) {
      _nativeLogPath = '${Directory.systemTemp.path}/litertlm_native.log';
      final redirect = proxyLib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('stream_proxy_redirect_stderr');
      final pathPtr = _nativeLogPath!.toNativeUtf8();
      final rc = redirect(pathPtr);
      calloc.free(pathPtr);
      if (rc != 0) {
        // Log capture is best-effort but its failure makes _dumpNativeLog
        // useless. Surface it instead of silently continuing.
        edgeAiLog(
          '[LiteRtLmFfi] WARNING: stderr redirect failed (rc=$rc) — '
          'native log dumps will be empty',
        );
        _nativeLogPath = null;
      } else {
        edgeAiLog('[LiteRtLmFfi] stderr redirected to $_nativeLogPath');
      }
    }

    edgeAiLog(
      '[LiteRtLmFfi/perf] _ensureBindings total: ${loadSw.elapsedMilliseconds}ms',
    );
    edgeAiLog('[LiteRtLmFfi] Libraries loaded');
  }

  /// Initialize the engine with model path and settings.
  ///
  /// [activationDataType] is the C API's number (see
  /// `activationDataTypeWireValue`); null leaves the engine's own choice.
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 2048,
    String? cacheDir,
    bool enableVision = false,
    String visionBackend = 'cpu',
    int maxNumImages = 0,
    bool enableAudio = false,
    String audioBackend = 'cpu',
    bool? enableSpeculativeDecoding,
    int? activationDataType,
  }) async {
    final initSw = Stopwatch()..start();
    _ensureBindings();
    _backend = backend;
    final bindingsMs = initSw.elapsedMilliseconds;
    edgeAiLog('[LiteRtLmFfi/perf] _ensureBindings: ${bindingsMs}ms');
    // Log the resolved per-encoder backends: vision/audio default to CPU
    // independent of the text backend, so this makes the GPU→CPU default (and
    // any override) visible when diagnosing "why isn't vision using my GPU".
    if (enableVision || enableAudio) {
      edgeAiLog(
        '[LiteRtLmFfi] encoders: '
        '${enableVision ? "vision=$visionBackend " : ""}'
        '${enableAudio ? "audio=$audioBackend " : ""}'
        '(text=$backend)',
      );
    }
    final b = _bindings!;

    // Create engine settings
    final modelPathPtr = modelPath.toNativeUtf8();
    final backendPtr = backend.toNativeUtf8();
    // Vision + audio encoders default to CPU (visionBackend/audioBackend), NOT
    // the text backend. The VISION encoder's STABLEHLO_COMPOSITE ops fail to
    // prepare on the Metal/WebGPU delegates (hard-fails at conversation_create,
    // no fallback — LiteRT-LM#2461), so CPU is mandatory-safe there. AUDIO runs
    // on either backend; CPU is a conservative default (GPU is often faster —
    // Gemma 3n audio ~2x). Both stay overridable via the arg.
    final visionBackendPtr = enableVision
        ? visionBackend.toNativeUtf8()
        : nullptr;
    final audioBackendPtr = enableAudio ? audioBackend.toNativeUtf8() : nullptr;

    try {
      // Asked before the settings exist: a missing NPU stack is an expected
      // fallback, and throwing after settings_create would leak the settings.
      final npuDispatchDir = Platform.isAndroid && backend == 'npu'
          ? await _prepareAndroidNpuDispatchDir()
          : null;

      final settingsCreateStart = initSw.elapsedMilliseconds;
      final settings = b.litert_lm_engine_settings_create(
        modelPathPtr.cast(),
        backendPtr.cast(),
        visionBackendPtr == nullptr ? nullptr : visionBackendPtr.cast(),
        audioBackendPtr == nullptr ? nullptr : audioBackendPtr.cast(),
      );
      edgeAiLog(
        '[LiteRtLmFfi/perf] settings_create: ${initSw.elapsedMilliseconds - settingsCreateStart}ms',
      );

      if (settings == nullptr) {
        throw Exception('Failed to create engine settings');
      }

      // Configure settings
      b.litert_lm_engine_settings_set_max_num_tokens(settings, maxTokens);

      // Enable benchmarking for session metrics (token counts, timing)
      b.litert_lm_engine_settings_enable_benchmark(settings);

      if (cacheDir != null) {
        final cacheDirPtr = cacheDir.toNativeUtf8();
        // Sets cache dir on main, vision, and audio executors (C API patched)
        b.litert_lm_engine_settings_set_cache_dir(settings, cacheDirPtr.cast());
        calloc.free(cacheDirPtr);
      }

      if (maxNumImages > 0) {
        b.litert_lm_engine_settings_set_max_num_images(settings, maxNumImages);
      }

      // MTP / speculative decoding (LiteRT-LM v0.11.0+). Skip when null so
      // the SDK uses the model's default; only call when caller explicitly
      // forces on/off.
      if (enableSpeculativeDecoding != null) {
        b.litert_lm_engine_settings_set_enable_speculative_decoding(
          settings,
          enableSpeculativeDecoding,
        );
      }

      // Activation type (0 F32, 1 F16, 2 I16, 3 I8). Skip when null: the engine
      // then takes the model file's `prefer_activation_type`, else F16 on GPU.
      // F16 on some GPUs copies digits wrongly from long prompts (Adreno
      // LiteRT-LM#3012, Metal #2814), and F32 fixes it at a slower prefill.
      // The setter is upstream C API, so every platform's libLiteRtLm has it
      // (and patch_c_api.sh's Windows .def exports it).
      if (activationDataType != null) {
        b.litert_lm_engine_settings_set_activation_data_type(
          settings,
          activationDataType,
        );
        edgeAiLog(
          '[LiteRtLmFfi] activation_data_type=$activationDataType '
          '(${_activationName(activationDataType)}, backend=$backend; only the '
          'GPU executor reads it)',
        );
      }

      // Windows NPU: point LiteRT at the directory containing
      // `LiteRtDispatch.dll` and disable HW mask update path. Native Assets
      // bundles both DLLs next to the executable, so resolvedExecutable.parent
      // is the right path. Without `dispatch_lib_dir` LiteRT reads
      // uninitialized env-option memory and engine_create crashes; without
      // `use_hw_masking_for_npu(false)` LiteRT sets up the kWH HW mask method
      // which Intel preview NPU (LunarLake/PantherLake) doesn't fully support
      // → CFG check failure 0xc0000409 (per Matt Kreileder's Intel NPU
      // pipeline instructions).
      if (Platform.isWindows && backend == 'npu') {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final dirPtr = exeDir.toNativeUtf8();
        b.litert_lm_engine_settings_set_litert_dispatch_lib_dir(
          settings,
          dirPtr.cast(),
        );
        calloc.free(dirPtr);
        b.litert_lm_engine_settings_set_use_hw_masking_for_npu(settings, false);
        edgeAiLog(
          '[LiteRtLmFfi] NPU Windows: dispatch_lib_dir=$exeDir, use_hw_masking_for_npu=false',
        );
      }

      if (npuDispatchDir != null) {
        final dirPtr = npuDispatchDir.toNativeUtf8();
        b.litert_lm_engine_settings_set_litert_dispatch_lib_dir(
          settings,
          dirPtr.cast(),
        );
        calloc.free(dirPtr);
        edgeAiLog(
          '[LiteRtLmFfi] NPU Android: dispatch_lib_dir=$npuDispatchDir',
        );
      }

      // #364: on Android, flush the OpenCL command queue every N ops during a
      // GPU prefill so it doesn't starve the Flutter raster/compositor thread.
      // By default LiteRT-LM's OpenCL backend dispatches the ENTIRE graph as one
      // uninterruptible batch (gpu_backend_opencl_litert.cc: "dispatch all
      // kernels in one batch" when kernel_batch_size<=0), so a ~2s prefill
      // freezes the compositor (repro'd on Adreno S23 Ultra: raster p95
      // 6.8ms->123ms). A positive hint_kernel_batch_size inserts a clFlush every
      // N ops, giving the display work interleave points. Upstream auto-applies
      // 4 for "generic" models to ensure smooth UI, but recognized Gemma types
      // aren't generic (engine_settings.cc gates the default on has_generic_model)
      // so gemma4/3/3n get NO flush unless we set it. Measured on dm3q: kb=4
      // (upstream value) still janks (p95 63ms), kb=2 is flat (p95 7.3ms ~=
      // baseline) with no TTFT cost, so 2 — not 4. NOT gpu_context_low_priority:
      // it only reorders cross-context submission (no Adreno preemption of a
      // running dispatch) and measured strictly worse (jank + TTFT both up).
      // Gated to Android: Metal (iOS/macOS) doesn't starve the compositor, and
      // the setter symbol only ships in the Android native rebuild.
      if (Platform.isAndroid && backend == 'gpu') {
        b.litert_lm_engine_settings_set_kernel_batch_size(settings, 2);
        edgeAiLog(
          '[LiteRtLmFfi] Android GPU: hint_kernel_batch_size=2 (#364 smooth UI)',
        );
      }

      // Create engine in a background isolate to avoid blocking UI.
      // Pass settings pointer as int address (Pointer can't cross isolates).
      edgeAiLog(
        '[LiteRtLmFfi] Creating engine from $modelPath (backend=$backend, maxTokens=$maxTokens) ...',
      );
      edgeAiLog(
        '[LiteRtLmFfi/perf] === START litert_lm_engine_create (native — model load + accelerator init + KV cache prefill) ===',
      );
      final settingsAddr = settings.address;
      final sw = Stopwatch()..start();
      // Snapshot the log level so the spawned isolate (a fresh copy of the
      // per-isolate top-level `edgeAiLogLevel`, default info) honours the
      // caller's setting instead of leaking perf logs at the default level.
      final isolateLogLevel = edgeAiLogLevel;
      final engineAddr = await Isolate.run(() {
        edgeAiLogLevel = isolateLogLevel;
        final isolateSw = Stopwatch()..start();
        final lib = _openLiteRtLmLibrary();
        edgeAiLog(
          '[LiteRtLmFfi/perf]   isolate: DynamicLibrary.open: ${isolateSw.elapsedMilliseconds}ms',
          level: EdgeAiLogLevel.verbose,
        );
        final lookupStart = isolateSw.elapsedMilliseconds;
        final create = lib
            .lookupFunction<
              Pointer Function(Pointer),
              Pointer Function(Pointer)
            >('litert_lm_engine_create');
        edgeAiLog(
          '[LiteRtLmFfi/perf]   isolate: lookupFunction: ${isolateSw.elapsedMilliseconds - lookupStart}ms',
          level: EdgeAiLogLevel.verbose,
        );
        final createStart = isolateSw.elapsedMilliseconds;
        final ptr = create(Pointer.fromAddress(settingsAddr)).address;
        edgeAiLog(
          '[LiteRtLmFfi/perf]   isolate: native litert_lm_engine_create: ${isolateSw.elapsedMilliseconds - createStart}ms',
          level: EdgeAiLogLevel.verbose,
        );
        return ptr;
      });
      _engine = Pointer<LiteRtLmEngine>.fromAddress(engineAddr);
      sw.stop();
      edgeAiLog(
        '[LiteRtLmFfi/perf] === END litert_lm_engine_create: ${sw.elapsedMilliseconds}ms (includes isolate spawn ~50-200ms) ===',
      );
      edgeAiLog(
        '[LiteRtLmFfi] litert_lm_engine_create took ${sw.elapsedMilliseconds}ms',
      );
      b.litert_lm_engine_settings_delete(settings);

      if (_engine == null || _engine == nullptr) {
        // Read the model's backend constraint BEFORE _dumpNativeLog() truncates
        // the log. A GPU-only model (e.g. Gemma 4 12B, whose decoder section
        // declares `section_backend_constraint: gpu`) fails engine_create on the
        // CPU backend with an otherwise opaque null — turn that into an
        // actionable error instead of the misleading "model may be invalid".
        final constraint = _backendConstraintFromNativeLog();
        _dumpNativeLog();
        if (constraint != null && constraint != backend) {
          throw Exception(
            'This .litertlm model requires the "$constraint" backend — it '
            'declares section_backend_constraint: $constraint, but the '
            '"$backend" backend was requested. Use PreferredBackend.$constraint '
            '(or omit preferredBackend to try GPU first).',
          );
        }
        // Only the GPU executor reads the activation type, so only a float32
        // GPU attempt can have failed because of it.
        final float32OnGpu = activationDataType == 0 && backend == 'gpu';
        throw Exception(
          'Failed to create engine. Model may be invalid: $modelPath'
          '${float32OnGpu ? ' (float32 activations need more GPU memory than '
                    'the default — try without activationDataType)' : ''}',
        );
      }

      _isInitialized = true;
      edgeAiLog(
        '[LiteRtLmFfi/perf] initialize() total: ${initSw.elapsedMilliseconds}ms',
      );
      edgeAiLog('[LiteRtLmFfi] Engine initialized successfully');

      // Auto-dump the SDK's stderr log after successful engine_create so
      // users can see what happens inside the native call (model load time,
      // accelerator init, sampler dlopen attempts, KV cache prefill, etc.).
      // No-op when stderr redirection isn't wired (release / Android /
      // Windows). Safe to call before _isInitialized was true since the
      // dump only reads a file, doesn't touch native state.
      _dumpNativeLog();
    } finally {
      calloc.free(modelPathPtr);
      calloc.free(backendPtr);
      if (visionBackendPtr != nullptr) calloc.free(visionBackendPtr);
      if (audioBackendPtr != nullptr) calloc.free(audioBackendPtr);
    }
  }

  /// Create a new conversation handle with optional system message and
  /// tools. The engine allows only ONE live conversation at a time
  /// (upstream LiteRT-LM #966), so the caller must delete any prior
  /// conversation before creating a new one — this is how virtual-session
  /// multiplexing rebuilds context. The caller owns the handle and must
  /// call [LiteRtLmConversationHandle.close].
  ///
  /// [messagesJson] optionally seeds the conversation with prior turns
  /// (a JSON array of `{role, content}` objects). Used by the virtual-
  /// session multiplexer to replay a session's history into a fresh
  /// conversation. When null the conversation starts empty (legacy
  /// behaviour).
  Future<LiteRtLmConversationHandle> createConversationHandle({
    String? systemMessage,
    String? toolsJson,
    String? messagesJson,
    double temperature = 0.8,
    int topK = 40,
    double? topP,
    int seed = 1,
    int? maxOutputTokens,
  }) {
    // The handle must be registered before the guard lifts: otherwise shutdown()
    // can clear _handles between the create and the add, leaving a live
    // conversation on a deleted engine that nothing will ever close.
    return _guardCreate(() async {
      // Serialize the native create against generation and any other create on
      // this engine. The engine is non-reentrant and holds one live
      // conversation at a time (#966); the virtual path and generation already
      // hold _nativeMutex, but this path did not — and once the create runs on
      // a spawned isolate it can race them on the shared engine pointer.
      // `protect` releases on every path (_createRawConversation can throw).
      // Only the native create is guarded; handle registration below is
      // pure-Dart bookkeeping and must stay inside _guardCreate, not the mutex.
      final conv = await _nativeMutex.protect(
        () => _createRawConversation(
          systemMessage: systemMessage,
          toolsJson: toolsJson,
          messagesJson: messagesJson,
          temperature: temperature,
          topK: topK,
          topP: topP,
          seed: seed,
          maxOutputTokens: maxOutputTokens,
        ),
      );
      edgeAiLog('[LiteRtLmFfi] Conversation created');
      final handle = LiteRtLmConversationHandle._(this, conv);
      _handles.add(handle);
      return handle;
    });
  }

  /// Create a raw native conversation pointer with the given config.
  ///
  /// Shared by [createConversationHandle] (which wraps it in a tracked
  /// [LiteRtLmConversationHandle]) and the virtual-session multiplexer
  /// ([startVirtualTurn]) which owns the pointer's lifecycle directly and
  /// does not register a handle. Lock-free — callers that need
  /// serialization (the multiplexer) hold [_nativeMutex] around it.
  Future<Pointer<LiteRtLmConversation>> _createRawConversation({
    String? systemMessage,
    String? toolsJson,
    String? messagesJson,
    double temperature = 0.8,
    int topK = 40,
    double? topP,
    int seed = 1,
    int? maxOutputTokens,
  }) async {
    _assertInitialized();
    final b = _bindings!;

    // Always build a sessionConfig with the caller's sampler params — even
    // when there's no systemMessage/tools. Otherwise temperature, topK,
    // topP, and seed get silently dropped on the floor and the model
    // falls back to its baked-in defaults (typically greedy), making
    // every call ignore stochastic decoding requests.
    //
    // LiteRT-LM v0.14.0: litert_lm_conversation_config_create() takes no
    // arguments — session_config, system message, tools, and messages are
    // attached afterwards via the litert_lm_conversation_config_set_*
    // setter chain built below. This is now real upstream API; the old
    // 6-arg overload from the now-deleted
    // native/litert_lm/patch_c_api.sh ("PATCH: 6-arg overload") is gone.
    final sessionConfig = b.litert_lm_session_config_create();

    // Sampler params go to every backend, NPU included.
    //
    // We used to skip this whole chain when the backend was NPU, citing a May
    // measurement against LiteRT-LM 032334d8 where GetSamplerBackend() did
    // `sampler_backend = backend` and then required CPU or GPU.
    //
    // Traced at the shipped pin v0.16.0 (924e79c9), that reason was never the
    // operative one: `GetSamplerBackend(LlmExecutorSettings)` is only reachable
    // from LlmLiteRtCompiledModelExecutorBase, and the NPU executor
    // (LlmLiteRtNpuCompiledModelExecutor) does not derive from it. The real
    // situation is simpler and worse — the NPU executor stores sampler_params_
    // and never reads it; every Decode() path calls ApplyGreedySampling, a
    // plain argmax. So NPU accepts the params because it discards them.
    //
    // Sending them anyway is harmless and correct the day upstream implements
    // NPU sampling. But the caller must not be left thinking they took effect,
    // which is why the warning below exists — dropping the old guard also
    // dropped the only signal the user had.
    //
    // Sampler TYPE is a separate question: at 5e0d86b only TopP (=2) was
    // implemented at engine level, with types 1 (TopK) and 3 (Greedy) rejected
    // as "UNIMPLEMENTED: Sampler type: N not implemented yet". We still send
    // TopP unconditionally and pass top_k as a hint, which native honours.
    // That was NOT re-checked at 924e79c9 — it is carried forward, not verified.
    final samplerParams = b.litert_lm_sampler_params_create(2); // always TopP
    b.litert_lm_sampler_params_set_top_k(samplerParams, topK);
    b.litert_lm_sampler_params_set_top_p(samplerParams, topP ?? 0.95);
    b.litert_lm_sampler_params_set_temperature(samplerParams, temperature);
    b.litert_lm_sampler_params_set_seed(samplerParams, seed);
    b.litert_lm_session_config_set_sampler_params(sessionConfig, samplerParams);
    b.litert_lm_sampler_params_delete(samplerParams);

    // The NPU executor argmaxes regardless of what we just set, so tell the
    // caller rather than letting them believe a seed or temperature took hold.
    // Only when they asked for something other than the greedy default —
    // warning on every NPU session would train people to ignore it.
    if (_backend == 'npu' &&
        (temperature != 0.8 || topK != 40 || topP != null || seed != 1)) {
      edgeAiLog(
        '[LiteRtLmFfi] NPU backend: sampler params (temperature=$temperature, '
        'topK=$topK, topP=$topP, seed=$seed) are sent but the NPU executor '
        'samples greedily and never reads them — output is deterministic '
        'argmax. Use PreferredBackend.cpu or .gpu if you need sampling.',
      );
    }

    // Optional per-session cap on how many tokens are *generated* (output),
    // independent of the engine's context window (maxTokens / KV-cache). This
    // is what callers usually want when they say "limit the response length".
    //
    // This was skipped on NPU too, "for the same reason as sampler params".
    // It was never measured — the reason was borrowed from the guard above by
    // analogy, and an output cap has nothing to do with sampling. Exercised
    // 2026-08-15 on Intel Lunar Lake NPU: accepted and honoured. Passing it
    // unconditionally, because silently ignoring a documented parameter is
    // worse than the failure the guard was imagining.
    if (maxOutputTokens != null) {
      b.litert_lm_session_config_set_max_output_tokens(
        sessionConfig,
        maxOutputTokens,
      );
    }

    final systemPtr = systemMessage?.toNativeUtf8();
    final toolsPtr = toolsJson?.toNativeUtf8();
    final messagesPtr = messagesJson?.toNativeUtf8();

    // v0.14.0: no-arg create + setter chain (engine is no longer an
    // argument — session_config carries everything the native side needs).
    final Pointer<LiteRtLmConversationConfig> convConfig = b
        .litert_lm_conversation_config_create();
    if (convConfig != nullptr) {
      b.litert_lm_conversation_config_set_session_config(
        convConfig,
        sessionConfig,
      );
      if (systemPtr != null) {
        b.litert_lm_conversation_config_set_system_message(
          convConfig,
          systemPtr.cast(),
        );
      }
      if (toolsPtr != null) {
        b.litert_lm_conversation_config_set_tools(convConfig, toolsPtr.cast());
        b.litert_lm_conversation_config_set_enable_constrained_decoding(
          convConfig,
          true,
        );
      }
      if (messagesPtr != null) {
        b.litert_lm_conversation_config_set_messages(
          convConfig,
          messagesPtr.cast(),
        );
      }
    }

    b.litert_lm_session_config_delete(sessionConfig);
    if (systemPtr != null) calloc.free(systemPtr);
    if (toolsPtr != null) calloc.free(toolsPtr);
    if (messagesPtr != null) calloc.free(messagesPtr);

    if (convConfig == nullptr) {
      throw Exception(
        'litert_lm_conversation_config_create returned null '
        '(systemMessage=${systemMessage != null}, tools=${toolsJson != null}, '
        'temperature=$temperature, topK=$topK, topP=$topP)',
      );
    }

    final Pointer<LiteRtLmConversation> conv;
    try {
      conv = Pointer<LiteRtLmConversation>.fromAddress(
        await _createConversationOffMainIsolate(
          engineAddr: _engine!.address,
          configAddr: convConfig.address,
        ),
      );

      // The await above yielded the event loop for the whole native round trip.
      // _guardCreate keeps shutdown() from deleting the engine meanwhile, but a
      // shutdown may now be queued behind us — in which case this conversation
      // must not escape. The engine is still alive here, so deleting is safe.
      if (_isShuttingDown || _engine == null) {
        if (conv != nullptr) _deleteConversation(conv);
        throw StateError('Client shut down while creating a conversation');
      }
    } finally {
      // Isolate.run can throw (isolate spawn failure under memory pressure,
      // dlopen/lookupFunction failure in the fresh isolate). Without this the
      // config leaks on that path.
      b.litert_lm_conversation_config_delete(convConfig);
    }

    if (conv == nullptr) {
      _dumpNativeLog();
      // With tools the runtime also builds a constraint for tool calls, and
      // that is the usual culprit here: FunctionGemma's constraint provider
      // accepts only a SentencePiece tokenizer, so a bundle exported with a
      // Hugging Face tokenizer cannot open a conversation with tools at all.
      throw Exception(
        toolsJson == null
            ? 'Failed to create conversation'
            : 'Failed to create conversation with tools. Tool calls run with '
                  'constrained decoding; for FunctionGemma that needs the '
                  '.litertlm to carry a SentencePiece tokenizer, and a bundle '
                  'exported with a Hugging Face tokenizer cannot provide one.',
      );
    }

    _liveConvs.add(conv); // #379: track liveness so late cancels can't UAF
    return conv;
  }

  /// Legacy single-conversation create. Closes the previous legacy
  /// conversation (if any) and opens a fresh one stored in [_legacyHandle].
  /// Kept for backward compat — new code should use
  /// [createConversationHandle] and own the handle directly.
  Future<void> createConversation({
    String? systemMessage,
    String? toolsJson,
    double temperature = 0.8,
    int topK = 40,
    double? topP,
    int seed = 1,
  }) async {
    _legacyHandle?.close();
    final handle = await createConversationHandle(
      systemMessage: systemMessage,
      toolsJson: toolsJson,
      temperature: temperature,
      topK: topK,
      topP: topP,
      seed: seed,
    );
    // A shutdown that landed while we were suspended already closed this handle
    // (it was registered in _handles inside the guard). Publishing it would
    // leave a closed conversation reachable on a torn-down client.
    if (handle.isClosed) {
      throw StateError('Client shut down while creating a conversation');
    }
    _legacyHandle = handle;
  }

  /// Build the JSON message for the Conversation API.
  ///
  /// Format: `{"role": "user", "content": [{"type": "text", "text": "..."}]}`
  /// Supports multiple images via `imagesBytes` list.
  static String buildMessageJson(
    String text, {
    List<Uint8List>? imagesBytes,
    Uint8List? audioBytes,
  }) {
    final content = <Map<String, dynamic>>[];
    if (imagesBytes != null) {
      for (final imageBytes in imagesBytes) {
        content.add({'type': 'image', 'blob': base64Encode(imageBytes)});
      }
    }
    if (audioBytes != null) {
      content.add({'type': 'audio', 'blob': base64Encode(audioBytes)});
    }
    content.add({'type': 'text', 'text': text});
    return jsonEncode({'role': 'user', 'content': content});
  }

  /// Serialize a message history into the `messages_json` array the
  /// conversation config accepts as a preface. Each entry is a whole
  /// Conversation API message — user and assistant text, an assistant turn
  /// with `tool_calls`, a role-`tool` result. Used by the virtual-session
  /// multiplexer to rebuild a session's full context in one prefill when
  /// switching the single live conversation.
  ///
  /// Verified honored by the patched native (a `messages_json` preface with
  /// a prior user+assistant turn lets the model recall it).
  static String buildHistoryJson(List<Map<String, Object?>> messages) =>
      jsonEncode(messages);

  /// Extract text from a LiteRT-LM JSON response chunk. Delegates to
  /// [SdkTextExtractor] — single source of truth shared with the web
  /// `@litert-lm/core` path so both engines map identical chunks to text
  /// the same way.
  static String extractTextFromResponse(String jsonStr) =>
      SdkTextExtractor.extractTextFromResponse(jsonStr);

  /// Send a message and get streaming response as plain text chunks on the
  /// given conversation. Supports multiple images via `imageBytes` list.
  Stream<String> _chatOn(
    Pointer<LiteRtLmConversation> conv,
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    final messageJson = buildMessageJson(
      text,
      imagesBytes: imageBytes,
      audioBytes: audioBytes,
    );
    final extraContext = thinkingExtraContext(enableThinking);
    return _sendMessageStreamRawOn(
      conv,
      messageJson,
      extraContext: extraContext,
    ).map(extractTextFromResponse);
  }

  /// Same as [_chatOn] but yields raw SDK JSON chunks without
  /// `extractTextFromResponse` mapping. Required by Gemma 4 path so callers
  /// can read the structured `tool_calls` field via [extractToolCalls].
  Stream<String> _chatRawOn(
    Pointer<LiteRtLmConversation> conv,
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    final messageJson = buildMessageJson(
      text,
      imagesBytes: imageBytes,
      audioBytes: audioBytes,
    );
    final extraContext = thinkingExtraContext(enableThinking);
    return _sendMessageStreamRawOn(
      conv,
      messageJson,
      extraContext: extraContext,
    );
  }

  /// Legacy: streaming chat on the implicit [_legacyHandle] conversation.
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _assertConversation();
    return _legacyHandle!.chat(
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    );
  }

  /// Legacy: raw streaming chat on the implicit [_legacyHandle] conversation.
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _assertConversation();
    return _legacyHandle!.chatRaw(
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    );
  }

  /// Send a raw JSON message on the given conversation and get a streaming
  /// response. Holds [_nativeMutex] for the whole generation so concurrent
  /// conversations don't race inside liblitert_lm; releases on completion or
  /// error.
  Stream<String> _sendMessageStreamRawOn(
    Pointer<LiteRtLmConversation> conv,
    String messageJson, {
    String? extraContext,
  }) async* {
    await _nativeMutex.acquire();
    try {
      yield* _doSendMessageStreamRawOn(
        conv,
        messageJson,
        extraContext: extraContext,
      );
    } finally {
      _nativeMutex.release();
    }
  }

  /// The single native conversation currently materialized for the
  /// virtual-session multiplexer. The LiteRT-LM engine allows only ONE live
  /// conversation at a time (upstream #966), so virtual sessions take turns:
  /// each turn tears this down and rebuilds it seeded with the active
  /// session's history. null when no virtual turn is in flight.
  Pointer<LiteRtLmConversation>? _virtualConv;

  /// Run one turn for a virtual session, holding [_nativeMutex] for the whole
  /// turn so no other virtual session can swap the live conversation out from
  /// under it.
  ///
  /// The turn is: tear down the previously-active virtual conversation (if
  /// any), create a fresh one seeded with [historyJson] (a `messages_json`
  /// preface that replays this session's prior user+assistant turns — proven
  /// honored by the patched native), then stream the response for
  /// [messageJson]. The conversation is left live after the stream so a
  /// follow-up turn on the SAME session can reuse it without a rebuild; only a
  /// turn on a DIFFERENT session pays the teardown+replay cost.
  ///
  /// [conversationToken] identifies the virtual session. When it equals the
  /// token that built [_virtualConv], the existing live conversation is
  /// reused (cheap same-session follow-up). Otherwise it's rebuilt.
  /// True while a virtual turn holds [_nativeMutex] and is actively streaming.
  /// Lets [releaseVirtualConversation] (a session closing mid-generation) defer
  /// the native teardown instead of deleting the pointer out from under the
  /// live stream (use-after-free).
  bool _virtualTurnInFlight = false;

  /// Set when a virtual turn is cancelled mid-generation. A cancelled
  /// conversation answers every later message with nothing, so the next turn
  /// must rebuild it even when it belongs to the same session.
  bool _virtualConvStopped = false;

  /// Token of a session that asked to release the live conversation while a
  /// turn was in flight. The teardown is deferred to the turn's cleanup.
  Object? _pendingReleaseToken;

  Stream<String> startVirtualTurn({
    required Object conversationToken,
    required String messageJson,
    required List<Map<String, Object?>> history,
    String? systemMessage,
    String? toolsJson,
    double temperature = 0.8,
    int topK = 40,
    double? topP,
    int seed = 1,
    String? extraContext,
    int? maxOutputTokens,
  }) {
    // StreamController (not async*) so the mutex release is tied to the
    // controller lifecycle — it fires on done, error, AND consumer cancel /
    // abandon. An async* generator's finally only runs when the consumer
    // drains the stream, so an abandoned stream would hold the mutex forever
    // and deadlock every other session.
    final controller = StreamController<String>();
    var mutexHeld = false;
    StreamSubscription<String>? inner;
    // Set by onCancel. If the consumer cancels while onListen is still awaiting
    // the mutex or the conversation create, `inner` is null so the cancel can't
    // reach it — and onListen would otherwise resume and start a generation
    // nobody is listening to. onListen checks this before starting the turn.
    var cancelledByConsumer = false;

    Future<void> releaseAndCleanup() async {
      _virtualTurnInFlight = false;
      // Honor a teardown that a closing session deferred while we held the lock.
      if (_pendingReleaseToken != null) {
        final pending = _pendingReleaseToken;
        _pendingReleaseToken = null;
        if (_virtualActiveToken == pending) {
          final conv = _virtualConv;
          if (conv != null) {
            _deleteConversation(conv);
            _virtualConv = null;
            _virtualActiveToken = null;
          }
        }
      }
      if (mutexHeld) {
        mutexHeld = false;
        _nativeMutex.release();
      }
    }

    controller.onListen = () async {
      try {
        await _nativeMutex.acquire();
        mutexHeld = true;
        _virtualTurnInFlight = true;
        if (_virtualActiveToken != conversationToken ||
            _virtualConv == null ||
            _virtualConvStopped) {
          // Switching sessions (or first turn, or the turn after a stop): drop
          // the old live conversation and rebuild one replaying this session's
          // history as a preface.
          _virtualConvStopped = false;
          final old = _virtualConv;
          if (old != null) {
            _deleteConversation(old);
            _virtualConv = null;
          }
          final historyJson = history.isEmpty
              ? null
              : buildHistoryJson(history);
          // Both fields are published inside the guard body: assigning them in
          // the await's continuation would let shutdown() delete the engine
          // first, leaving _virtualConv pointing at a conversation whose engine
          // is gone — which releaseAndCleanup() would then try to delete.
          await _guardCreate(() async {
            final conv = await _createRawConversation(
              systemMessage: systemMessage,
              toolsJson: toolsJson,
              messagesJson: historyJson,
              temperature: temperature,
              topK: topK,
              topP: topP,
              seed: seed,
              maxOutputTokens: maxOutputTokens,
            );
            _virtualConv = conv;
            _virtualActiveToken = conversationToken;
          });
        }
        // _guardCreate above yields the event loop, so a shutdown() queued
        // behind us can delete _virtualConv before we get here. Surface it as a
        // clean "closed" error instead of a Null-check-operator crash.
        if (_isShuttingDown || _virtualConv == null) {
          throw StateError('Client is shutting down; conversation was closed');
        }
        // A cancel that landed during the mutex wait or the create above left
        // `inner` null, so it never reached native. Don't start an orphan turn
        // for a consumer that is already gone — release and close instead.
        if (cancelledByConsumer) {
          await releaseAndCleanup();
          if (!controller.isClosed) await controller.close();
          return;
        }
        inner =
            _doSendMessageStreamRawOn(
              _virtualConv!,
              messageJson,
              extraContext: extraContext,
            ).listen(
              controller.add,
              onError: controller.addError,
              onDone: () async {
                await releaseAndCleanup();
                if (!controller.isClosed) await controller.close();
              },
              cancelOnError: false,
            );
      } catch (e, st) {
        controller.addError(e, st);
        await releaseAndCleanup();
        if (!controller.isClosed) await controller.close();
      }
    };

    // Fires when the consumer cancels / abandons the stream — guarantees the
    // mutex is released even if generation never completed.
    controller.onCancel = () async {
      cancelledByConsumer = true;
      // Cancel the live native turn explicitly. `inner?.cancel()` alone only
      // reaches native transitively, and only once `inner` exists; a cancel
      // that arrives during the mutex wait or create would otherwise never stop
      // the native decode. `cancelVirtualTurn` is lock-free and a no-op unless
      // this token owns the currently-live conversation.
      //
      // Guard on `mutexHeld`: onCancel also fires as implicit teardown after a
      // stream completes normally (Dart delivers `done` by cancelling the
      // subscription). On that path the inner stream's onDone has already run
      // `releaseAndCleanup()`, which clears `mutexHeld` synchronously — so
      // `mutexHeld` is false here and we skip cancelling a just-finished, about-
      // to-be-reused `_virtualConv`. A genuine mid-flight cancel still holds the
      // mutex, so `mutexHeld` is true and the cancel fires.
      if (mutexHeld) cancelVirtualTurn(conversationToken);
      await inner?.cancel();
      await releaseAndCleanup();
    };

    return controller.stream;
  }

  /// Token of the virtual session whose history is currently materialized in
  /// [_virtualConv]. Used to skip the teardown+replay when the next turn is on
  /// the same session.
  Object? _virtualActiveToken;

  /// Cancel an in-flight virtual turn for [conversationToken]. Mirrors
  /// [_cancelOn] but targets the shared live virtual conversation. Does NOT
  /// take the mutex (it must interrupt a generation that already holds it).
  ///
  /// No-op unless [conversationToken] owns the currently-live conversation —
  /// otherwise one session's `stopGeneration()` would cancel another session's
  /// in-flight generation (the single conversation is shared).
  void cancelVirtualTurn(Object conversationToken) {
    if (_virtualActiveToken != conversationToken) return;
    final conv = _virtualConv;
    if (conv == null) return;
    // Only a cancel that lands inside a turn damages the conversation.
    if (_virtualTurnInFlight) _virtualConvStopped = true;
    _cancelOn(conv);
  }

  /// Tear down the live virtual conversation if it belongs to
  /// [conversationToken]. Called when a virtual session closes so its native
  /// conversation doesn't linger. If a different session is active, this is a
  /// no-op — that session's conversation must stay live.
  ///
  /// If a turn is in flight, the teardown is DEFERRED to the turn's cleanup —
  /// deleting the pointer now would be a use-after-free. We also cancel the
  /// in-flight generation so the turn finishes promptly and the deferred
  /// teardown runs.
  void releaseVirtualConversation(Object conversationToken) {
    if (_virtualActiveToken != conversationToken) return;
    if (_virtualTurnInFlight) {
      _pendingReleaseToken = conversationToken;
      final conv = _virtualConv;
      if (conv != null) _cancelOn(conv);
      return;
    }
    final conv = _virtualConv;
    if (conv != null) {
      _deleteConversation(conv);
      _virtualConv = null;
      _virtualActiveToken = null;
    }
  }

  Stream<String> _doSendMessageStreamRawOn(
    Pointer<LiteRtLmConversation> conv,
    String messageJson, {
    String? extraContext,
  }) {
    _assertInitialized();
    final b = _bindings!;

    final controller = StreamController<String>();

    final messagePtr = messageJson.toNativeUtf8();
    final extraPtr = extraContext != null
        ? extraContext.toNativeUtf8()
        : nullptr;

    // NativeCallable.listener is thread-safe — the callback can be
    // invoked from the native background thread that LiteRT-LM uses
    // for streaming, and Dart will marshal it to the right isolate.
    // Dart callback — receives heap-copied strings from proxy
    late final NativeCallable<_StreamCallbackNative> callable;
    callable = NativeCallable<_StreamCallbackNative>.listener((
      Pointer<Void> data,
      Pointer<Char> chunk,
      int isFinal,
      Pointer<Char> errorMsg,
    ) {
      if (errorMsg != nullptr && errorMsg.address != 0) {
        final error = _decodeNativeString(errorMsg);
        _proxyFreeString!(errorMsg); // free strdup'd string
        // stopGeneration() (and any other caller-initiated cancel) surfaces
        // here as a CANCELLED error from native. That's not an error from
        // the API consumer's perspective — the stream just stops cleanly
        // at whatever token was last delivered.
        if (error.startsWith('CANCELLED')) {
          controller.close();
        } else {
          controller.addError(Exception('Stream error: $error'));
          controller.close();
        }
        callable.close();
        calloc.free(messagePtr);
        if (extraPtr != nullptr) calloc.free(extraPtr);
        return;
      }

      if (chunk != nullptr && chunk.address != 0) {
        final text = chunk.cast<Utf8>().toDartString();
        _proxyFreeString!(chunk); // free strdup'd string
        if (text.isNotEmpty) {
          controller.add(text);
        }
      }

      if (isFinal != 0) {
        controller.close();
        callable.close();
        calloc.free(messagePtr);
        if (extraPtr != nullptr) calloc.free(extraPtr);
      }
    });

    // Create proxy that strdup's strings before forwarding to Dart callback
    final outProxyFn = calloc<Pointer<NativeFunction<_StreamCallbackNative>>>();
    final proxyData = _proxyCreate!(
      callable.nativeFunction,
      nullptr,
      outProxyFn,
    );
    final proxyFn = outProxyFn.value;
    calloc.free(outProxyFn);

    // v0.12.0 send_message_stream takes a LiteRtLmConversationOptionalArgs*
    // that must be a real allocation (passing null sigsegvs inside
    // litert_lm_lib). We allocate an empty one per call and free it after
    // the native call returns; the callback fires synchronously inside.
    final optionalArgs = b.litert_lm_conversation_optional_args_create();
    if (optionalArgs == nullptr) {
      calloc.free(messagePtr);
      if (extraPtr != nullptr) calloc.free(extraPtr);
      callable.close();
      throw StateError(
        'litert_lm_conversation_optional_args_create returned null — '
        'native libLiteRtLm.dylib initialization failure',
      );
    }

    final result = b.litert_lm_conversation_send_message_stream(
      conv,
      messagePtr.cast(),
      extraPtr == nullptr ? nullptr : extraPtr.cast(),
      optionalArgs,
      proxyFn.cast(),
      proxyData,
    );

    b.litert_lm_conversation_optional_args_delete(optionalArgs);

    if (result != 0) {
      controller.addError(
        Exception('Failed to start streaming (code: $result)'),
      );
      controller.close();
      callable.close();
      calloc.free(messagePtr);
      if (extraPtr != nullptr) calloc.free(extraPtr);
    }

    // Consumer abandoned the stream (subscription.cancel) without calling
    // stopGeneration(). Tell native to stop sampling so the GPU isn't left
    // generating an orphaned response: otherwise the next close()/inference
    // can stall on a still-busy shared GPU conversation — observed on
    // Windows Intel iGPU as a hang on session.close() that cascades the whole
    // gate (macOS/Linux mask it by finishing the orphaned generation fast).
    // The native cancel surfaces as a CANCELLED error in the callback above,
    // which closes the controller cleanly. Idempotent on an already-finished
    // generation, so it's safe even if the stream completed concurrently.
    controller.onCancel = () => _cancelOn(conv);

    return controller.stream;
  }

  /// Legacy: streaming raw on the implicit [_legacyHandle] conversation.
  Stream<String> sendMessageStreamRaw(
    String messageJson, {
    String? extraContext,
  }) {
    _assertConversation();
    return _legacyHandle!.sendMessageStreamRaw(
      messageJson,
      extraContext: extraContext,
    );
  }

  /// Send a text message on the given conversation and get the full response
  /// (sync C API, non-blocking Dart). Serialized via [_nativeMutex] so it
  /// can't run concurrently with another conversation's generation.
  Future<String> _sendMessageOn(
    Pointer<LiteRtLmConversation> conv,
    String messageJson, {
    String? extraContext,
  }) {
    return _nativeMutex.protect(() async {
      _assertInitialized();
      final b = _bindings!;

      final messagePtr = messageJson.toNativeUtf8();
      final extraPtr = extraContext != null
          ? extraContext.toNativeUtf8()
          : nullptr;

      // v0.12.0 send_message requires a non-null LiteRtLmConversationOptionalArgs*.
      final optionalArgs = b.litert_lm_conversation_optional_args_create();
      if (optionalArgs == nullptr) {
        calloc.free(messagePtr);
        if (extraPtr != nullptr) calloc.free(extraPtr);
        throw StateError(
          'litert_lm_conversation_optional_args_create returned null — '
          'native libLiteRtLm.dylib initialization failure',
        );
      }

      try {
        final response = b.litert_lm_conversation_send_message(
          conv,
          messagePtr.cast(),
          extraPtr == nullptr ? nullptr : extraPtr.cast(),
          optionalArgs,
        );

        if (response == nullptr) {
          throw Exception('send_message returned null');
        }

        final strPtr = b.litert_lm_json_response_get_string(response);
        final result = strPtr == nullptr
            ? ''
            : strPtr.cast<Utf8>().toDartString();
        b.litert_lm_json_response_delete(response);
        return result;
      } finally {
        b.litert_lm_conversation_optional_args_delete(optionalArgs);
        calloc.free(messagePtr);
        if (extraPtr != nullptr) calloc.free(extraPtr);
      }
    });
  }

  /// Legacy: sync send on the implicit [_legacyHandle] conversation.
  Future<String> sendMessage(String messageJson, {String? extraContext}) {
    _assertConversation();
    return _legacyHandle!.sendMessage(messageJson, extraContext: extraContext);
  }

  /// Cancel ongoing generation on the given conversation.
  void _cancelOn(Pointer<LiteRtLmConversation> conv) {
    // #379: never cancel a conversation that has already been freed. The
    // raw-stream and virtual-turn onCancel hooks can fire after model/handle/
    // engine teardown deleted the conversation; dereferencing the dangling
    // pointer is a use-after-free SIGSEGV in native Conversation::CancelProcess.
    // (Address-keyed — see the _liveConvs ABA note for the residual it leaves.)
    if (!_liveConvs.contains(conv)) return;
    if (_bindings != null) {
      _bindings!.litert_lm_conversation_cancel_process(conv);
      edgeAiLog('[LiteRtLmFfi] Generation cancelled');
    }
  }

  /// Legacy: cancel on the implicit [_legacyHandle] conversation.
  void cancelGeneration() {
    _legacyHandle?.cancelGeneration();
  }

  /// Delete a conversation pointer. Called by
  /// [LiteRtLmConversationHandle.close].
  void _deleteConversation(Pointer<LiteRtLmConversation> conv) {
    // Drop liveness first so any onCancel that races this teardown no-ops in
    // [_cancelOn] rather than dereferencing the pointer we are about to free.
    _liveConvs.remove(conv);
    if (_bindings != null) {
      _bindings!.litert_lm_conversation_delete(conv);
      edgeAiLog('[LiteRtLmFfi] Conversation closed');
    }
  }

  /// Legacy: close the implicit [_legacyHandle] conversation.
  void closeConversation() {
    _legacyHandle?.close();
    _legacyHandle = null;
  }

  /// Shutdown the engine and release all resources. Closes every live
  /// conversation handle first (legacy + any opened directly).
  ///
  /// Waits for any conversation create suspended inside [_guardCreate]. Since
  /// `litert_lm_conversation_create` runs on a spawned isolate, deleting the
  /// engine while one is in flight frees the engine out from under native code
  /// that is still dereferencing it.
  ///
  /// Consequently this never completes if the native create itself hangs. That
  /// is deliberate — the alternative is tearing down the engine underneath it —
  /// but it means [FfiInferenceModel.close] inherits the hang. There is no
  /// timeout escape hatch.
  Future<void> shutdown() async {
    _isShuttingDown = true;
    if (_createsInFlight > 0) {
      _createsQuiescent ??= Completer<void>();
      await _createsQuiescent!.future;
    }

    // Copy because close() mutates _handles.
    for (final h in _handles.toList()) {
      h.close();
    }
    _handles.clear();
    _legacyHandle = null;

    // Tear down the shared virtual-session conversation too. Cancel any
    // in-flight virtual turn first: like handle.close(), an uncancelled
    // conversation_delete blocks in ~SessionBasic → ThreadPool::WaitUntilDone
    // draining the live generation (the #364 ANR). Safe post-#379 — vc is still
    // in _liveConvs here, so _cancelOn reaches native rather than no-oping.
    final vc = _virtualConv;
    if (vc != null) {
      _cancelOn(vc);
      _deleteConversation(vc);
      _virtualConv = null;
      _virtualActiveToken = null;
    }

    if (_engine != null && _engine != nullptr && _bindings != null) {
      _bindings!.litert_lm_engine_delete(_engine!);
      _engine = null;
      edgeAiLog('[LiteRtLmFfi] Engine deleted');
    }
    // engine_delete bulk-frees every remaining conversation at once; the
    // handle/virtual drains above already emptied the registry, but clear it so
    // no address can linger as a dangling "live" entry after a bulk free.
    _liveConvs.clear();

    _isInitialized = false;
    _backend = null;
    _tokenizerMissing = false;
    _isShuttingDown = false;
  }

  /// Latched once the tokenizer symbols turn out to be missing from the loaded
  /// library, so a native bump that drops them degrades once and loudly rather
  /// than silently on every call. Reset by [shutdown] with the rest of the
  /// engine state.
  bool _tokenizerMissing = false;

  /// Token count for [text] from the model's own tokenizer, or null when it
  /// cannot be obtained.
  ///
  /// Null means "ask someone else" — no engine, engine shut down, the native
  /// call returned NULL (the only failure `engine.h` documents), or the
  /// tokenizer symbols are absent from this build. Callers budget context with
  /// this, and a budgeting helper that throws is worse than one that admits it
  /// does not know: `chat.dart` wraps the call in a bare catch that would
  /// swallow the throw and skip the increment entirely — a 100% undercount.
  ///
  /// It does NOT swallow everything. The bindings resolve symbols lazily
  /// (`late final _lookup(...)`), so the first call is where a missing symbol
  /// surfaces as `ArgumentError` — and that is precisely the signal that this
  /// fix has stopped working after a native bump. It is caught once, latched,
  /// and reported; every other error propagates.
  ///
  /// `litert_lm_engine_tokenize` is engine-level, not conversation-level: the
  /// tokenizer belongs to the model, so no session is required.
  Future<int?> tokenCount(String text) async {
    if (text.isEmpty) return 0; // measured: this tokenizer prepends no BOS
    if (_tokenizerMissing) return null;

    // Holds [_nativeMutex] like every other native call on this engine. The
    // C API is not documented as reentrant on one engine (see the field's own
    // comment), and `send_message_stream` is documented as non-blocking with
    // callbacks on a background thread — so the Dart isolate is free while a
    // decode runs, and an unguarded tokenize would reach liblitert_lm
    // concurrently with it. Callers arrive through the already-async
    // sizeInTokens, so the await costs nothing.
    return _nativeMutex.protect(() async {
      final b = _bindings;
      final engine = _engine;
      // Re-read inside the lock: shutdown() can null these while we waited.
      if (b == null || engine == null || engine == nullptr) return null;

      // Allocated inside the try: the default allocator throws ArgumentError
      // when it cannot allocate, and this method promises not to throw.
      Pointer<Utf8>? textPtr;
      Pointer<LiteRtLmTokenizeResult> result = nullptr;
      try {
        textPtr = text.toNativeUtf8();
        result = b.litert_lm_engine_tokenize(engine, textPtr.cast<Char>());
        if (result == nullptr) return null;
        final n = b.litert_lm_tokenize_result_get_num_tokens(result);
        // Non-empty text cannot legitimately tokenize to nothing, and the
        // count is bound from size_t, so a negative would be a sentinel we do
        // not understand. Either way it is a failure, not a budget of zero —
        // which would mark the turn free and undercount worse than the
        // estimate this replaced.
        if (n <= 0) return null;
        return n;
      } on ArgumentError catch (e) {
        // Either a missing symbol (lazy lookup firing here) or an allocation
        // failure. Both mean "no count this time"; only the first is permanent,
        // and telling them apart is not worth a string match — latch on the
        // lookup wording only, and let a one-off OOM retry next turn.
        final missing = e.toString().contains('Failed to lookup symbol');
        if (missing) _tokenizerMissing = true;
        edgeAiLog(
          '[LiteRtLmFfi] tokenCount unavailable${missing ? ' (symbol missing '
                    'from this native build — sizeInTokens will estimate from '
                    'here on)' : ''}: $e',
        );
        return null;
      } finally {
        if (result != nullptr) b.litert_lm_tokenize_result_delete(result);
        if (textPtr != null) calloc.free(textPtr);
      }
    });
  }

  /// Get session metrics from the given conversation including token usage.
  /// Returns empty SessionMetrics if benchmark unavailable.
  SessionMetrics _getMetricsOn(Pointer<LiteRtLmConversation> conv) {
    if (_bindings == null) {
      return SessionMetrics();
    }

    final benchmarkInfo = _bindings!.litert_lm_conversation_get_benchmark_info(
      conv,
    );
    if (benchmarkInfo == nullptr) {
      return SessionMetrics();
    }

    try {
      // Get number of turns
      final numPrefillTurns = _bindings!
          .litert_lm_benchmark_info_get_num_prefill_turns(benchmarkInfo);
      final numDecodeTurns = _bindings!
          .litert_lm_benchmark_info_get_num_decode_turns(benchmarkInfo);

      // Sum up tokens from all turns
      var inputTokens = 0;
      var outputTokens = 0;

      for (var i = 0; i < numPrefillTurns; i++) {
        inputTokens += _bindings!
            .litert_lm_benchmark_info_get_prefill_token_count_at(
              benchmarkInfo,
              i,
            );
      }

      for (var i = 0; i < numDecodeTurns; i++) {
        outputTokens += _bindings!
            .litert_lm_benchmark_info_get_decode_token_count_at(
              benchmarkInfo,
              i,
            );
      }

      // Get timing info if available
      final timeToFirstToken = _bindings!
          .litert_lm_benchmark_info_get_time_to_first_token(benchmarkInfo);
      final initTime = _bindings!
          .litert_lm_benchmark_info_get_total_init_time_in_second(
            benchmarkInfo,
          );

      // Calculate average tokens per second from last decode turn if available
      double? tokensPerSecond;
      if (numDecodeTurns > 0) {
        tokensPerSecond = _bindings!
            .litert_lm_benchmark_info_get_decode_tokens_per_sec_at(
              benchmarkInfo,
              numDecodeTurns - 1,
            );
        if (tokensPerSecond <= 0) tokensPerSecond = null;
      }

      // Cleanup benchmark info
      _bindings!.litert_lm_benchmark_info_delete(benchmarkInfo);

      return SessionMetrics(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        totalTokens: inputTokens + outputTokens,
        timeToFirstTokenMs: timeToFirstToken > 0
            ? timeToFirstToken * 1000
            : null,
        tokensPerSecond: tokensPerSecond,
        initTimeMs: initTime > 0 ? initTime * 1000 : null,
      );
    } catch (e) {
      edgeAiLog('[LiteRtLmFfiClient] Error getting metrics: $e');
      _bindings!.litert_lm_benchmark_info_delete(benchmarkInfo);
      return SessionMetrics();
    }
  }

  /// Legacy: metrics for the implicit [_legacyHandle] conversation.
  SessionMetrics getSessionMetrics() {
    final h = _legacyHandle;
    if (h == null) return SessionMetrics();
    return h.getSessionMetrics();
  }

  void _assertInitialized() {
    if (!_isInitialized || _engine == null || _engine == nullptr) {
      throw StateError('Engine not initialized. Call initialize() first.');
    }
  }

  void _assertConversation() {
    if (_legacyHandle == null || _legacyHandle!.isClosed) {
      throw StateError('No conversation. Call createConversation() first.');
    }
  }
}

/// Name of a LiteRT-LM activation wire value, for logs and errors.
String _activationName(int value) => switch (value) {
  0 => 'float32',
  1 => 'float16',
  2 => 'int16',
  3 => 'int8',
  _ => 'type $value',
};

/// Returns the directory to hand LiteRT as `dispatch_lib_dir` on Android.
///
/// LiteRT opendir()-scans it for libLiteRtDispatch_*.so and the QNN libraries,
/// so they must exist as files. The core plugin returns a directory holding
/// exactly the stack this build bundled — nativeLibraryDir when the installer
/// extracted them, else a copy taken from the base APK or its config split (a
/// Play install). The list comes from here because the build decides it.
Future<String> _prepareAndroidNpuDispatchDir() async {
  const bundledChannel = MethodChannel('flutter_gemma_bundled');
  final String? dir;
  try {
    dir = await bundledChannel.invokeMethod<String>('prepareNpuDispatchDir', {
      'libs': [for (final n in qualcommNpuLibs) androidLibFileName(n)],
    });
  } on MissingPluginException {
    throw const NpuDispatchUnavailableException(
      'the installed flutter_edge_ai has no prepareNpuDispatchDir; '
      'update flutter_edge_ai to the version flutter_edge_ai_litertlm '
      'requires',
    );
  } on PlatformException catch (e) {
    throw NpuDispatchUnavailableException(
      'the Qualcomm NPU libraries could not be prepared '
      '(${e.code}: ${e.message})',
    );
  }
  if (dir == null) {
    throw const NpuDispatchUnavailableException(
      'prepareNpuDispatchDir returned no directory',
    );
  }
  return dir;
}

/// The Android NPU attempt cannot start because the dispatch directory could
/// not be prepared. An [Exception], not an [Error], so `initializeFfiRuntime`
/// records it and falls back to gpu/cpu with the reason attached.
class NpuDispatchUnavailableException implements Exception {
  const NpuDispatchUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'NpuDispatchUnavailableException: $message';
}
