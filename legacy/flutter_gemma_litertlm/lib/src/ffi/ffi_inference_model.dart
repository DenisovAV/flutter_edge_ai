import 'dart:async';
import 'dart:convert';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

import 'package:flutter/foundation.dart';

import 'package:flutter_gemma/flutter_gemma_interface.dart';
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';
import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/core/tool.dart';
import 'package:flutter_gemma/core/chat.dart';
import 'package:flutter_gemma/core/extensions.dart';
import 'package:flutter_gemma/core/function_call_parser.dart';
import 'package:flutter_gemma/core/parsing/sdk_response_parser.dart';
import 'litert_lm_client.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart';

/// FFI implementation of InferenceModel using dart:ffi → LiteRT-LM C API.
/// Shared between desktop and mobile (iOS) for .litertlm models.
class FfiInferenceModel extends InferenceModel with CloseNotifier {
  FfiInferenceModel({
    required this.ffiClient,
    required this.maxTokens,
    required this.modelType,
    required this.activeBackend,
    this.fileType = ModelFileType.litertlm,
    this.supportImage = false,
    this.supportAudio = false,
    this.maxConcurrentSessions,
    required this.onClose,
  });

  final LiteRtLmFfiClient ffiClient;
  final ModelType modelType;
  @override
  final ModelFileType fileType;
  @override
  final int maxTokens;
  @override
  final PreferredBackend? activeBackend;
  final bool supportImage;
  final bool supportAudio;

  /// Cap on concurrent [openSession] sessions; null = unlimited.
  final int? maxConcurrentSessions;
  final VoidCallback onClose;

  FfiInferenceModelSession? _session;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  /// Sessions opened via [openSession] — detached from the legacy [_session]
  /// singleton. Each owns its own conversation handle.
  final Set<FfiInferenceModelSession> _openSessions = {};

  @override
  InferenceModelSession? get session => _session;

  @override
  List<InferenceModelSession> get sessions =>
      List.unmodifiable([if (_session != null) _session!, ..._openSessions]);

  @override
  Future<InferenceModelSession> createSession({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
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
        'LoRA weights are not supported on the .litertlm FFI path '
        '(loraPath=$loraPath). Track upstream LiteRT-LM C API support; '
        'remove loraPath or use a MediaPipe .task model on Android/iOS.',
      );
    }

    // Single-flight guard for genuinely *concurrent* callers only. The
    // completer is cleared in the `finally` below once creation settles,
    // so a *sequential* second call falls through and opens a fresh
    // conversation handle (closing the prior session first) instead of
    // returning the cached session. Without this, the cached completer
    // made every later createChat reuse the first session, so the
    // previous conversation's KV cache bled into the next chat. This is
    // the litert/FFI sibling of the MediaPipe fix in #309 (issue #308).
    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }

    final completer = _createCompleter = Completer<InferenceModelSession>();
    final sessionSw = Stopwatch()..start();

    try {
      // Legacy singleton lane: close the previous conversation BEFORE
      // opening a fresh one. The engine holds at most one live
      // conversation (upstream litert-lm #966), so closing first never
      // leaves two alive — matching the delete-before-create order the
      // virtual-session multiplexer already uses. It also means a
      // teardown error can't leak a handle that was created first and
      // then left unwrapped: each session owns its own conversation
      // pointer, so closing the old one can't touch the not-yet-created
      // new one. See PR #310 review.
      await _session?.close();

      final toolsJson = _nativeToolsJson(tools);

      final beforeConv = sessionSw.elapsedMilliseconds;
      // Same config every time, so a conversation rebuilt after a stopped turn
      // is this one again, plus its history.
      Future<LiteRtLmConversationHandle> open({String? messagesJson}) =>
          ffiClient.createConversationHandle(
            systemMessage: systemInstruction,
            toolsJson: toolsJson,
            messagesJson: messagesJson,
            temperature: temperature,
            topK: topK,
            topP: topP,
            seed: randomSeed,
            maxOutputTokens: maxOutputTokens,
          );
      final handle = RecoveringConversationHandle(
        await open(),
        reopen: (messagesJson) => open(messagesJson: messagesJson),
      );
      gemmaLog(
        '[FfiInferenceModel/perf] createConversation (FFI): ${sessionSw.elapsedMilliseconds - beforeConv}ms',
      );

      // createConversationHandle now suspends across an isolate round trip, so
      // close() can have run while we were away. Without this the caller gets a
      // working-looking session whose conversation belongs to a dead engine.
      if (_isClosed) {
        handle.close();
        throw StateError('Model was closed while creating a session');
      }

      late final FfiInferenceModelSession session;
      session = FfiInferenceModelSession(
        handle: handle,
        modelType: modelType,
        fileType: fileType,
        supportImage: enableVisionModality ?? supportImage,
        supportAudio: enableAudioModality ?? supportAudio,
        enableThinking: enableThinking,
        // Identity-guarded so a late close of a superseded session can't
        // null a newer `_session`. Does NOT touch `_createCompleter` —
        // that is owned by the `finally` below, not by session teardown.
        onClose: () {
          if (identical(_session, session)) _session = null;
        },
      );
      _session = session;

      completer.complete(session);
      gemmaLog(
        '[FfiInferenceModel/perf] createSession total: ${sessionSw.elapsedMilliseconds}ms',
      );
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      // Pure in-flight guard: clear once creation settles (success OR
      // failure) so the next call isn't blocked by a cached completer
      // (the issue #308 KV-cache bleed on success; a permanently cached
      // rejected future on failure).
      _createCompleter = null;
    }
    // Return `completer.future` (rather than the session / a rethrow) so
    // the caller stays the error listener after the completer field is
    // cleared above, and concurrent callers share the same result.
    return completer.future;
  }

  @override
  Future<InferenceModelSession> openSession({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
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
        'LoRA weights are not supported on the .litertlm FFI path '
        '(loraPath=$loraPath). Remove loraPath or use a MediaPipe .task '
        'model on Android/iOS.',
      );
    }
    final cap = maxConcurrentSessions;
    if (cap != null && _openSessions.length >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one.',
      );
    }

    final toolsJson = _nativeToolsJson(tools);

    // The LiteRT-LM engine allows only ONE live conversation at a time
    // (upstream #966), so concurrent sessions can't each hold a real native
    // conversation. Each session instead gets a virtual handle that keeps its
    // history in Dart and replays it into the single shared conversation on
    // demand (serialized by the client mutex). Logically concurrent contexts,
    // serialized inference. openSession() itself makes no native call, so it
    // never fails on the one-conversation limit.
    final handle = _VirtualConversationHandle(
      client: ffiClient,
      systemMessage: systemInstruction,
      toolsJson: toolsJson,
      temperature: temperature,
      topK: topK,
      topP: topP,
      seed: randomSeed,
      maxOutputTokens: maxOutputTokens,
    );

    late final FfiInferenceModelSession session;
    session = FfiInferenceModelSession(
      handle: handle,
      modelType: modelType,
      fileType: fileType,
      supportImage: enableVisionModality ?? supportImage,
      supportAudio: enableAudioModality ?? supportAudio,
      enableThinking: enableThinking,
      onClose: () => _openSessions.remove(session),
    );
    _openSessions.add(session);
    return session;
  }

  @override
  Future<InferenceChat> createChat({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool isThinking = false,
    ModelType? modelType,
    ToolChoice toolChoice = ToolChoice.auto,
    int? maxFunctionBufferLength,
    String? systemInstruction,
    int? maxOutputTokens,
  }) async {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    chat = InferenceChat(
      sessionCreator: () => createSession(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage ?? this.supportImage,
        enableAudioModality: supportAudio ?? this.supportAudio,
        systemInstruction: systemInstruction,
        enableThinking: isThinking,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? this.supportImage,
      supportAudio: supportAudio ?? this.supportAudio,
      supportsFunctionCalls: supportsFunctionCalls ?? false,
      maxFunctionBufferLength:
          maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
      tools: tools,
      modelType: modelType ?? this.modelType,
      isThinking: isThinking,
      fileType: fileType,
      toolChoice: toolChoice,
      systemInstruction: systemInstruction,
    );
    await chat!.initSession();
    return chat!;
  }

  /// `tools_json` for a model whose tool calling LiteRT-LM runs natively —
  /// Gemma 4, and FunctionGemma — and null for every other model, which gets a
  /// Dart-side tools prompt in chat.dart instead. The runtime renders the
  /// declarations from it, parses calls into `tool_calls` and takes results as
  /// role `tool`. Same predicate [InferenceChat] uses to skip its own prompt,
  /// so the declarations are rendered exactly once.
  String? _nativeToolsJson(List<Tool> tools) =>
      tools.isNotEmpty &&
          FunctionCallParser.usesSdkPassthrough(modelType, fileType: fileType)
      ? SdkResponseParser.serializeToolsForSdk(tools)
      : null;

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      await _session?.close();
      // Copy because close() mutates _openSessions via the onClose callback.
      for (final s in _openSessions.toList()) {
        await s.close();
      }
      _openSessions.clear();
    } finally {
      // Awaited: shutdown() defers engine_delete until any conversation create
      // suspended on its spawned isolate has finished.
      await ffiClient.shutdown();
      onClose(); // legacy hook (engine passes a no-op)
      fireCloseListeners(); // core's singleton-reset, registered via addCloseListener
    }
  }
}

/// FFI implementation of InferenceModelSession.
/// Buffers query chunks until [getResponse] is called.
///
/// Routes all per-conversation native calls through [handle] — its own
/// [ConversationHandle] — so multiple sessions on one model are fully
/// isolated. [extractTextFromResponse] is a static helper on
/// [LiteRtLmFfiClient] and needs no instance.
class FfiInferenceModelSession extends InferenceModelSession
    with RawSdkResponseSession {
  FfiInferenceModelSession({
    required this.handle,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this.supportAudio,
    this.enableThinking = false,
    required this.onClose,
  });

  final ConversationHandle handle;
  final ModelType modelType;
  final ModelFileType fileType;
  final bool supportImage;
  final bool supportAudio;
  final bool enableThinking;
  final VoidCallback onClose;

  final StringBuffer _queryBuffer = StringBuffer();
  final List<Uint8List> _pendingImages = [];
  Uint8List? _pendingAudio;
  bool _isClosed = false;

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

  /// Last full raw JSON response from SDK. For native tool models this is the
  /// structured OpenAI Chat Completions object (with `tool_calls` if any).
  /// chat.dart reads it via [lastRawResponse] before fallback to text
  /// extraction.
  String? _lastRawResponse;

  /// Most recent raw SDK JSON. Returns the response of the last [getResponse]
  /// or [getResponseAsync]. For native tool models use
  /// [SdkResponseParser.extractToolCalls] on this string to surface tool calls.
  @override
  String? get lastRawResponse => _lastRawResponse;

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError('Session is closed');
    }
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
  /// whole turn. LiteRT-LM's template continues the model's own turn only after
  /// a `tool` message; sent as user text, the model opens a new turn and calls
  /// the same function again. A turn that also carries user text or media is a
  /// user message, so there the results stay in the text they were staged as —
  /// the history replay after a context trim stages exactly that mix.
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

  /// This turn's raw SDK stream: the tool-result message when there is one,
  /// the staged user message otherwise.
  Stream<String> _rawTurn(
    String text,
    List<Uint8List>? images,
    Uint8List? audio,
    String? toolMessage,
  ) => toolMessage != null
      ? handle.chatRawMessage(toolMessage, enableThinking: enableThinking)
      : handle.chatRaw(
          text,
          imageBytes: images,
          audioBytes: audio,
          enableThinking: enableThinking,
        );

  @override
  Future<String> getResponse() async {
    _assertNotClosed();
    final text = _queryBuffer.toString();
    _queryBuffer.clear();
    final audio = _pendingAudio;
    final images = _pendingImages.isNotEmpty
        ? List<Uint8List>.from(_pendingImages)
        : null;
    _pendingAudio = null;
    _pendingImages.clear();
    final toolMessage = _takeToolResponseMessage();

    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;

    // Native tool models walk raw SDK JSON so chat.dart can read `tool_calls`
    // via [SdkResponseParser.extractToolCalls]. Other models keep the existing
    // text-only fast path (raw JSON cache stays null).
    if (_nativeTools) {
      final rawBuffer = StringBuffer();
      final textBuffer = StringBuffer();
      await for (final rawChunk in _rawTurn(text, images, audio, toolMessage)) {
        if (firstChunkMs == null) {
          firstChunkMs = genSw.elapsedMilliseconds;
          gemmaLog(
            '[FfiInferenceModelSession/perf] time-to-first-chunk (prefill): ${firstChunkMs}ms',
          );
        }
        chunkCount++;
        rawBuffer.write(rawChunk);
        textBuffer.write(LiteRtLmFfiClient.extractTextFromResponse(rawChunk));
      }
      _lastRawResponse = rawBuffer.toString();
      _logGenerationStats(genSw, firstChunkMs, chunkCount);
      return textBuffer.toString();
    }

    _lastRawResponse = null;
    final buffer = StringBuffer();
    await for (final chunk in handle.chat(
      text,
      imageBytes: images,
      audioBytes: audio,
      enableThinking: enableThinking,
    )) {
      if (firstChunkMs == null) {
        firstChunkMs = genSw.elapsedMilliseconds;
        gemmaLog(
          '[FfiInferenceModelSession/perf] time-to-first-chunk (prefill): ${firstChunkMs}ms',
        );
      }
      chunkCount++;
      buffer.write(chunk);
    }
    _logGenerationStats(genSw, firstChunkMs, chunkCount);
    return buffer.toString();
  }

  void _logGenerationStats(Stopwatch sw, int? firstChunkMs, int chunks) {
    final total = sw.elapsedMilliseconds;
    if (firstChunkMs == null || chunks == 0) {
      gemmaLog(
        '[FfiInferenceModelSession/perf] generation total: ${total}ms (no chunks emitted)',
      );
      return;
    }
    final decodeMs = total - firstChunkMs;
    final decodeRate = chunks > 1 && decodeMs > 0
        ? ((chunks - 1) * 1000.0 / decodeMs).toStringAsFixed(1)
        : 'n/a';
    gemmaLog(
      '[FfiInferenceModelSession/perf] generation total: ${total}ms '
      '(prefill ${firstChunkMs}ms + decode ${decodeMs}ms over $chunks chunks, '
      '~$decodeRate chunks/sec)',
    );
  }

  @override
  Stream<String> getResponseAsync() async* {
    _assertNotClosed();
    final text = _queryBuffer.toString();
    _queryBuffer.clear();
    final audio = _pendingAudio;
    final images = _pendingImages.isNotEmpty
        ? List<Uint8List>.from(_pendingImages)
        : null;
    _pendingAudio = null;
    _pendingImages.clear();
    final toolMessage = _takeToolResponseMessage();

    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;

    if (_nativeTools) {
      final rawBuffer = StringBuffer();
      await for (final rawChunk in _rawTurn(text, images, audio, toolMessage)) {
        if (firstChunkMs == null) {
          firstChunkMs = genSw.elapsedMilliseconds;
          gemmaLog(
            '[FfiInferenceModelSession/perf] (async) time-to-first-chunk (prefill): ${firstChunkMs}ms',
          );
        }
        chunkCount++;
        rawBuffer.write(rawChunk);
        yield LiteRtLmFfiClient.extractTextFromResponse(rawChunk);
      }
      _lastRawResponse = rawBuffer.toString();
      _logGenerationStats(genSw, firstChunkMs, chunkCount);
      return;
    }

    _lastRawResponse = null;
    await for (final chunk in handle.chat(
      text,
      imageBytes: images,
      audioBytes: audio,
      enableThinking: enableThinking,
    )) {
      if (firstChunkMs == null) {
        firstChunkMs = genSw.elapsedMilliseconds;
        gemmaLog(
          '[FfiInferenceModelSession/perf] (async) time-to-first-chunk (prefill): ${firstChunkMs}ms',
        );
      }
      chunkCount++;
      yield chunk;
    }
    _logGenerationStats(genSw, firstChunkMs, chunkCount);
  }

  @override
  SessionMetrics getSessionMetrics() {
    return handle.getSessionMetrics();
  }

  @override
  Future<int> sizeInTokens(String text) async {
    // Ask the model's own tokenizer. This used to be `(text.length / 4).ceil()`
    // — a placeholder from the 0.14.0 FFI port that nothing ever measured,
    // while the MediaPipe path called the real tokenizer all along.
    //
    // Measured 2026-08-18 against gemma-4-E2B-it's own tokenizer, estimate over
    // actual (below 1.0 = UNDERCOUNT):
    //
    //   english   1.23x     russian  1.00x     repeated ru words  1.40x
    //   code      0.75x     chinese  0.44x
    //
    // So the folklore is half right. Four chars per token is fine for English
    // and — surprisingly — near-exact for Russian, whose words this tokenizer
    // covers well. It is CJK that breaks it: Chinese runs ~1.8 characters per
    // token, so the estimate undercounts by more than half. Code undercounts by
    // a third.
    //
    // InferenceChat budgets the context window with this (chat.dart accumulates
    // `_currentTokens += await session.sizeInTokens(...)` and recreates the
    // session near `maxTokens`), so an undercount means it believes there is
    // headroom while the native KV cache is already full — surfacing as the
    // #318-class DYNAMIC_UPDATE_SLICE failure or silent truncation, and read as
    // a model problem rather than an estimator one. The same conversation on a
    // .task model trimmed correctly.
    //
    // The ratios are per-tokenizer, not universal: re-measure rather than
    // re-quote if the model family changes.
    // Same closed-session contract as every sibling method. Without it this
    // was the one call that survived close() — and it would have answered with
    // a plausible estimate instead of the use-after-close error the caller
    // gets everywhere else.
    _assertNotClosed();

    final exact = await handle.tokenCount(text);
    if (exact != null) return exact;

    // Engine down, or the native call failed. Fall back to the estimate rather
    // than throw — this feeds budgeting, not correctness — but say so, because
    // a silent estimate is what got us here.
    // Fall back, but err HIGH — and note that this warning does not reach a
    // release build at all (`gemmaLog` is `kDebugMode`-gated and
    // dead-code-eliminated), so the fallback has to be safe on its own rather
    // than merely announced.
    //
    // The two directions are not symmetric. Overcounting trims history and
    // recreates the session a little early — cheap, recoverable, visible.
    // Undercounting overruns the native KV cache, which is the #318-class
    // DYNAMIC_UPDATE_SLICE crash. `len/4` was measured at 0.44x on Chinese and
    // 0.75x on code, i.e. it errs in the crash direction on exactly the inputs
    // that break. Two characters per token bounds every case measured
    // (densest was ~1.8), so it over-counts English by roughly 2x and never
    // under-counts.
    if (!_tokenFallbackWarned) {
      _tokenFallbackWarned = true;
      gemmaLog(
        '[LiteRtLmFfi] sizeInTokens: native tokenizer unavailable; estimating '
        'conservatively at 2 chars/token for the rest of this session. '
        'Context budgeting will over-count, trimming history earlier than '
        'necessary — the safe direction.',
      );
    }
    return (text.length / 2).ceil();
  }

  /// One-shot latch for the estimate warning. Without it the message fires
  /// once per turn and once per trimmed message, which is the volume that
  /// teaches people to scroll past it.
  bool _tokenFallbackWarned = false;

  @override
  Future<void> stopGeneration() async {
    handle.cancelGeneration();
  }

  @override
  Future<void> close() async {
    // Idempotent: a superseded singleton session and the live one can both
    // be closed by a caller, and createSession also closes the prior
    // session before opening a new one — a second close must not re-run
    // handle.close() / onClose(). See the createSession comment and #308.
    if (_isClosed) return;
    _isClosed = true;
    _queryBuffer.clear();
    _pendingImages.clear();
    _pendingAudio = null;
    _pendingToolResponses.clear();
    handle.close();
    onClose();
  }
}

/// How long a turn waits for a stopped one to wind down before going ahead —
/// the same bound VoiceSession gives a stopped reply to drain.
const _windDownTimeout = Duration(seconds: 5);

/// The single-session lane's handle: one real native conversation, rebuilt
/// after a turn is stopped.
///
/// A conversation whose generation was cancelled mid-turn answers every later
/// message with nothing — zero chunks in about a millisecond, on every turn
/// after, measured on native 0.16.0 through 0.17.1. A fresh conversation on the
/// same engine answers normally. So this handle records each turn the way the
/// virtual-session multiplexer does, and the first turn after a stop replaces
/// the conversation with a new one seeded with that history as a
/// `messages_json` preface — one prefill, paid only after a stop.
///
/// A cancel that arrives after a turn has finished does not count: Dart
/// delivers a stream's `done` by cancelling its subscription, which cancels
/// the native conversation on every normal turn, and that leaves it healthy.
///
/// Public, though nothing outside this library uses it, so that tests can drive
/// the recovery over fake handles with no engine.
class RecoveringConversationHandle implements ConversationHandle {
  RecoveringConversationHandle(
    this._live, {
    required this.reopen,
    this.windDownTimeout = _windDownTimeout,
  });

  /// How long a turn waits for a stopped one to record itself. See [_turn].
  final Duration windDownTimeout;

  ConversationHandle _live;

  /// Opens a conversation with this session's config, seeded with
  /// [messagesJson] when given.
  final Future<ConversationHandle> Function(String? messagesJson) reopen;

  /// Every turn so far, as the messages a rebuild replays.
  final List<Map<String, Object?>> _history = [];

  /// True from the start of a turn — rebuild included — to the end of its
  /// `finally`.
  bool _inFlight = false;

  /// A cancel landed inside the current turn. Reset when the next turn starts.
  bool _stopRequested = false;

  /// Completes when the current turn's `finally` has run, so a turn that
  /// starts before a stopped one has wound down can wait for its history.
  Future<void>? _turnDone;

  /// Set when a turn that reached the model was cut off; the next turn
  /// rebuilds before it runs.
  bool _stopped = false;

  /// Images and audio are not replayed — the preface is text — so a rebuild
  /// after a multimodal turn says so once instead of silently forgetting.
  bool _historyHasMedia = false;

  bool _closed = false;

  Future<void> _rebuild() async {
    // One live conversation per engine (upstream #966): delete first.
    _live.close();
    _live = await reopen(
      _history.isEmpty ? null : LiteRtLmFfiClient.buildHistoryJson(_history),
    );
    // Only now: a reopen that throws leaves the old conversation closed and
    // this set, so the next turn tries again instead of using a dead handle.
    _stopped = false;
    if (_closed) {
      _live.close();
      throw StateError('Conversation handle is closed');
    }
    gemmaLog(
      '[FfiInferenceModel] rebuilt the conversation after a stopped turn '
      '(${_history.length} messages replayed)',
    );
    if (_historyHasMedia) {
      gemmaLog(
        '[FfiInferenceModel] images and audio from earlier turns are not '
        'replayed after a stop — the rebuilt conversation has their text only',
        level: GemmaLogLevel.info,
      );
    }
  }

  /// Runs one turn on the live conversation, rebuilding it first if the
  /// previous turn was stopped, and records the turn for the next rebuild.
  /// [raw] says whether [send] yields raw SDK JSON or plain text.
  Stream<String> _turn(
    Map<String, Object?> message,
    Stream<String> Function(ConversationHandle live) send, {
    required bool raw,
  }) async* {
    if (_closed) throw StateError('Conversation handle is closed');
    // A turn that starts while a stopped one is still winding down — which
    // VoiceSession does after a bounded drain — waits for its `finally`, or
    // the rebuild would replay a history that is missing the stopped exchange.
    // Bounded: a consumer that pauses the stopped stream and never resumes it
    // would otherwise block every later turn. Past the bound the stopped turn
    // is treated as having damaged the conversation, and the rebuild goes
    // ahead without its exchange rather than not at all.
    if (_stopRequested) {
      await _turnDone?.timeout(
        windDownTimeout,
        onTimeout: () {
          _stopped = true;
          gemmaLog(
            '[FfiInferenceModel] a stopped turn did not wind down within '
            '${windDownTimeout.inSeconds}s (is its stream paused?); rebuilding '
            'without it',
          );
        },
      );
    }
    final done = Completer<void>();
    _turnDone = done.future;
    _inFlight = true;
    _stopRequested = false;
    final text = StringBuffer();
    final rawReply = StringBuffer();
    var sent = false;
    var finished = false;
    var failed = false;
    try {
      if (_stopped) await _rebuild();
      // Stopped while the conversation was being rebuilt: nothing has reached
      // the model, so there is nothing to generate and nothing to record.
      if (_stopRequested) return;
      sent = true;
      await for (final chunk in send(_live)) {
        if (raw) {
          text.write(LiteRtLmFfiClient.extractTextFromResponse(chunk));
          rawReply.write(chunk);
        } else {
          text.write(chunk);
        }
        yield chunk;
      }
      finished = true;
    } catch (_) {
      // A failed turn is not a stopped one: rebuilding would replay the same
      // context into the same failure.
      failed = true;
      rethrow;
    } finally {
      _inFlight = false;
      if (sent) {
        // Stopped by cancelGeneration, or abandoned mid-turn — which cancels
        // native the same way — leaves the conversation answering nothing.
        if (_stopRequested || (!finished && !failed)) _stopped = true;
        // The message reached the model either way, so it belongs in the
        // history a rebuild replays — with whatever of the reply was produced.
        _history
          ..add(message)
          ..add(
            _VirtualConversationHandle._assistantTurn(
              text.toString(),
              rawReply.toString(),
            ),
          );
      }
      done.complete();
    }
  }

  /// The user message as a rebuild replays it: its text. Media is noted, not
  /// kept — see [_historyHasMedia].
  Map<String, Object?> _textOnly(
    String text,
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
  ) {
    if ((imageBytes?.isNotEmpty ?? false) || audioBytes != null) {
      _historyHasMedia = true;
    }
    return jsonDecode(LiteRtLmFfiClient.buildMessageJson(text))
        as Map<String, Object?>;
  }

  @override
  Future<int?> tokenCount(String text) => _live.tokenCount(text);

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => _turn(
    _textOnly(text, imageBytes, audioBytes),
    (live) => live.chat(
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    ),
    raw: false,
  );

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => _turn(
    _textOnly(text, imageBytes, audioBytes),
    (live) => live.chatRaw(
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    ),
    raw: true,
  );

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
  }) => _turn(
    jsonDecode(messageJson) as Map<String, Object?>,
    (live) => live.chatRawMessage(messageJson, enableThinking: enableThinking),
    raw: true,
  );

  @override
  void cancelGeneration() {
    // Only a cancel that lands inside a turn damages the conversation. The
    // turn's `finally` turns this into a rebuild if generation had begun.
    if (_inFlight) _stopRequested = true;
    _live.cancelGeneration();
  }

  @override
  SessionMetrics getSessionMetrics() => _live.getSessionMetrics();

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _history.clear();
    _live.close();
  }
}

/// A [ConversationHandle] backed by the virtual-session multiplexer.
///
/// The LiteRT-LM engine allows only ONE live conversation at a time
/// (upstream #966), so concurrent [openSession] sessions can't each hold a
/// real native conversation. Instead each virtual handle keeps its full turn
/// history in Dart and, on every generate, asks the client to (re)materialize
/// the single shared conversation seeded with THIS session's history via a
/// `messages_json` preface. The client serializes turns with a mutex, so the
/// sessions are logically concurrent (independent contexts) but inference is
/// serialized (one generation at a time) — verified by the
/// session_switch / messages_preface smoke tests.
///
/// Same-session follow-up turns reuse the live conversation (no rebuild);
/// only switching to a different session pays the teardown+replay cost.
class _VirtualConversationHandle implements ConversationHandle {
  _VirtualConversationHandle({
    required this.client,
    required this.systemMessage,
    required this.toolsJson,
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.seed,
    this.maxOutputTokens,
  });

  final LiteRtLmFfiClient client;
  final String? systemMessage;
  final String? toolsJson;
  final double temperature;
  final int topK;
  final double? topP;
  final int seed;
  final int? maxOutputTokens;

  /// The tokenizer belongs to the engine, not to a conversation, so a virtual
  /// session answers this as accurately as a live one.
  @override
  Future<int?> tokenCount(String text) => client.tokenCount(text);

  /// Unique identity for this virtual session — the client uses it to tell
  /// whether the live conversation already holds this session's history.
  final Object token = Object();

  /// Completed turns, replayed as a `messages_json` preface to rebuild this
  /// session's context when it next becomes active. Whole messages rather than
  /// role and text, because a tool round is an assistant turn with
  /// `tool_calls` followed by a role-`tool` message, and neither survives being
  /// flattened to text.
  final List<Map<String, Object?>> _history = [];

  bool _closed = false;

  /// This session's own turn is running. See [cancelGeneration].
  bool _inFlight = false;

  /// A cancel landed inside this session's current turn.
  bool _stopRequested = false;

  /// Completes when the current turn has recorded its history.
  Future<void>? _turnDone;

  /// Drive one turn through the multiplexer, then record the sent [message]
  /// and the generated assistant reply so the NEXT turn replays them as
  /// preface. [raw] decides what the caller gets per chunk (raw SDK JSON or its
  /// text); history records the reply the same way either way.
  Stream<String> _run(
    Map<String, Object?> message, {
    required bool raw,
    bool enableThinking = false,
  }) async* {
    if (_closed) throw StateError('Conversation handle is closed');
    // After a stop the client rebuilds the conversation from this snapshot,
    // so a turn that starts before the stopped one has recorded itself waits
    // for it — otherwise the rebuild would leave the stopped exchange out.
    if (_stopRequested) {
      // Bounded for the reason given in RecoveringConversationHandle._turn.
      await _turnDone?.timeout(_windDownTimeout, onTimeout: () {});
    }
    final done = Completer<void>();
    _turnDone = done.future;
    _inFlight = true;
    _stopRequested = false;
    final messageJson = jsonEncode(message);
    final extraContext = enableThinking ? '{"enable_thinking": true}' : null;
    // Snapshot history BEFORE this turn — the live message is sent separately.
    final historySnapshot = List<Map<String, Object?>>.from(_history);
    final assistantText = StringBuffer();
    final assistantRaw = StringBuffer();
    var recorded = false;
    void record() {
      if (recorded) return;
      recorded = true;
      // Record both turns so the next switch back replays the full context.
      // The message was already fed live into the native conversation, so it
      // must land in history even if generation errored partway — otherwise a
      // session switch+rebuild would replay a context that omits a turn the
      // model actually saw, silently diverging native and Dart state.
      _history.add(message);
      _history.add(
        _assistantTurn(assistantText.toString(), assistantRaw.toString()),
      );
    }

    try {
      await for (final rawChunk in client.startVirtualTurn(
        conversationToken: token,
        messageJson: messageJson,
        history: historySnapshot,
        systemMessage: systemMessage,
        toolsJson: toolsJson,
        temperature: temperature,
        topK: topK,
        topP: topP,
        seed: seed,
        extraContext: extraContext,
        maxOutputTokens: maxOutputTokens,
      )) {
        final chunkText = LiteRtLmFfiClient.extractTextFromResponse(rawChunk);
        assistantText.write(chunkText);
        assistantRaw.write(rawChunk);
        yield raw ? rawChunk : chunkText;
      }
      record();
    } finally {
      // Also record on error/cancel so the user turn isn't lost.
      record();
      _inFlight = false;
      done.complete();
    }
  }

  /// The assistant turn to replay: its tool calls when it made any, so the
  /// tool results recorded after it still answer something, and its text
  /// otherwise.
  static Map<String, Object?> _assistantTurn(String text, String raw) {
    final calls = SdkResponseParser.extractToolCalls(raw);
    if (calls.isEmpty) {
      return {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
      };
    }
    return {
      'role': 'assistant',
      'tool_calls': [
        for (final call in calls)
          {
            'type': 'function',
            'function': {'name': call.name, 'arguments': call.args},
          },
      ],
    };
  }

  // Virtual sessions replay history as a text-only `messages_json` preface, so
  // image/audio turns can't be reconstructed on a session switch. Reject media
  // loudly rather than silently dropping it (parity with openSession rejecting
  // loraPath). Multimodal needs the single-session createSession path.
  void _rejectMedia(List<Uint8List>? imageBytes, Uint8List? audioBytes) {
    if ((imageBytes != null && imageBytes.isNotEmpty) || audioBytes != null) {
      throw UnsupportedError(
        'Image/audio input is not supported on concurrent (openSession) '
        '.litertlm sessions — their history is replayed text-only on switch. '
        'Use createSession() for multimodal, or a MediaPipe .task model.',
      );
    }
  }

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _rejectMedia(imageBytes, audioBytes);
    return _run(_userMessage(text), raw: false, enableThinking: enableThinking);
  }

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _rejectMedia(imageBytes, audioBytes);
    return _run(_userMessage(text), raw: true, enableThinking: enableThinking);
  }

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
  }) => _run(
    jsonDecode(messageJson) as Map<String, Object?>,
    raw: true,
    enableThinking: enableThinking,
  );

  static Map<String, Object?> _userMessage(String text) =>
      jsonDecode(LiteRtLmFfiClient.buildMessageJson(text))
          as Map<String, Object?>;

  @override
  void cancelGeneration() {
    if (_inFlight) _stopRequested = true;
    client.cancelVirtualTurn(token);
  }

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _history.clear();
    client.releaseVirtualConversation(token);
  }
}
