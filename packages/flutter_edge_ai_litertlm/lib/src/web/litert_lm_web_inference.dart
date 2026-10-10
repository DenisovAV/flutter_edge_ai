// Standalone library: the web `.litertlm` inference model + session. Lives in
// flutter_edge_ai_litertlm (extracted from core's flutter_edge_ai_web.dart). Imports
// the shared web infra (web_model_source, web_image_format) and core parsing
// directly so it no longer needs to be a `part of flutter_edge_ai_web.dart`.
import 'dart:async';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';

import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/sampling.dart';
import 'package:flutter_edge_ai/core/tool.dart';
import 'package:flutter_edge_ai/core/extensions.dart';
import 'package:flutter_edge_ai/core/function_call_parser.dart';
import 'package:flutter_edge_ai/core/parsing/sdk_response_parser.dart';
import 'package:flutter_edge_ai/core/parsing/sdk_text_extractor.dart';
import 'package:flutter_edge_ai/web/web_model_source.dart';
import 'package:flutter_edge_ai/web/web_image_format.dart';

import 'litert_lm_web.dart';
import '../thinking_context.dart';

/// `SamplerType.TOP_P` in `@litert-lm/core`.
const _samplerTypeTopP = 2;

/// Web `.litertlm` inference via the upstream `@litert-lm/core` early-preview
/// JS API (`@litert-lm/core` 0.17.1 on web through WebGPU/WASM).
///
/// Mirrors [FfiInferenceModel] (mobile/desktop) for the same C API but maps
/// it onto the JS surface: `Engine.create` → `engine.createConversation` →
/// `conversation.sendMessageStreaming(text)` returning a JS AsyncIterator.
///
/// **Limitations (matches upstream early-preview status):**
/// - Text-in/text-out only — vision/audio are warn-and-ignore (the TS
///   EngineSettings doesn't expose Audio/VisionExecutor yet).
/// - Thinking reaches the model as `extra_context` with an explicit
///   `enable_thinking` ([thinkingContext]), the key the chat templates read —
///   measured on Gemma 4 E2B in Chrome (`web_thinking_test.dart`). The earlier
///   `{thinking: true}` reached no template, which is why web thinking was
///   once documented as unsupported.
/// - LoRA throws [UnsupportedError] (parity with FFI path).
/// - `stopGeneration()` closes the local stream and calls the upstream
///   `conversation.cancel()` to abort the JS-side generation (wrapped in
///   try/catch — the early-preview API may throw if nothing is in flight).
/// - For models >2 GB use `WebStorageMode.streaming` so the resolver returns
///   an [OpfsStreamModelSource] — passing a Blob URL to `Engine.create`
///   trips Chrome's `ERR_BLOB_OUT_OF_MEMORY` limit. The
///   [WebModelSourceResolver] handles the routing transparently — same path
///   MediaPipe `WebInferenceModel` uses today.
class LiteRtLmWebInferenceModel extends InferenceModel with CloseNotifier {
  LiteRtLmWebInferenceModel({
    required this.sourceResolver,
    required this.maxTokens,
    required this.modelType,
    this.fileType = ModelFileType.litertlm,
    this.maxConcurrentSessions,
    required this.onClose,
  });

  /// Shared with [WebInferenceModel] — resolves the active model into either
  /// a [BlobUrlModelSource] (cacheApi/none) or [OpfsStreamModelSource]
  /// (streaming). Engine-specific glue lives in [_ensureEngine] below.
  final WebModelSourceResolver sourceResolver;
  final ModelType modelType;
  @override
  final ModelFileType fileType;
  @override
  final int maxTokens;
  @override
  PreferredBackend? get activeBackend => null;

  /// Cap on concurrent [openSession] sessions; null = unlimited.
  final int? maxConcurrentSessions;
  final VoidCallback onClose;

  LiteRtLmEngine? _engine;
  LiteRtLmWebSession? _session;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  /// Guards [_ensureEngine] against concurrent calls. Without it, two
  /// overlapping openSession/createSession calls both see `_engine == null`
  /// and both call `Engine.create`, leaking the first engine (JS/WASM + GPU
  /// resources) for the page lifetime.
  Completer<void>? _engineCompleter;

  /// Serializes generation across all sessions on this model — concurrent
  /// contexts, serialized inference, matching the FFI/MediaPipe paths. The
  /// `@litert-lm/core` engine is shared WebGPU/WASM state; parallel
  /// generations would contend for the accelerator. Passed to each session.
  final Mutex generationMutex = Mutex();

  /// Sessions opened via [openSession] — detached from the legacy [_session]
  /// singleton. Each owns its own `@litert-lm/core` Conversation JS object.
  final Set<LiteRtLmWebSession> _openSessions = {};

  @override
  InferenceModelSession? get session => _session;

  @override
  List<InferenceModelSession> get sessions =>
      List.unmodifiable([if (_session != null) _session!, ..._openSessions]);

  Future<void> _ensureEngine() async {
    if (_engine != null) return;
    // Concurrent-call guard: a second caller awaits the first creation instead
    // of starting its own (which would leak an engine).
    if (_engineCompleter != null) {
      await _engineCompleter!.future;
      return;
    }
    final completer = _engineCompleter = Completer<void>();
    try {
      await _createEngine();
      completer.complete();
    } catch (e, st) {
      _engineCompleter = null; // allow retry
      completer.completeError(e, st);
      rethrow;
    }
  }

  Future<void> _createEngine() async {
    final resolved = await sourceResolver.resolveActiveInferenceModel();

    // The host page wires up `window.litertLmReady` (a Promise resolving to
    // the Engine constructor) in its index.html `<script type="module">`
    // block. Module scripts are deferred, so Dart can reach here before the
    // ESM finishes loading and `window.Engine` would be undefined. Awaiting
    // the readiness promise guarantees the @litert-lm/core module is loaded
    // before any static interop call on `LiteRtLmEngine`.
    final ready = globalContext.getProperty<JSObject?>('litertLmReady'.toJS);
    if (ready == null) {
      throw StateError(
        'window.litertLmReady is not set. The host page must include the '
        '@litert-lm/core ESM loader from example/web/index.html — see '
        'README "Web .litertlm setup".',
      );
    }
    await (ready as JSPromise).toDart;

    final JSAny modelArg;
    final String diagDescription;
    switch (resolved.model) {
      case BlobUrlModelSource(:final url):
        modelArg = url.toJS;
        diagDescription = url;
      case OpfsStreamModelSource(:final filename):
        modelArg = await (resolved.model as OpfsStreamModelSource).openStream();
        diagDescription = '<OPFS ReadableStream: $filename>';
    }

    if (kDebugMode) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel] Engine.create({model: $diagDescription})',
      );
    }
    final sw = Stopwatch()..start();
    final engineFuture = LiteRtLmEngine.create(
      LiteRtLmEngineOptions(model: modelArg),
    );
    _engine = await engineFuture.toDart;
    if (kDebugMode) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel/perf] Engine.create: ${sw.elapsedMilliseconds}ms',
      );
    }
  }

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<Tool> tools = const [],
    int? maxOutputTokens,
  }) async {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    if (loraPath != null) {
      throw UnsupportedError(
        'LoRA weights are not supported on the .litertlm web path '
        '(loraPath=$loraPath). Track upstream @litert-lm/core; remove '
        'loraPath or use a MediaPipe .task web model.',
      );
    }
    // Vision/audio modality on web @litert-lm/core@0.17.1 requires a
    // dedicated Vision/AudioExecutor to be loaded at Engine.create() time.
    // The WASM runtime asserts "Vision executor should not be null, please
    // TryLoadingVisionExecutor() first.", but the TypeScript-level
    // `EngineSettings` interface (wasm_binding_types.d.ts) only exposes
    // `getMutableMainExecutorSettings()` — there's no setter for
    // VisionExecutorSettings or AudioExecutorSettings in the early preview.
    // Engine logs confirm this with `max_num_images: 0` baked in at create.
    //
    // Until upstream adds the Vision/Audio executor setters to the JS API,
    // setting `visionModalityEnabled`/`audioModalityEnabled: true` in
    // SessionConfig throws "Audio options should not be null" / "Vision
    // options should not be null" — so we force-disable them and warn.
    if (enableVisionModality == true || enableAudioModality == true) {
      if (kDebugMode) {
        edgeAiLog(
          '[LiteRtLmWebInferenceModel] Warning: vision/audio modality '
          'is requested but @litert-lm/core@0.17.1 does not expose the '
          'Vision/AudioExecutor config in its TypeScript API — image/audio '
          'inputs are dropped on web until upstream extends EngineSettings. '
          'Track: https://github.com/google-ai-edge/LiteRT-LM',
        );
      }
    }
    const visionEnabled = false;
    const audioEnabled = false;

    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<InferenceModelSession>();
    final sessionSw = Stopwatch()..start();

    try {
      final conversation = await _buildConversation(
        sampling: SamplingParams(
          temperature: temperature,
          topK: topK,
          topP: topP,
          randomSeed: randomSeed,
        ),
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
        sw: sessionSw,
      );

      final session = _session = LiteRtLmWebSession(
        conversation: conversation,
        modelType: modelType,
        fileType: fileType,
        supportImage: visionEnabled,
        supportAudio: audioEnabled,
        generationMutex: generationMutex,
        onClose: () {
          _session = null;
          _createCompleter = null;
        },
      );

      completer.complete(session);
      if (kDebugMode) {
        edgeAiLog(
          '[LiteRtLmWebInferenceModel/perf] createSession total: ${sessionSw.elapsedMilliseconds}ms',
        );
      }
      return session;
    } catch (e, st) {
      completer.completeError(e, st);
      _createCompleter = null;
      rethrow;
    }
  }

  @override
  Future<InferenceModelSession> openSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<Tool> tools = const [],
    int? maxOutputTokens,
  }) async {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    if (loraPath != null) {
      throw UnsupportedError(
        'LoRA weights are not supported on the .litertlm web path. '
        'Remove loraPath or use a MediaPipe .task web model.',
      );
    }
    final cap = maxConcurrentSessions;
    if (cap != null && _openSessions.length >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one.',
      );
    }
    // Vision/audio still blocked upstream (@litert-lm/core@0.17.1) — see the
    // detailed comment in createSession. Force-disable here too.
    if ((enableVisionModality == true || enableAudioModality == true) &&
        kDebugMode) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel] Warning: vision/audio modality '
        'is dropped on the web .litertlm path until upstream extends '
        'EngineSettings.',
      );
    }

    await _ensureEngine();
    final conversation = await _buildConversation(
      sampling: SamplingParams(
        temperature: temperature,
        topK: topK,
        topP: topP,
        randomSeed: randomSeed,
      ),
      systemInstruction: systemInstruction,
      enableThinking: enableThinking,
      tools: tools,
      maxOutputTokens: maxOutputTokens,
      sw: Stopwatch()..start(),
    );

    late final LiteRtLmWebSession session;
    session = LiteRtLmWebSession(
      conversation: conversation,
      modelType: modelType,
      fileType: fileType,
      supportImage: false,
      supportAudio: false,
      generationMutex: generationMutex,
      onClose: () => _openSessions.remove(session),
    );
    _openSessions.add(session);
    return session;
  }

  /// Builds an `@litert-lm/core` Conversation from sampler + preface config.
  /// Shared by [createSession] (legacy singleton) and [openSession]
  /// (detached) so the JS interop and tool/thinking wiring stay in one place.
  Future<LiteRtLmConversation> _buildConversation({
    required SamplingParams sampling,
    String? systemInstruction,
    required bool enableThinking,
    required List<Tool> tools,
    required Stopwatch sw,
    int? maxOutputTokens,
  }) async {
    await _ensureEngine();

    // Build SessionConfig matching upstream TS:
    //   { samplerParams?, maxOutputTokens? }
    // Vision/audio modality intentionally not set — they require
    // AudioExecutor/VisionExecutor at Engine.create() which the TS
    // EngineSettings doesn't expose yet.
    //
    // `maxOutputTokens` has been in `SessionConfig` since at least 0.14.0 — the
    // web path was simply never wired to set it, and logged that it ignored the
    // argument. Nothing upstream was blocking it. Upstream counts thinking
    // tokens against the same budget on models that emit them, matching the
    // native FFI behaviour.
    //
    // The sampler goes with an explicit `type`. Without one the config stays
    // TYPE_UNSPECIFIED and the engine replaces the whole sampler with the
    // bundle's, or with greedy when the bundle has none, so the values below
    // were silently ignored. The web API cannot read a bundle's sampler, so an
    // unset field comes from the family defaults; the models published for
    // web (Gemma 4, Gemma 3n) ship no sampler of their own.
    final resolved = SamplingParams.resolve(
      sampling,
      modelType: modelType,
      thinking: enableThinking,
    );
    final sessionConfigMap = <String, Object>{
      'samplerParams': <String, Object>{
        'type': _samplerTypeTopP,
        'temperature': resolved.temperature,
        'k': resolved.topK,
        'p': resolved.topP,
        'seed': resolved.randomSeed,
      },
      if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
    };
    final sessionConfigJs = sessionConfigMap.jsify() as JSObject?;

    // Build Preface matching upstream TS:
    //   { messages?: Message[], tools?: Tool[], extra_context?: {...} }
    final prefaceMessages = <Map<String, Object>>[];
    if (systemInstruction != null && systemInstruction.isNotEmpty) {
      prefaceMessages.add(<String, Object>{
        'role': 'system',
        'content': systemInstruction,
      });
    }
    // Tools — for the models whose tool calling LiteRT-LM runs natively (Gemma
    // 4, and FunctionGemma), the same predicate as the native FFI path in
    // `FfiInferenceModel`. Reuses [SdkResponseParser.serializeToolsForSdk] so
    // the JSON shape is byte-identical between web and native.
    final toolsForPreface =
        tools.isNotEmpty &&
            FunctionCallParser.usesSdkPassthrough(modelType, fileType: fileType)
        ? (jsonDecode(SdkResponseParser.serializeToolsForSdk(tools))
              as List<dynamic>)
        : const <dynamic>[];
    final prefaceMap = <String, Object>{
      if (prefaceMessages.isNotEmpty) 'messages': prefaceMessages,
      if (toolsForPreface.isNotEmpty) 'tools': toolsForPreface,
      // The key the templates read, sent both ways — see [thinkingContext].
      'extra_context': thinkingContext(enableThinking),
    };
    final prefaceJs = prefaceMap.isNotEmpty
        ? prefaceMap.jsify() as JSObject
        : null;

    final beforeConv = sw.elapsedMilliseconds;
    final convoFuture = _engine!.createConversation(
      LiteRtLmConversationOptions(
        sessionConfig: sessionConfigJs,
        preface: prefaceJs,
        filterChannelContentFromKvCache: enableThinking ? true : null,
        // Deliberately NOT enabled, unlike the FFI path. Upstream
        // google-ai-edge/LiteRT-LM#2434: with constrained decoding on, the WASM
        // grammar does not return to its start state after a completed
        // `<|tool_call>...<tool_call|>` block, so the NEXT decode round in that
        // conversation aborts with `Invalid token at state N` no matter what it
        // contains. That kills every multi-turn tool flow — including the agent
        // loop's call -> result -> continue, which cannot avoid that round.
        //
        // Measured on 0.17.0, seven cases in
        // `example/integration_test/web_function_calling_test.dart`: with the
        // flag off all pass, including the negative control (a non-action prompt
        // still calls nothing) and the round-trip. Gemma 4 emits well-formed
        // tool-call blocks without the grammar, and `SdkResponseParser` keeps its
        // raw-token fallback for the case where it does not. With the flag on,
        // any turn following a tool call fails.
        //
        // Native keeps it on: the C++ grammar resets correctly and is
        // unaffected. Re-enable here once #2434 is fixed upstream.
        enableConstrainedDecoding: null,
      ),
    );
    final conversation = await convoFuture.toDart;
    if (kDebugMode) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel/perf] createConversation: ${sw.elapsedMilliseconds - beforeConv}ms',
      );
    }
    return conversation;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      await _session?.close();
      for (final s in _openSessions.toList()) {
        await s.close();
      }
      _openSessions.clear();
    } finally {
      try {
        _engine?.delete();
      } catch (e) {
        if (kDebugMode) {
          edgeAiLog('[LiteRtLmWebInferenceModel] engine.delete() failed: $e');
        }
      }
      _engine = null;
      onClose();
      fireCloseListeners();
    }
  }
}

/// Session-side accumulator + async iterator pump for `@litert-lm/core`.
///
/// Mirrors [FfiInferenceModelSession] (lib/core/ffi/ffi_inference_model.dart)
/// 1:1 — same buffering of query chunks, same Gemma 4 raw-JSON-accumulating
/// branch, same `with RawSdkResponseSession` mixin so [InferenceChat] reads
/// `lastRawResponse` and extracts `tool_calls` via the shared
/// [SdkResponseParser]. The only platform-specific bit is that here the JS
/// AsyncIterator is driven manually via [LiteRtLmAsyncIter.next] rather than
/// a Dart `Stream` from native FFI.
class LiteRtLmWebSession extends InferenceModelSession
    with RawSdkResponseSession {
  LiteRtLmWebSession({
    required this.conversation,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this.supportAudio,
    required this.generationMutex,
    required this.onClose,
  });

  final LiteRtLmConversation conversation;
  final ModelType modelType;
  final ModelFileType fileType;
  final bool supportImage;
  final bool supportAudio;

  /// Shared across all sessions of the owning model — serializes generation
  /// (concurrent contexts, serialized inference). Acquired for the whole
  /// duration of a getResponse(Async) call.
  final Mutex generationMutex;
  final VoidCallback onClose;

  final StringBuffer _queryBuffer = StringBuffer();
  final List<Uint8List> _pendingImages = [];
  Uint8List? _pendingAudio;
  bool _isClosed = false;
  bool _isCancelled = false;

  /// Whether LiteRT-LM runs this model's tool calling natively (Gemma 4, and
  /// FunctionGemma); see [FunctionCallParser.usesSdkPassthrough].
  late final bool _nativeTools = FunctionCallParser.usesSdkPassthrough(
    modelType,
    fileType: fileType,
  );

  /// Tool results staged since the last generation, for [_nativeTools] models.
  final List<({String name, Object? response})> _pendingToolResponses = [];

  /// Whether anything other than a tool result was staged for this turn.
  bool _stagedNonToolContent = false;

  /// Last full raw JSON response from SDK — native tool models only.
  /// chat.dart reads it via [lastRawResponse] and runs
  /// [SdkResponseParser.extractToolCalls] on it before falling back to text
  /// extraction. Mirrors [FfiInferenceModelSession._lastRawResponse].
  String? _lastRawResponse;

  @override
  String? get lastRawResponse => _lastRawResponse;

  /// JS `JSON.stringify` handle, looked up once per session.
  late final JSObject _jsJson = globalContext.getProperty<JSObject>(
    'JSON'.toJS,
  );

  String _stringifyChunk(JSObject value) =>
      _jsJson.callMethod<JSString>('stringify'.toJS, value).toDart;

  void _assertNotClosed() {
    if (_isClosed) throw StateError('Session is closed');
  }

  @override
  Future<void> addQueryChunk(Message message) async {
    _assertNotClosed();
    final prompt = message.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    _queryBuffer.write(prompt);
    if (_nativeTools && message.type == MessageType.toolResponse) {
      final name = message.toolName;
      if (name == null) {
        throw ArgumentError.value(
          message,
          'message',
          'A tool response needs toolName: the runtime formats the result as '
              'response:NAME{...}, and without a name it answers no call',
        );
      }
      _pendingToolResponses.add((
        name: name,
        response: SdkResponseParser.toolResponsePayload(message.text),
      ));
    } else if (prompt.isNotEmpty || message.hasImage || message.hasAudio) {
      _stagedNonToolContent = true;
    }
    if (message.hasImage && supportImage) {
      if (message.imageBytes != null) {
        _pendingImages.add(message.imageBytes!);
      }
      for (final image in message.images) {
        if (!_pendingImages.contains(image)) {
          _pendingImages.add(image);
        }
      }
    }
    if (message.hasAudio && message.audioBytes != null && supportAudio) {
      _pendingAudio = message.audioBytes;
    }
  }

  /// The staged tool results as one role-`tool` message, when they are the
  /// whole turn; mirrors `FfiInferenceModelSession`. A turn that also carries
  /// user text or media is a user message, and the results stay in its text.
  String? _takeToolResponseMessage() {
    final onlyTools =
        _pendingToolResponses.isNotEmpty && !_stagedNonToolContent;
    final message = onlyTools
        ? SdkResponseParser.buildToolResponsesJson(_pendingToolResponses)
        : null;
    _pendingToolResponses.clear();
    _stagedNonToolContent = false;
    return message;
  }

  @override
  Future<String> getResponse() async {
    _assertNotClosed();
    final buf = StringBuffer();
    await for (final chunk in getResponseAsync()) {
      buf.write(chunk);
    }
    return buf.toString();
  }

  @override
  Stream<String> getResponseAsync() {
    _assertNotClosed();
    final text = _queryBuffer.toString();
    _queryBuffer.clear();
    final images = _pendingImages.isNotEmpty
        ? List<Uint8List>.from(_pendingImages)
        : null;
    final audio = _pendingAudio;
    _pendingImages.clear();
    _pendingAudio = null;
    _isCancelled = false;
    final toolMessage = _takeToolResponseMessage();

    final controller = StreamController<String>();
    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;

    // Serialize generation across all sessions of this model. Acquired before
    // the pump starts (in onListen) and released exactly once in every
    // terminal path (done / error / consumer cancel) so an abandoned stream
    // can't hold the lock forever.
    var mutexHeld = false;
    var released = false;
    void releaseMutex() {
      if (released) return;
      released = true;
      if (mutexHeld) generationMutex.release();
    }

    // Build the request payload:
    //  * pure text → pass a plain string (legacy fast path).
    //  * any image/audio → build a Message object with a `content` array of
    //    MessageContentItem (one text + N image/audio items), shaped per the
    //    upstream TS declarations.
    final JSAny messageArg;
    if (toolMessage != null) {
      // Tool results go back as one role-`tool` message, the only shape after
      // which the template continues the model's own turn.
      messageArg =
          (jsonDecode(toolMessage) as Map<String, Object?>).jsify() as JSAny;
    } else if ((images == null || images.isEmpty) && audio == null) {
      messageArg = text.toJS;
    } else {
      final contentItems = <Map<String, Object>>[
        if (text.isNotEmpty) <String, Object>{'type': 'text', 'text': text},
        if (images != null)
          for (final img in images)
            <String, Object>{
              'type': 'image',
              // Data URL is the broadest-compatible shape; upstream `path` can
              // also be a Blob URL or a file URL once we wire those.
              'image_url': <String, Object>{
                // Reuse the shared magic-number detector promoted to the public
                // detectImageMimeType util (PNG / JPEG / WebP).
                'url':
                    'data:${detectImageMimeType(img)};base64,${base64Encode(img)}',
              },
            },
        if (audio != null)
          <String, Object>{
            'type': 'audio',
            // Audio payload (PCM 16kHz mono) per the native FFI contract.
            'input_audio': <String, Object>{
              'data': base64Encode(audio),
              'format': 'wav',
            },
          },
      ];
      messageArg =
          <String, Object>{'role': 'user', 'content': contentItems}.jsify()
              as JSAny;
    }
    // Native tool models mirror FfiInferenceModelSession.getResponseAsync —
    // every raw chunk is stringified and appended to rawBuffer so chat.dart
    // can run SdkResponseParser.extractToolCalls on the assembled JSON. Other
    // model types skip accumulation and `_lastRawResponse` stays null.
    final accumulateRaw = _nativeTools;
    final rawBuffer = accumulateRaw ? StringBuffer() : null;
    if (accumulateRaw) {
      _lastRawResponse = null;
    }

    void startPump() {
      final raw = conversation.sendMessageStreaming(messageArg);
      final asyncIterSym = globalContext
          .getProperty<JSObject>('Symbol'.toJS)
          .getProperty<JSAny>('asyncIterator'.toJS);
      final factory = raw.getProperty<JSFunction?>(asyncIterSym);
      final iter = factory != null
          ? raw.callMethod<JSObject>(asyncIterSym)
          : raw; // assume it's already an iterator

      void pump() {
        if (controller.isClosed || _isCancelled) {
          releaseMutex();
          if (!controller.isClosed) controller.close();
          return;
        }
        iter.next().toDart.then(
          (JSObject step) {
            if (controller.isClosed || _isCancelled) {
              releaseMutex();
              if (!controller.isClosed) controller.close();
              return;
            }
            final done = (step.getProperty<JSBoolean>('done'.toJS)).toDart;
            if (done) {
              if (accumulateRaw) {
                _lastRawResponse = rawBuffer!.toString();
              }
              if (kDebugMode) {
                final total = genSw.elapsedMilliseconds;
                edgeAiLog(
                  '[LiteRtLmWebSession/perf] generation total: ${total}ms '
                  '(prefill ${firstChunkMs ?? 0}ms, $chunkCount chunks)',
                );
              }
              releaseMutex();
              controller.close();
              return;
            }
            if (firstChunkMs == null) {
              firstChunkMs = genSw.elapsedMilliseconds;
              if (kDebugMode) {
                edgeAiLog(
                  '[LiteRtLmWebSession/perf] time-to-first-chunk: ${firstChunkMs}ms',
                );
              }
            }
            chunkCount++;
            final value = step.getProperty<JSObject?>('value'.toJS);
            if (value != null) {
              // Stringify the JS chunk into the same JSON shape liblitert_lm
              // streams via the native FFI callback. Both engines then dump it
              // into the shared SdkTextExtractor — single source of truth for
              // text-vs-thinking extraction, identical to ffi_inference_model.dart.
              final jsonStr = _stringifyChunk(value);
              if (accumulateRaw) {
                rawBuffer!.write(jsonStr);
              }
              try {
                final text = SdkTextExtractor.extractTextFromResponse(jsonStr);
                if (text.isNotEmpty) controller.add(text);
              } catch (e, st) {
                releaseMutex();
                if (!controller.isClosed) {
                  controller.addError(e, st);
                  controller.close();
                }
                return;
              }
            }
            pump();
          },
          onError: (Object error, StackTrace st) {
            releaseMutex();
            if (!controller.isClosed) {
              controller.addError(error, st);
              controller.close();
            }
          },
        );
      }

      pump();
    }

    // Acquire the model-wide generation mutex before kicking off generation,
    // so concurrent sessions take turns (serialized inference). Released in
    // every terminal path (done / error / cancel) via releaseMutex().
    controller.onListen = () async {
      try {
        await generationMutex.acquire();
        mutexHeld = true;
        if (_isCancelled || controller.isClosed) {
          releaseMutex();
          if (!controller.isClosed) await controller.close();
          return;
        }
        startPump();
      } catch (e, st) {
        releaseMutex();
        if (!controller.isClosed) {
          controller.addError(e, st);
          await controller.close();
        }
      }
    };
    controller.onCancel = () {
      _isCancelled = true;
      releaseMutex();
    };
    return controller.stream;
  }

  /// Approximate token count. `@litert-lm/core` (early preview) exposes no
  /// tokenizer, so unlike the FFI arm — which now asks the model's own — this
  /// can only estimate.
  ///
  /// Two characters per token, not four, for the same reason the FFI arm's
  /// fallback uses it: undercounting overruns the native KV cache, while
  /// overcounting only trims history early. Four was measured at 0.44x on
  /// Chinese against gemma-4-E2B-it, i.e. wrong in the crash direction.
  @override
  Future<int> sizeInTokens(String text) async => (text.length / 2).ceil();

  /// Stops the in-flight generation both locally (closes the Dart stream)
  /// and upstream (calls `conversation.cancel()` per the @litert-lm/core JS
  /// API). The cancel call is wrapped in try/catch because the early-preview
  /// API may throw if no generation is in flight.
  @override
  Future<void> stopGeneration() async {
    _isCancelled = true;
    try {
      conversation.cancel();
    } catch (e) {
      if (kDebugMode) {
        edgeAiLog('[LiteRtLmWebSession] conversation.cancel() threw: $e');
      }
    }
  }

  /// LiteRT-LM web does not surface benchmark info; return empty metrics.
  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {
    _isClosed = true;
    _isCancelled = true;
    // Abort any in-flight JS generation BEFORE the model tears the engine
    // down. Without this, the model's close() → engine.delete() can free the
    // WASM/WebGPU state while a pending iter.next() Promise is still resolving
    // against this conversation (use-after-free). stopGeneration() does the
    // same; close() must too.
    try {
      conversation.cancel();
    } catch (e) {
      if (kDebugMode) {
        edgeAiLog('[LiteRtLmWebSession] cancel during close threw: $e');
      }
    }
    _queryBuffer.clear();
    onClose();
  }
}
