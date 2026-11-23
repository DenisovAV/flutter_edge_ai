// The web `Engine`: the same public shape as the native one
// (`src/api/engine.dart`), over `@litert-lm/core`'s `Engine`
// ([liteRtLmWebRuntime]) on WebGPU or WebAssembly. The public library exports
// it in place of the native one where `dart.library.js_interop` is true.
//
// What does not run on the web is refused, never ignored, each with the
// reason measured on the pinned runtime (2026-11-23, Gemma 4 E2B's web export,
// Chrome 157): vision and audio encoders (an image or audio part fails), the
// NPU, the cache directory, the activation
// type, speculative decoding, the tokenizer and option scoring. The page loads
// the runtime itself (its module script sets `window.Engine` and
// `window.litertLmReady`; see litertlm_dart's README, "On the web").

import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:meta/meta.dart' show visibleForTesting;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../api/backend.dart';
import '../api/config.dart';
import '../api/conversation.dart';
import '../api/message.dart';
import '../bundle/litertlm_bundle_info.dart' show BundleInfo;
import '../ffi/engine_sampler_latch.dart';
import '../ffi/thinking_context.dart';
import '../runtime/errors.dart';
import '../runtime/load_errors.dart' show LiteRtLmEngineCreateException;
import '../runtime/runtime_log.dart';
import '../runtime/types.dart';
import 'litert_lm_js.dart';
import 'page_lock.dart';
import 'web_conversation_handle.dart';
import 'web_runtime_version.dart';
import 'web_session_config.dart';

/// One `.litertlm` model loaded by the page's `@litert-lm/core` runtime.
final class Engine {
  Engine._(
    this._js, {
    required this.backend,
    required this.visionBackend,
    required this.audioBackend,
    required this.maxNumTokens,
    required this._pageLock,
  });

  final JsLiteRtLmEngine _js;
  final LiteRtLmPageLock _pageLock;

  /// The text model's backend, as the runtime resolved it: WebGPU
  /// ([Backend.gpu], also for a web export the runtime runs through its
  /// legacy GPU executor) or WebAssembly ([Backend.cpu]).
  final Backend backend;

  /// Where the vision encoder runs, as the runtime resolved it; null when the
  /// engine loaded none.
  final Backend? visionBackend;

  /// Where the audio encoder runs, as the runtime resolved it; null when the
  /// engine loaded none.
  final Backend? audioBackend;

  /// Refuses [contents] that need an encoder this engine did not load, as
  /// natively: the runtime would fail the message later.
  void _checkMediaLoaded(List<Content> contents) {
    if (visionBackend == null &&
        contents.any((p) => p is ImageBytesContent || p is ImageFileContent)) {
      throw UnsupportedError(
        'This engine loaded no vision encoder: create it with a '
        'visionBackend to send images.',
      );
    }
    if (audioBackend == null &&
        contents.any((p) => p is AudioBytesContent || p is AudioFileContent)) {
      throw UnsupportedError(
        'This engine loaded no audio encoder: create it with an '
        'audioBackend to send audio.',
      );
    }
  }

  /// The context window the runtime resolved: the one asked for, else the
  /// bundle's own (4096 for Gemma 4 E2B's web export); 0 when it reported
  /// none. On the web it is not raised to the 1024 tokens the native
  /// CPU and GPU executors need: the web runtime takes what it is given.
  final int maxNumTokens;

  /// Always null on the web: the runtime takes no activation type.
  final ActivationDataType? activationDataType = null;

  /// Always null on the web: the page cannot read the file by path.
  final BundleInfo? bundleInfo = null;

  final _handles = <WebConversationHandle>{};
  final _pendingCreates = <Future<void>>{};
  final _samplerLatch = EngineSamplerLatch();
  bool _closed = false;
  bool _samplerDefaultNoted = false;
  Future<void>? _closing;

  /// Loads [config.modelPath] — a URL the page can fetch (`blob:`, `https:`)
  /// — on [config.backend]: WebGPU for [Backend.gpu], WebAssembly for
  /// [Backend.cpu] (whose `threadCount` becomes the runtime's
  /// `number_of_threads`). One attempt, no fallback. Pass [Backend.gpu] for
  /// Gemma 4's GPU export: the default [Backend.cpu] fails it at the first
  /// send (0.19.0: "Environment was not initialized during streaming.").
  ///
  /// Throws [UnsupportedError] for what does not run on the web (see the
  /// library comment), [StateError] when the page did not load
  /// `@litert-lm/core` or loaded one without what this release calls, and
  /// [LiteRtLmEngineCreateException] with the runtime's message when it
  /// refuses the model.
  static Future<Engine> create(EngineConfig config) => createWebEngine(config);

  /// Starts a conversation, with its own `@litert-lm/core` conversation.
  ///
  /// On the web the model file's own sampler cannot be read: a config without
  /// [ConversationConfig.samplerConfig] samples with 0.8 / 40 / 0.95 / seed 1,
  /// which is said once per engine. Throws [ConstraintUnsupportedException]
  /// for a response format (the web conversation API has no constrained
  /// decoding), [UnsupportedError] for speculative decoding, a thinking token
  /// budget or an initial message with an image or audio, and
  /// [LiteRtLmNativeException] with the runtime's message when it refuses the
  /// conversation.
  Future<Conversation> createConversation([ConversationConfig? config]) {
    if (config?.samplerConfig == null && !_samplerDefaultNoted) {
      _samplerDefaultNoted = true;
      // ignore: avoid_print
      print(
        '[litertlm_dart] On the web the model file\'s own sampler cannot be '
        'read: a conversation without a samplerConfig samples with '
        'temperature 0.8, topK 40, topP 0.95, seed 1. Shown once per engine.',
      );
    }
    return _createConversation(config);
  }

  Future<Conversation> _createConversation(
    ConversationConfig? config, {
    SamplerConfig? defaultSamplerConfig,
  }) async {
    if (_closed) throw StateError('The engine is closed.');
    final c = config ?? ConversationConfig();
    if (c.responseFormat != null) {
      throw const ConstraintUnsupportedException(
        'LiteRT-LM web uses $liteRtLmWebRuntime, whose conversation API has '
        'no constrained-decoding option.',
      );
    }
    if (c.speculativeDecoding != null) {
      throw UnsupportedError(
        'The web runtime ($liteRtLmWebRuntime) has no speculative decoding.',
      );
    }
    final enableThinking = c.thinkingConfig?.enableThinking ?? false;
    if (enableThinking && c.thinkingConfig?.thinkingTokenBudget != null) {
      throw UnsupportedError(
        'The web runtime ($liteRtLmWebRuntime) takes no thinking token '
        'budget.',
      );
    }
    for (final message in c.initialMessages) {
      if (message.contents.any(
        (part) => part is ImageFileContent || part is AudioFileContent,
      )) {
        throw UnsupportedError(webMediaPathMessage);
      }
      _checkMediaLoaded(message.contents);
    }
    final sampling = samplerFor(
      c.samplerConfig ?? defaultSamplerConfig,
      const BundleSampler(),
    );
    final explicit = c.samplerConfig != null;
    final base = <Map<String, Object?>>[
      if (c.systemInstruction case final system? when system.isNotEmpty)
        {'role': 'system', 'content': system},
      for (final m in c.initialMessages) messageJson(m),
    ];
    final tools = toolsJson(c.tools);
    JSObject options(List<Object?> replay) {
      final messages = [...base, ...replay];
      final preface = <String, Object?>{
        if (messages.isNotEmpty) 'messages': messages,
        if (tools != null) 'tools': jsonDecode(tools),
        // The key the templates read, sent both ways — see [thinkingContext].
        'extra_context': {
          ...c.extraContext,
          ...thinkingContext(enableThinking),
        },
      };
      final js = JSObject()
        ..['sessionConfig'] = webSessionConfig(
          sampling,
          maxOutputTokens: c.maxOutputTokens,
        ).jsify()
        ..['preface'] = preface.jsify();
      // Strips the thinking channel from the KV cache so it does not pollute
      // later turns, as natively. A rebuild replays the runtime's history,
      // which then holds no thinking either; the stopped exchange is put
      // back as its text only.
      if (enableThinking) js['filterChannelContentFromKvCache'] = true.toJS;
      // Constrained decoding stays off, unlike natively. 0.17.0 and 0.18.0
      // aborted the decode round after a tool-call block with it on
      // (`Invalid token at state N`, google-ai-edge/LiteRT-LM#2434); 0.19.0
      // with Gemma 4 E2B's GPU export completes that round trip with it on
      // (web_litertlm_runtime_probe_test.dart, 2026-11-23), but every web
      // suite runs with it off, and Gemma 4 writes well-formed tool-call
      // blocks without the grammar.
      return js;
    }

    Future<JsLiteRtLmConversation> create(List<Object?> replay) async {
      final JsLiteRtLmConversation conversation;
      try {
        conversation = await _js.createConversation(options(replay)).toDart;
      } catch (e) {
        throw LiteRtLmNativeException(
          '$liteRtLmWebRuntime refused the conversation: $e',
        );
      }
      final missing = liteRtLmWebObjectMissing(
        conversation,
        webConversationMembers,
      );
      if (missing.isNotEmpty) {
        try {
          await awaitIfThenable(conversation.delete());
        } catch (_) {}
        throw StateError(_incompleteRuntime('conversation', missing));
      }
      return conversation;
    }

    final took = Stopwatch()..start();
    final pending = Completer<void>();
    _pendingCreates.add(pending.future);
    final JsLiteRtLmConversation js;
    try {
      // May prefill the preface inside the page's WebAssembly module.
      js = await _pageLock.run(() {
        // Closed while it waited for the page: the engine is being deleted.
        if (_closed) {
          throw StateError(
            'The engine was closed while a conversation opened.',
          );
        }
        return create(const []);
      });
    } catch (_) {
      _pendingCreates.remove(pending.future);
      pending.complete();
      rethrow;
    }
    runtimeLog(
      '[litertlm_dart/web] createConversation: ${took.elapsedMilliseconds} ms',
    );
    if (_closed) {
      // Closed while the runtime built it: nobody else will delete it.
      try {
        await awaitIfThenable(js.delete());
      } catch (e) {
        runtimeLog(
          '[litertlm_dart/web] deleting a conversation built while the engine '
          'closed failed: $e',
        );
      }
      _pendingCreates.remove(pending.future);
      pending.complete();
      throw StateError('The engine was closed while a conversation opened.');
    }
    _pendingCreates.remove(pending.future);
    pending.complete();
    late final WebConversationHandle handle;
    handle = WebConversationHandle(
      js,
      enableThinking: enableThinking,
      extraContext: c.extraContext,
      onGeneration: () => _noteGeneration(sampling, explicit: explicit),
      rebuild: create,
      preface: base,
      vision: visionBackend != null,
      audio: audioBackend != null,
      onClose: () => _handles.remove(handle),
      pageLock: _pageLock,
    );
    _handles.add(handle);
    return newConversation(
      handle,
      config: c,
      thinkingTokenBudgetCapsNothing: () {},
      engineClosed: () => _closed,
    );
  }

  /// Reports what LiteRT-LM#2080 means for a generation with [sampling], as
  /// the native client does: the web runtime is the same LiteRT-LM and keeps
  /// the sampler of its first generation too.
  void _noteGeneration(Sampler sampling, {required bool explicit}) {
    final note = _samplerLatch.onGeneration(sampling, explicit: explicit);
    if (note == null) return;
    if (!note.warn) {
      runtimeLog('[litertlm_dart/web] ${note.message}', verbose: true);
      return;
    }
    // A release build is where a wrong sampler gets reported, and runtimeLog
    // is silent there.
    // ignore: avoid_print
    print('[litertlm_dart] WARNING: ${note.message} Shown once per engine.');
  }

  /// Refused on the web: `@litert-lm/core` counts a conversation's tokens
  /// (`getTokenCount()`), but exposes no tokenizer for a text.
  Future<List<int>> tokenize(String text) async =>
      throw UnsupportedError(_noTokenizer);

  /// Refused on the web: `@litert-lm/core` exposes no detokenizer.
  Future<String> detokenize(List<int> ids) async =>
      throw UnsupportedError(_noTokenizer);

  static const _noTokenizer =
      'The web runtime ($liteRtLmWebRuntime) counts a conversation\'s tokens, '
      'but exposes no tokenizer for a text.';

  /// Refused on the web: `@litert-lm/core` has no text scoring and no rewind.
  Future<ScoringRun> scoreTargets(
    String prompt,
    List<String> targets, {
    CancelSignal? cancel,
  }) async => throw UnsupportedError(
    'Option scoring does not run on the web: $liteRtLmWebRuntime has no '
    'text scoring and no rewind.',
  );

  /// Closes every conversation — each waits, at most 30 s, for its
  /// generation to end — and deletes the engine, after any conversation
  /// still being created. A reply still streaming ends with
  /// [ConversationClosedException]; a later send on any of its
  /// conversations, and every other call on the engine, is a [StateError].
  /// Fails with the page's [LiteRtLmPagePoisonedError] when a stopped
  /// generation never ended: the engine is then left to the page (its delete
  /// would wait on that generation for good).
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    // The conversations stop first: a create queued on the page lock may be
    // waiting behind one of their generations. Started before the creates
    // are awaited, so they cannot wait on each other.
    final closes = [
      for (final handle in _handles.toList())
        handle.close().then<Object?>((_) => null, onError: (Object e) => e),
    ];
    // A create queued on the page lock refuses when its turn comes; one
    // already running deletes what it built.
    await Future.wait(_pendingCreates.toList());
    final results = await Future.wait(closes);
    final poisoned = results.whereType<LiteRtLmPagePoisonedError>().firstOrNull;
    if (poisoned != null || _pageLock.poison != null) {
      throw poisoned ?? _pageLock.poison!;
    }
    try {
      await awaitIfThenable(_js.delete());
    } catch (e) {
      noteWebDeleteFailure('An engine', e);
    }
  }
}

/// The members of a runtime conversation this release calls.
const webConversationMembers = [
  'sendMessageStreaming',
  'cancel',
  'getHistory',
  'getTokenCount',
  'delete',
];

/// Why a page's `@litert-lm/core` cannot be driven: its [what] lacks
/// [missing].
String _incompleteRuntime(String what, List<String> missing) =>
    'The page\'s @litert-lm/core $what lacks ${missing.join(', ')}, which '
    'this release calls: import $liteRtLmWebModuleUrl in its module script.';

/// [Engine.create], with [model] — a `ReadableStream<Uint8Array>` or a `Blob`
/// — in place of [EngineConfig.modelPath] when given: what a model of more
/// than 2 GB needs, which a `blob:` URL fetch cannot carry
/// (`ERR_BLOB_OUT_OF_MEMORY`). [EngineConfig.modelPath] then only names it
/// in the log.
Future<Engine> createWebEngine(
  EngineConfig config, {
  JSAny? model,
  @visibleForTesting LiteRtLmPageLock? pageLock,
}) async {
  _refuseOnWeb(config);
  final constructor = await _awaitRuntime();
  final settings = JSObject()..['model'] = model ?? config.modelPath.toJS;
  settings['backend'] = _webBackendValue(config.backend).toJS;
  if (config.visionBackend case final vision?) {
    settings['visionBackend'] = _webBackendValue(vision).toJS;
  }
  if (config.audioBackend case final audio?) {
    settings['audioBackend'] = _webBackendValue(audio).toJS;
  }
  final executor = JSObject();
  // A GPU_ARTISAN model (Gemma 4's web exports) reserves its images' space
  // per conversation up front: with none reserved the first image fails
  // ("Media embedding cache was not set.", 0.19.0, measured 2026-11-23). As
  // natively, unset is 1 with a vision encoder.
  if (config.maxNumImages ?? (config.visionBackend == null ? null : 1)
      case final images?) {
    executor['maxNumImages'] = images.toJS;
  }
  if (config.maxNumTokens case final tokens?) {
    executor['maxNumTokens'] = tokens.toJS;
  }
  if (config.backend case CpuBackend(:final threadCount?)) {
    if (threadCount < 1) {
      throw ArgumentError.value(
        threadCount,
        'threadCount',
        'must be 1 or more',
      );
    }
    executor['backendConfig'] = JSObject()
      ..['number_of_threads'] = threadCount.toJS;
  }
  if (_hasKeys(executor)) {
    settings['mainExecutorSettings'] = executor;
  }
  final lock = pageLock ?? liteRtLmPageLock;
  runtimeLog(
    '[litertlm_dart/web] Engine.create({model: '
    '${model == null ? config.modelPath : '<stream: ${config.modelPath}>'}})',
  );
  final took = Stopwatch()..start();
  // Streams the model into the page's WebAssembly module, which the
  // EmbeddingGemma 2 engine shares: see page_lock.dart.
  final JsLiteRtLmEngine js;
  try {
    js = await lock.run(
      () => (constructor as JsLiteRtLmEngine)
          .callMethod<JSPromise<JsLiteRtLmEngine>>('create'.toJS, settings)
          .toDart,
    );
  } on LiteRtLmPagePoisonedError {
    rethrow;
  } catch (e) {
    final message = '$e';
    throw LiteRtLmEngineCreateException(
      '$liteRtLmWebRuntime could not create the engine for '
      '${config.modelPath} on ${config.backend}: $message',
      nativeMessage: message,
    );
  }
  runtimeLog(
    '[litertlm_dart/web] Engine.create: ${took.elapsedMilliseconds} ms',
  );
  final resolved = js.settings;
  final resolvedBackend = resolved?['backend'];
  final resolvedExecutor = resolved?['mainExecutorSettings'];
  final tokens = resolvedExecutor.isA<JSObject>()
      ? (resolvedExecutor as JSObject)['maxNumTokens']
      : null;
  final Backend backend;
  try {
    backend = switch (resolvedBackend.isA<JSNumber>()
        ? (resolvedBackend as JSNumber).toDartInt
        : null) {
      liteRtLmWebBackendCpu => const Backend.cpu(),
      liteRtLmWebBackendGpu ||
      liteRtLmWebBackendGpuArtisan => const Backend.gpu(),
      final other => throw StateError(
        other == null
            ? '$liteRtLmWebRuntime reported no backend for the engine '
                  '(settings.backend), so this release cannot say where it '
                  'runs.'
            : '$liteRtLmWebRuntime resolved the engine to backend $other, '
                  'which this release does not know.',
      ),
    };
  } catch (_) {
    // Nobody else holds the engine: free it before refusing it.
    try {
      await awaitIfThenable(js.delete());
    } catch (e) {
      noteWebDeleteFailure('An engine', e);
    }
    rethrow;
  }
  noteOtherWebRuntimeVersion();
  Backend? encoder(String key) {
    final value = resolved?[key];
    if (!value.isA<JSNumber>()) return null;
    return switch ((value as JSNumber).toDartInt) {
      liteRtLmWebBackendCpu => const Backend.cpu(),
      liteRtLmWebBackendGpu ||
      liteRtLmWebBackendGpuArtisan => const Backend.gpu(),
      _ => null,
    };
  }

  return Engine._(
    js,
    backend: backend,
    visionBackend: encoder('visionBackend'),
    audioBackend: encoder('audioBackend'),
    maxNumTokens: tokens.isA<JSNumber>()
        ? (tokens as JSNumber).toDartInt
        : (config.maxNumTokens ?? 0),
    pageLock: lock,
  );
}

bool _hasKeys(JSObject object) => (globalContext['Object']! as JSObject)
    .callMethod<JSArray<JSAny?>>('keys'.toJS, object)
    .toDart
    .isNotEmpty;

/// [Engine.createConversation] with the model's sampler default when the
/// config sets none, as natively: values the Flutter adapter resolves, which
/// never count as the caller's choice for LiteRT-LM#2080's warning.
Future<Conversation> createConversationWithDefault(
  Engine engine,
  ConversationConfig config,
  SamplerConfig? defaultSamplerConfig,
) => engine._createConversation(
  config,
  defaultSamplerConfig: defaultSamplerConfig,
);

/// `@litert-lm/core`'s `Backend` value for [backend]: CPU (WebAssembly) or
/// GPU (WebGPU). A Gemma 4 web export asked for the GPU resolves to
/// GPU_ARTISAN, the same WebGPU (0.19.0, measured 2026-11-23).
int _webBackendValue(Backend backend) => switch (backend) {
  CpuBackend() => liteRtLmWebBackendCpu,
  GpuBackend() => liteRtLmWebBackendGpu,
  NpuBackend() => throw UnsupportedError('No NPU on the web.'),
};

void _refuseOnWeb(EngineConfig config) {
  final refused = [
    if (config.backend is NpuBackend) 'the NPU (Backend.npu)',
    if (config.visionBackend is NpuBackend) 'an NPU vision encoder',
    if (config.audioBackend is NpuBackend) 'an NPU audio encoder',
    if (config.cacheDir != null) 'a cache directory (cacheDir)',
    if (config.activationDataType != null) 'an activationDataType',
    if (config.speculativeDecoding != null) 'speculative decoding',
  ];
  if (refused.isEmpty) return;
  throw UnsupportedError(
    'The web Engine ($liteRtLmWebRuntime) has no ${refused.join(', ')}: '
    'leave ${refused.length == 1 ? 'it' : 'them'} unset on the web.',
  );
}

/// Waits for the page's module script (`window.litertLmReady`) to have
/// loaded `@litert-lm/core`, and returns its `Engine` constructor: module
/// scripts are deferred, so Dart can reach here before `window.Engine` is
/// set. A page whose loader failed, without `window.Engine`, or whose
/// `Engine` lacks a member this release calls is refused with a
/// [StateError]; another version that has them all is accepted, and said
/// once ([noteOtherWebRuntimeVersion]).
Future<JSObject> _awaitRuntime() async {
  final ready = globalContext['litertLmReady'];
  if (ready == null || ready.isUndefinedOrNull) {
    throw StateError(
      'window.litertLmReady is not set: the page does not load '
      '@litert-lm/core. Add the module script from litertlm_dart\'s README '
      '("On the web"), which imports $liteRtLmWebModuleUrl.',
    );
  }
  if (ready.isA<JSObject>() && (ready as JSObject).has('then')) {
    try {
      await (ready as JSPromise<JSAny?>).toDart;
    } catch (e) {
      throw StateError(
        'The page\'s module script failed to load @litert-lm/core '
        '(window.litertLmReady rejected: $e). It must import '
        '$liteRtLmWebModuleUrl (litertlm_dart\'s README, "On the web").',
      );
    }
  }
  final constructor = globalContext['Engine'];
  if (constructor == null || !constructor.typeofEquals('function')) {
    throw StateError(
      'window.Engine is not set: the page\'s module script must set '
      'window.Engine = m.Engine; (litertlm_dart\'s README, "On the web").',
    );
  }
  final missing = liteRtLmWebRuntimeMissing(constructor as JSObject, const [
    'createConversation',
    'delete',
  ]);
  if (missing.isNotEmpty) {
    throw StateError(_incompleteRuntime('Engine', missing));
  }
  return constructor;
}
