// The web `Engine`: the same public shape as the native one
// (`src/api/engine.dart`), over `@litert-lm/core`'s `Engine`
// ([liteRtLmWebRuntime]) on WebGPU or WebAssembly. The public library exports
// it in place of the native one where `dart.library.js_interop` is true.
//
// What exists natively and not here is refused, never ignored: the NPU, a CPU
// thread count, vision and audio encoders, the cache directory, the activation
// type, speculative decoding, the tokenizer and option scoring. The page loads
// the runtime itself (its module script sets `window.Engine` and
// `window.litertLmReady`; see the README's web setup).

import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../api/backend.dart';
import '../api/config.dart';
import '../api/conversation.dart';
import '../api/message.dart' show messageJson, toolsJson;
import '../bundle/litertlm_bundle_info.dart' show BundleInfo;
import '../ffi/engine_sampler_latch.dart';
import '../ffi/thinking_context.dart';
import '../runtime/errors.dart';
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
    required this.maxNumTokens,
    required this._pageLock,
  });

  final JsLiteRtLmEngine _js;
  final LiteRtLmPageLock _pageLock;

  /// The text model's backend, as the runtime resolved it: WebGPU
  /// ([Backend.gpu]) or WebAssembly ([Backend.cpu]).
  final Backend backend;

  /// Always null on the web: the engine loads no vision encoder.
  final Backend? visionBackend = null;

  /// Always null on the web: the engine loads no audio encoder.
  final Backend? audioBackend = null;

  /// The context window the runtime resolved: the one asked for, else the
  /// bundle's own; 0 when it reported none.
  final int maxNumTokens;

  /// Always null on the web: the runtime takes no activation type.
  final ActivationDataType? activationDataType = null;

  /// Always null on the web: the page cannot read the file by path.
  final BundleInfo? bundleInfo = null;

  final _handles = <WebConversationHandle>{};
  final _samplerLatch = EngineSamplerLatch();
  bool _closed = false;
  Future<void>? _closing;

  /// Loads [config.modelPath] — a URL the page can fetch (`blob:`, `https:`)
  /// — on [config.backend]: WebGPU for [Backend.gpu], WebAssembly for
  /// [Backend.cpu]. One attempt, no fallback.
  ///
  /// Throws [UnsupportedError] for what the web runtime does not have (see
  /// the library comment), [StateError] when the page did not load
  /// `@litert-lm/core`, and the runtime's own error when it refuses the model.
  static Future<Engine> create(EngineConfig config) => createWebEngine(config);

  /// Starts a conversation, with its own `@litert-lm/core` conversation.
  ///
  /// Throws [ConstraintUnsupportedException] for a response format (the web
  /// conversation API has no constrained decoding) and [UnsupportedError] for
  /// speculative decoding or a thinking token budget.
  Future<Conversation> createConversation([ConversationConfig? config]) =>
      _createConversation(config);

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
    final sampling = samplerFor(
      c.samplerConfig ?? defaultSamplerConfig,
      const BundleSampler(),
    );
    final explicit = c.samplerConfig != null;
    final messages = <Map<String, Object?>>[
      if (c.systemInstruction case final system? when system.isNotEmpty)
        {'role': 'system', 'content': system},
      for (final m in c.initialMessages) messageJson(m),
    ];
    final tools = toolsJson(c.tools);
    final preface = <String, Object?>{
      if (messages.isNotEmpty) 'messages': messages,
      if (tools != null) 'tools': jsonDecode(tools),
      // The key the templates read, sent both ways — see [thinkingContext].
      'extra_context': {...c.extraContext, ...thinkingContext(enableThinking)},
    };
    final options = JSObject()
      ..['sessionConfig'] = webSessionConfig(
        sampling,
        maxOutputTokens: c.maxOutputTokens,
      ).jsify()
      ..['preface'] = preface.jsify();
    // Strips the thinking channel from the KV cache so it does not pollute
    // later turns, as natively.
    if (enableThinking) options['filterChannelContentFromKvCache'] = true.toJS;
    // Constrained decoding stays off, unlike natively: with it on, the WASM
    // grammar does not return to its start state after a completed tool-call
    // block, so the next decode round of that conversation aborts with
    // `Invalid token at state N` (google-ai-edge/LiteRT-LM#2434; measured on
    // 0.17.0 in example/integration_test/web_function_calling_test.dart).
    // Gemma 4 emits well-formed tool-call blocks without the grammar.
    final took = Stopwatch()..start();
    // May prefill the preface inside the page's WebAssembly module.
    final js = await _pageLock.run(
      () => _js.createConversation(options).toDart,
    );
    runtimeLog(
      '[litertlm_dart/web] createConversation: ${took.elapsedMilliseconds} ms',
    );
    if (_closed) {
      try {
        await js.delete().toDart;
      } catch (e) {
        runtimeLog(
          '[litertlm_dart/web] deleting a conversation built while the engine '
          'closed failed: $e',
        );
      }
      throw StateError('The engine was closed while a conversation opened.');
    }
    late final WebConversationHandle handle;
    handle = WebConversationHandle(
      js,
      enableThinking: enableThinking,
      extraContext: c.extraContext,
      onGeneration: () => _noteGeneration(sampling, explicit: explicit),
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

  /// Refused on the web: `@litert-lm/core` exposes no tokenizer.
  Future<List<int>> tokenize(String text) =>
      throw UnsupportedError(_noTokenizer);

  /// Refused on the web: `@litert-lm/core` exposes no tokenizer.
  Future<String> detokenize(List<int> ids) =>
      throw UnsupportedError(_noTokenizer);

  static const _noTokenizer =
      'The web runtime ($liteRtLmWebRuntime) exposes no tokenizer.';

  /// Refused on the web: `@litert-lm/core` has no scoring or rewind.
  Future<ScoringRun> scoreTargets(
    String prompt,
    List<String> targets, {
    CancelSignal? cancel,
  }) => throw UnsupportedError(
    'Option scoring does not run on the web: $liteRtLmWebRuntime has no '
    'text scoring and no rewind.',
  );

  /// Closes every conversation — each waits, at most 30 s, for its
  /// generation to end — and deletes the engine. A reply still streaming ends
  /// with [ConversationClosedException]; a later send on any of its
  /// conversations, and every other call on the engine, is a [StateError].
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final handles = _handles.toList();
    for (final handle in handles) {
      handle.close();
    }
    await Future.wait([for (final handle in handles) handle.closed]);
    try {
      await _js.delete().toDart.timeout(
        WebConversationHandle.closeDrainTimeout,
      );
    } catch (e) {
      runtimeLog('[litertlm_dart/web] engine.delete() failed: $e');
    }
  }
}

/// [Engine.create], with [model] — a `ReadableStream<Uint8Array>` or a `Blob`
/// — in place of [EngineConfig.modelPath] when given: what a model of more
/// than 2 GB needs, which a `blob:` URL fetch cannot carry
/// (`ERR_BLOB_OUT_OF_MEMORY`). [EngineConfig.modelPath] then only names it
/// in the log.
Future<Engine> createWebEngine(
  EngineConfig config, {
  JSAny? model,
  LiteRtLmPageLock? pageLock,
}) async {
  _refuseOnWeb(config);
  await _awaitRuntime();
  final backendValue = switch (config.backend) {
    CpuBackend() => liteRtLmWebBackendCpu,
    GpuBackend() => liteRtLmWebBackendGpu,
    NpuBackend() => throw StateError('refused above'),
  };
  final settings = JSObject()
    ..['model'] = model ?? config.modelPath.toJS
    ..['backend'] = backendValue.toJS;
  if (config.maxNumTokens case final tokens?) {
    settings['mainExecutorSettings'] = JSObject()
      ..['maxNumTokens'] = tokens.toJS;
  }
  final lock = pageLock ?? liteRtLmPageLock;
  runtimeLog(
    '[litertlm_dart/web] Engine.create({model: '
    '${model == null ? config.modelPath : '<stream: ${config.modelPath}>'}})',
  );
  final took = Stopwatch()..start();
  // Streams the model into the page's WebAssembly module, which the
  // EmbeddingGemma 2 engine shares: see page_lock.dart.
  final js = await lock.run(() => JsLiteRtLmEngine.create(settings).toDart);
  runtimeLog(
    '[litertlm_dart/web] Engine.create: ${took.elapsedMilliseconds} ms',
  );
  final resolved = js.settings;
  final resolvedBackend = resolved?['backend'];
  final executor = resolved?['mainExecutorSettings'];
  final tokens = executor.isA<JSObject>()
      ? (executor as JSObject)['maxNumTokens']
      : null;
  return Engine._(
    js,
    backend: resolvedBackend.isA<JSNumber>()
        ? ((resolvedBackend as JSNumber).toDartInt == liteRtLmWebBackendCpu
              ? const Backend.cpu()
              : const Backend.gpu())
        : config.backend,
    maxNumTokens: tokens.isA<JSNumber>()
        ? (tokens as JSNumber).toDartInt
        : (config.maxNumTokens ?? 0),
    pageLock: lock,
  );
}

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

void _refuseOnWeb(EngineConfig config) {
  final refused = [
    if (config.backend is NpuBackend) 'the NPU (Backend.npu)',
    if (config.backend case CpuBackend(threadCount: _?)) 'a CPU thread count',
    if (config.visionBackend != null) 'a vision encoder (visionBackend)',
    if (config.audioBackend != null) 'an audio encoder (audioBackend)',
    if (config.maxNumImages != null) 'maxNumImages',
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
/// loaded `@litert-lm/core`: module scripts are deferred, so Dart can reach
/// here before `window.Engine` is set.
Future<void> _awaitRuntime() async {
  final ready = globalContext.getProperty<JSObject?>('litertLmReady'.toJS);
  if (ready == null) {
    throw StateError(
      'window.litertLmReady is not set. The host page must include the '
      '@litert-lm/core ESM loader from example/web/index.html — see '
      'README "Web .litertlm setup".',
    );
  }
  await (ready as JSPromise).toDart;
}
