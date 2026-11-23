// Core's InferenceModel and InferenceModelSession on the web, over
// litertlm_dart's web `Engine` and `Conversation` (`@litert-lm/core` in the
// page): what [FfiInferenceModel] is natively. The runtime — the JS interop,
// the stream pump, the page lock, the sampler latch — is litertlm_dart's
// (`src/web/`); this file keeps what core sees: the session cap, the LoRA and
// media refusals, tool results staged as one role-`tool` message, the reply's
// raw JSON for core's tool-call parser, the model-wide generation lock and how
// a turn ended.
//
// No dart:js_interop: the engine arrives as a [WebLlmEngine]
// (web/web_llm_engine.dart over litertlm_dart's web `Engine`, a fake in the VM
// tests).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:litertlm_dart/internal.dart'
    show liteRtLmWebRuntime, messageJson, messageRawJson;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;
import 'package:mutex/mutex.dart';

import '../reported_engine_turn.dart';
import 'core_hints.dart';
import 'turn_errors.dart';
import 'user_message.dart';

/// What the web model needs of a loaded engine: conversations with the
/// adapter's resolved sampler, and the engine's close.
abstract interface class WebLlmEngine {
  /// A conversation of [config], with [defaultSamplerConfig] as the model's
  /// own sampler when [config] sets none.
  Future<lm.Conversation> openConversation(
    lm.ConversationConfig config,
    lm.SamplerConfig? defaultSamplerConfig,
  );

  /// Closes every conversation and deletes the engine.
  Future<void> close();
}

/// Web `.litertlm` inference over litertlm_dart's web engine
/// ([liteRtLmWebRuntime] on WebGPU).
///
/// **Limitations:**
/// - Images and audio with `supportImage`/`supportAudio` (the vision encoder
///   on the GPU, the audio encoder on the CPU); without them an image or
///   audio message throws [UnsupportedError] from
///   [LiteRtLmWebSession.addQueryChunk]. `maxNumImages` counts a whole
///   conversation's images on the web.
/// - Thinking reaches the model as `extra_context` with an explicit
///   `enable_thinking` (litertlm_dart's `thinkingContext`), the key the chat
///   templates read — measured on Gemma 4 E2B in Chrome
///   (`web_thinking_test.dart`).
/// - LoRA throws [UnsupportedError] (parity with FFI path).
/// - `stopGeneration()` closes the local stream and stops the runtime's
///   generation (`conversation.cancel()`).
/// - For models >2 GB use `WebStorageMode.streaming`: the engine then reads
///   the model as a stream from OPFS, as a `blob:` URL fetch trips Chrome's
///   `ERR_BLOB_OUT_OF_MEMORY` limit.
class LiteRtLmWebInferenceModel extends InferenceModel with CloseNotifier {
  LiteRtLmWebInferenceModel({
    required this.createEngine,
    required this.maxTokens,
    required this.modelType,
    this.fileType = ModelFileType.litertlm,
    this.maxConcurrentSessions,
    this.supportImage = false,
    this.supportAudio = false,
    MultimodalOrder? multimodalOrder,
    required this.onClose,
  }) : multimodalOrder =
           multimodalOrder ?? MultimodalOrder.forModelType(modelType);

  /// The engine loads a vision, an audio encoder (core's `supportImage`,
  /// `supportAudio`); a session sends images or audio only then.
  final bool supportImage;
  final bool supportAudio;

  /// Where a message's images and audio go around its text.
  final MultimodalOrder multimodalOrder;

  /// Loads the engine, at the first session: the active model's source
  /// resolved by core and handed to litertlm_dart (web/web_llm_engine.dart).
  final Future<WebLlmEngine> Function() createEngine;
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

  WebLlmEngine? _engine;
  LiteRtLmWebSession? _session;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  @override
  StructuredOutputSupport get engineStructuredOutputSupport =>
      const StructuredOutputSupport.none(
        'LiteRT-LM web uses $liteRtLmWebRuntime, whose conversation API has '
        'no constrained-decoding option.',
      );

  /// Guards [_ensureEngine] against concurrent calls. Without it, two
  /// overlapping openSession/createSession calls both see `_engine == null`
  /// and both create an engine, leaking the first (JS/WASM + GPU resources)
  /// for the page lifetime.
  Completer<void>? _engineCompleter;

  /// Serializes generation across all sessions on this model — concurrent
  /// contexts, serialized inference, matching the FFI/MediaPipe paths. The
  /// engine is shared WebGPU/WASM state; parallel generations would contend
  /// for the accelerator. Passed to each session.
  final Mutex generationMutex = Mutex();

  /// Sessions opened via [openSession] — detached from the legacy [_session]
  /// singleton. Each owns its own conversation.
  final Set<LiteRtLmWebSession> _openSessions = {};

  @override
  InferenceModelSession? get session => _session;

  /// Open sessions still being built: they count against
  /// [maxConcurrentSessions] from the check on, so two calls that overlap
  /// cannot both pass it.
  int _openingSessions = 0;

  @override
  List<InferenceModelSession> get engineSessions => [
    ?_session,
    ..._openSessions,
  ];

  /// [body], its error with the line in core's terms ([withCoreHintError]).
  static Future<T> _withCoreHint<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      final hinted = withCoreHintError(e);
      if (identical(hinted, e)) rethrow;
      Error.throwWithStackTrace(hinted, st);
    }
  }

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
      _engine = await _withCoreHint(createEngine);
      completer.complete();
    } catch (e, st) {
      _engineCompleter = null; // allow retry
      // Only a concurrent caller or a close listens to it; this one rethrows.
      completer.future.ignore();
      completer.completeError(e, st);
      rethrow;
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
    // Resolved before anything loads: values it rejects must not load the
    // engine.
    final explicit = SamplingParams(
      temperature: temperature,
      topK: topK,
      topP: topP,
      randomSeed: randomSeed,
    );
    final sampling = _resolveSampling(explicit, thinking: enableThinking);

    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<InferenceModelSession>();
    final sessionSw = Stopwatch()..start();

    try {
      await _ensureEngine();
      final conversation = await _buildConversation(
        explicit: explicit,
        sampling: sampling,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
      );
      // Closed while the engine or the conversation was being created: the
      // model has closed (or is closing) its engine.
      if (_isClosed) {
        await conversation.close();
        throw StateError('Model was closed while creating a session');
      }

      final session = _session = LiteRtLmWebSession(
        conversation: conversation,
        modelType: modelType,
        fileType: fileType,
        generationMutex: generationMutex,
        maxOutputTokens: maxOutputTokens,
        supportImage: enableVisionModality ?? supportImage,
        supportAudio: enableAudioModality ?? supportAudio,
        multimodalOrder: multimodalOrder,
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
      // Only a concurrent caller listens to it; this one rethrows.
      completer.future.ignore();
      completer.completeError(e, st);
      _createCompleter = null;
      rethrow;
    }
  }

  @override
  Future<InferenceModelSession> openEngineSession(
    SessionRequest request,
  ) async {
    final SessionRequest(
      :temperature,
      :randomSeed,
      :topK,
      :topP,
      :loraPath,
      :enableVisionModality,
      :enableAudioModality,
      :systemInstruction,
      :enableThinking,
      :tools,
      :maxOutputTokens,
    ) = request;
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
    if (cap != null && _openSessions.length + _openingSessions >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one.',
      );
    }

    // Resolved before anything loads: values it rejects must not load the
    // engine.
    final explicit = SamplingParams(
      temperature: temperature,
      topK: topK,
      topP: topP,
      randomSeed: randomSeed,
    );
    final sampling = _resolveSampling(explicit, thinking: enableThinking);
    // Counted from the cap check until the session is in [_openSessions]:
    // the awaits below would otherwise let a second call pass the check.
    _openingSessions++;
    final lm.Conversation conversation;
    try {
      await _ensureEngine();
      conversation = await _buildConversation(
        explicit: explicit,
        sampling: sampling,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
      );
    } finally {
      _openingSessions--;
    }
    // Closed while the engine or the conversation was being created: the
    // model has closed (or is closing) its engine.
    if (_isClosed) {
      await conversation.close();
      throw StateError('Model was closed while opening a session');
    }

    late final LiteRtLmWebSession session;
    session = LiteRtLmWebSession(
      conversation: conversation,
      modelType: modelType,
      fileType: fileType,
      generationMutex: generationMutex,
      maxOutputTokens: maxOutputTokens,
      supportImage: enableVisionModality ?? supportImage,
      supportAudio: enableAudioModality ?? supportAudio,
      multimodalOrder: multimodalOrder,
      onClose: () => _openSessions.remove(session),
    );
    _openSessions.add(session);
    return session;
  }

  /// The web runtime cannot read a bundle's sampler, so an unset field comes
  /// from the family defaults; the models published for web (Gemma 4, Gemma
  /// 3n) ship no sampler of their own. Throws an [ArgumentError] for a value
  /// no engine can sample with.
  ResolvedSampling _resolveSampling(
    SamplingParams explicit, {
    required bool thinking,
  }) => SamplingParams.resolve(
    explicit,
    modelType: modelType,
    thinking: thinking,
  );

  /// A conversation for a session. The resolved sampling is the caller's
  /// choice when [explicit] sets any of it, else the model's default, which
  /// never counts as the caller's for LiteRT-LM#2080's warning. Tools go to
  /// the runtime only for the models whose tool calling LiteRT-LM runs
  /// natively (Gemma 4, FunctionGemma), the same predicate as the native path
  /// and as core's chat, so the declarations are rendered exactly once.
  Future<lm.Conversation> _buildConversation({
    required SamplingParams explicit,
    required ResolvedSampling sampling,
    String? systemInstruction,
    required bool enableThinking,
    required List<Tool> tools,
    int? maxOutputTokens,
  }) {
    final sampler = lm.SamplerConfig(
      topK: sampling.topK,
      topP: sampling.topP,
      temperature: sampling.temperature,
      seed: sampling.randomSeed,
    );
    final nativeTools =
        tools.isNotEmpty &&
        FunctionCallParser.usesSdkPassthrough(modelType, fileType: fileType);
    return _engine!.openConversation(
      lm.ConversationConfig(
        systemInstruction: systemInstruction,
        tools: [
          if (nativeTools)
            for (final tool in tools)
              lm.Tool(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters,
              ),
        ],
        samplerConfig: explicit.isEmpty ? null : sampler,
        maxOutputTokens: maxOutputTokens,
        thinkingConfig: lm.ThinkingConfig(enableThinking: enableThinking),
      ),
      explicit.isEmpty ? sampler : null,
    );
  }

  /// The teardown in progress, shared by every caller of [close]: a second
  /// call waits for it instead of returning at once, so core can tell when
  /// the model is really gone before it builds the next one.
  Future<void>? _closeFuture;

  @override
  Future<void> close() {
    final teardown = _closeFuture;
    if (teardown != null) return teardown;
    final settled = Completer<void>();
    _closeFuture = settled.future;
    // The first caller gets the teardown's own outcome; every later caller
    // gets `settled`, which completes normally once the teardown has ended.
    return _close().whenComplete(settled.complete);
  }

  Future<void> _close() async {
    _isClosed = true;
    // An engine still loading is closed with the rest, once it has loaded:
    // nobody else would close it.
    if (_engineCompleter case final loading? when !loading.isCompleted) {
      try {
        await loading.future;
      } catch (_) {
        // A failed load left no engine to close.
      }
    }
    try {
      await _session?.close();
      for (final s in _openSessions.toList()) {
        await s.close();
      }
      _openSessions.clear();
    } finally {
      try {
        await _engine?.close();
      } catch (e) {
        // Release builds see it: the engine's memory may stay in the page.
        // ignore: avoid_print
        print(
          '[flutter_edge_ai_litertlm] WARNING: closing the web engine failed: $e',
        );
      }
      _engine = null;
      onClose();
      fireCloseListeners();
    }
  }
}

/// A session over one [lm.Conversation]: core's staging of query chunks, the
/// raw reply JSON native tool models leave for core's parser, the model-wide
/// generation lock and the turn's end. Mirrors `FfiInferenceModelSession`.
class LiteRtLmWebSession extends InferenceModelSession
    with RawSdkResponseSession {
  LiteRtLmWebSession({
    required this.conversation,
    required this.modelType,
    required this.fileType,
    required this.generationMutex,
    required this.onClose,
    this.maxOutputTokens,
    this.supportImage = false,
    this.supportAudio = false,
    this.multimodalOrder = const MultimodalOrder(),
  });

  /// This session sends images, audio: its engine loaded that encoder.
  final bool supportImage;
  final bool supportAudio;

  /// Where a message's images and audio go around its text.
  final MultimodalOrder multimodalOrder;

  final List<Uint8List> _pendingImages = [];
  Uint8List? _pendingAudio;

  final lm.Conversation conversation;
  final ModelType modelType;
  final ModelFileType fileType;

  /// Shared across all sessions of the owning model — serializes generation
  /// (concurrent contexts, serialized inference). Held for the whole of a
  /// getResponse(Async) call.
  final Mutex generationMutex;
  final VoidCallback onClose;

  /// The cap on each reply, which decides what a completed turn reports.
  final int? maxOutputTokens;

  /// [stopGeneration] was called during the current turn.
  bool _stopAsked = false;

  final StringBuffer _queryBuffer = StringBuffer();
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
  /// extraction.
  String? _lastRawResponse;

  @override
  String? get lastRawResponse => _lastRawResponse;

  void _assertNotClosed() {
    if (_isClosed) throw StateError('Session is closed');
  }

  /// The error for an image or audio message a session cannot send: its
  /// engine loaded no such encoder. Dropping the bytes instead would let the
  /// model answer about media it never received.
  static UnsupportedError _unsupportedMedia(Message message) {
    final kinds = [
      if (message.hasImage) 'image',
      if (message.hasAudio) 'audio',
    ].join(' and ');
    return UnsupportedError(
      'This web .litertlm model was loaded without $kinds input: load it with '
      '${[if (message.hasImage) 'supportImage: true', if (message.hasAudio) 'supportAudio: true'].join(' and ')} '
      'to send it.',
    );
  }

  /// Stages [message] for the next generation. Throws [UnsupportedError] for
  /// a message with an image or audio, before anything is staged, so the
  /// rejected message leaves the next turn unchanged.
  @override
  Future<void> addQueryChunk(Message message) async {
    _assertNotClosed();
    if ((message.hasImage && !supportImage) ||
        (message.hasAudio && !supportAudio)) {
      throw _unsupportedMedia(message);
    }
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
    // As natively: a message's images are [Message.images] when it has any,
    // else its [Message.imageBytes] (the factories set both to one photo).
    if (message.hasImage) {
      if (message.images.isNotEmpty) {
        _pendingImages.addAll(message.images);
      } else if (message.imageBytes case final image?) {
        _pendingImages.add(image);
      }
    }
    if (message.audioBytes case final audio? when message.hasAudio) {
      _pendingAudio = audio;
    }
  }

  /// The turn's message: the staged tool results as one role-`tool` message
  /// when they are the whole turn (the only shape after which the template
  /// continues the model's own turn), else the staged text as a user message.
  /// A turn that also carries user text is a user message, and the results
  /// stay in its text.
  lm.Message _takeTurnMessage(String text) {
    final onlyTools =
        _pendingToolResponses.isNotEmpty && !_stagedNonToolContent;
    final message = onlyTools
        ? lm.Message.tool([
            for (final r in _pendingToolResponses)
              lm.Content.toolResponse(r.name, r.response),
          ])
        : liteRtLmUserMessage(
            text,
            images: List.of(_pendingImages),
            audio: _pendingAudio,
            order: multimodalOrder,
          );
    _pendingImages.clear();
    _pendingAudio = null;
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
    final message = _takeTurnMessage(_queryBuffer.toString());
    _queryBuffer.clear();
    _isCancelled = false;

    final controller = StreamController<String>();
    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;

    // Serialize generation across all sessions of this model. Acquired before
    // the turn starts (in onListen) and released exactly once in every
    // terminal path (done / error / stop / consumer cancel) so an abandoned
    // stream can't hold the lock forever. The runtime holds the page until
    // the turn has really ended; the next message waits for that there.
    var mutexHeld = false;
    var released = false;
    void releaseMutex() {
      if (released) return;
      released = true;
      if (mutexHeld) generationMutex.release();
    }

    // Native tool models mirror FfiInferenceModelSession.getResponseAsync —
    // every raw chunk is appended so chat.dart can run
    // SdkResponseParser.extractToolCalls on the assembled JSON. Other model
    // types skip accumulation and `_lastRawResponse` stays null.
    final accumulateRaw = _nativeTools;
    final rawBuffer = accumulateRaw ? StringBuffer() : null;
    if (accumulateRaw) {
      _lastRawResponse = null;
    }

    StreamSubscription<lm.Message>? turn;
    // Ends this reply now and lets the conversation wind the turn down: a
    // stop or a consumer that left.
    void letGo() {
      releaseMutex();
      if (!controller.isClosed) controller.close();
      final sub = turn;
      turn = null;
      // The conversation winds the turn down on its own.
      if (sub != null) unawaited(sub.cancel());
    }

    controller.onListen = () async {
      try {
        await generationMutex.acquire();
        mutexHeld = true;
        if (_isCancelled || controller.isClosed) {
          letGo();
          return;
        }
        turn = conversation
            .sendMessageStream(message)
            .listen(
              (piece) {
                if (controller.isClosed) return;
                if (_isCancelled) {
                  letGo();
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
                // The chunk's JSON as the runtime streamed it, the shape
                // liblitert_lm streams natively: both engines then read it
                // with the shared SdkTextExtractor.
                final json =
                    messageRawJson(piece) ?? jsonEncode(messageJson(piece));
                rawBuffer?.write(json);
                try {
                  final text = SdkTextExtractor.extractTextFromResponse(json);
                  if (text.isNotEmpty) controller.add(text);
                } catch (e, st) {
                  controller.addError(e, st);
                  letGo();
                }
              },
              onError: (Object error, StackTrace st) {
                turn = null;
                releaseMutex();
                if (controller.isClosed) return;
                // As natively: a close is LiteRtLmSessionClosedError, which
                // startTurn reads as TurnEnd.closed; a failure is what the
                // runtime threw, with its line in core's terms.
                controller.addError(coreTurnError(error), st);
                controller.close();
              },
              onDone: () {
                turn = null;
                if (!_isCancelled) {
                  if (accumulateRaw) {
                    _lastRawResponse = rawBuffer!.toString();
                  }
                  if (kDebugMode) {
                    edgeAiLog(
                      '[LiteRtLmWebSession/perf] generation total: '
                      '${genSw.elapsedMilliseconds}ms (prefill '
                      '${firstChunkMs ?? 0}ms, $chunkCount chunks)',
                    );
                  }
                }
                releaseMutex();
                if (!controller.isClosed) controller.close();
              },
            );
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
      letGo();
    };
    return controller.stream;
  }

  /// Approximate token count. `@litert-lm/core` exposes no tokenizer, so
  /// unlike the FFI arm — which asks the model's own — this can only
  /// estimate.
  ///
  /// Two characters per token, not four, for the same reason the FFI arm's
  /// fallback uses it: undercounting overruns the native KV cache, while
  /// overcounting only trims history early. Four was measured at 0.44x on
  /// Chinese against gemma-4-E2B-it, i.e. wrong in the crash direction.
  @override
  Future<int> sizeInTokens(String text) async => (text.length / 2).ceil();

  /// How the turn ended, for core's chat: a stop is [TurnEnd.stopped], a
  /// close the consumer did not ask for [TurnEnd.closed] (the chat keeps the
  /// partial reply, then raises: decision H). A completed turn reports
  /// [liteRtLmPlaceholderCompletedEnd], a guess.
  @override
  EngineTurn startTurn() {
    _stopAsked = false;
    return reportedEngineTurn(
      getResponseAsync(),
      stopped: () => _stopAsked,
      closed: () => _isClosed,
      isCloseError: (error) => error is LiteRtLmSessionClosedError,
      completed: () => liteRtLmPlaceholderCompletedEnd(maxOutputTokens),
    );
  }

  /// Stops the in-flight generation both locally (closes the Dart stream at
  /// its next chunk) and in the runtime (`conversation.cancel()`). A reply
  /// stopped before its end leaves the runtime conversation refusing every
  /// later send, so litertlm_dart sends the next message to one rebuilt from
  /// the history, the stopped reply's text kept.
  @override
  Future<void> stopGeneration() async {
    _stopAsked = true;
    _isCancelled = true;
    conversation.cancel();
  }

  /// LiteRT-LM web does not surface benchmark info; return empty metrics.
  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  /// Stops any generation in flight and waits for the runtime to have ended
  /// it (at most 30 s), so the owning model deletes its engine only after
  /// nothing is suspended inside the page's WebAssembly module any more. A
  /// second call returns the first one's future: it completes when the
  /// conversation has really closed.
  @override
  Future<void> close() => _closing ??= _close();

  Future<void>? _closing;

  Future<void> _close() async {
    _isClosed = true;
    _isCancelled = true;
    try {
      // Waits for the runtime to have ended the turn and freed the
      // conversation; fails when a stopped turn never ended (the page is then
      // unusable, and says so).
      await conversation.close();
    } finally {
      _queryBuffer.clear();
      onClose();
    }
  }
}
