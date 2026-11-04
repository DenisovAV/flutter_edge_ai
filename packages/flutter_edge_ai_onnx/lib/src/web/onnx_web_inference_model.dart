// Web text-generation arm of `OnnxEngine` — Transformers.js v4
// (`@huggingface/transformers`) over `dart:js_interop` (ONNX web PR,
// `feat/onnx-web`). `dart:js_interop` only resolves on web compile targets —
// this file can never be imported into a VM (`flutter test`) run; it is
// compile-checked by `flutter build web` and exercised for real only in a
// browser.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';

import 'package:flutter_edge_ai/engine.dart';

import '../onnx_sampling.dart';
import '../reported_engine_turn.dart';
import 'transformers_js_interop.dart';
import 'transformers_web_resolver.dart';

/// Web text generation via Transformers.js v4 (`@huggingface/transformers`)
/// — the web arm of `OnnxEngine`. A COMPLETELY different provisioning +
/// execution model from the native ORT-GenAI arm (`../onnx_inference_model.dart`):
///
/// - **Model identity is a Hugging Face repo id**, not a downloaded
///   directory. Transformers.js resolves + caches the repo itself (browser
///   Cache Storage / IndexedDB) from the id alone — core's install pipeline
///   never touches the bytes (see `WebModelManager`'s `ModelFileType.onnx`
///   fileless-install branch and [TransformersWebResolver]).
/// - **The pipeline is STATELESS per call.** Unlike ORT-GenAI's persistent
///   generator (one KV cache reused turn-to-turn) or LiteRT-LM's
///   `Conversation`, `pipe(messages, options)` re-encodes the WHOLE
///   conversation from scratch every call — there is no cross-call KV cache
///   to reuse. [OnnxWebSession] accumulates the full
///   `List<{role, content}>` history and resends it every turn.
/// - **Structured messages, not a hand-built prompt string.** The pipeline
///   is handed `[{role, content}, ...]` and applies the model repo's OWN
///   `chat_template` (via the tokenizer's `apply_chat_template`) —
///   `Message.transformToChatPrompt` (the manual-template path every other
///   engine uses) is deliberately NOT used here.
///
/// Text-only v1 — LoRA and vision/audio are rejected loudly, matching
/// `OnnxSession` (the native ORT-GenAI arm)'s posture. `enableThinking` and
/// native tool calling are warn-and-ignore: whether/how the repo's own
/// `chat_template` emits a thinking channel or tool-call JSON is entirely
/// up to that template, not something this engine drives.
///
/// Besides the legacy [createSession] session, `openSession` / `openChat`
/// open further [OnnxWebSession]s on the same pipeline: each keeps its own
/// history, and turns of all of them are served one at a time. An open
/// session costs only its history (there is no KV cache between calls), so
/// [maxConcurrentSessions] is unset unless the app sets it.
class OnnxWebInferenceModel extends InferenceModel with CloseNotifier {
  OnnxWebInferenceModel({
    required this.resolver,
    required this.maxTokens,
    required this.modelType,
    this.fileType = ModelFileType.onnx,
    this.preferredBackend,
    this.maxConcurrentSessions,
    required this.onClose,
  });

  /// Resolves the active model's Hugging Face repo id. Engine-specific glue
  /// (the actual `pipeline()` call) lives in [_ensurePipeline] below.
  final TransformersWebResolver resolver;
  final ModelType modelType;
  @override
  final ModelFileType fileType;
  @override
  final int maxTokens;

  /// The caller's requested backend. `PreferredBackend.cpu` pins WASM;
  /// anything else (or null) tries WebGPU first, then falls back to WASM.
  final PreferredBackend? preferredBackend;

  PreferredBackend? _activeBackend;
  @override
  PreferredBackend? get activeBackend => _activeBackend;

  /// Cap on concurrent `openSession` sessions; null = unlimited. The legacy
  /// [createSession] session does not count.
  final int? maxConcurrentSessions;

  /// Serializes generation across every session of this model — the legacy
  /// one and each open one share the pipeline (mirrors every other engine's
  /// "concurrent contexts, serialized inference" posture).
  final Mutex generationMutex = Mutex();

  final VoidCallback onClose;

  TransformersPipeline? _pipeline;
  TransformersTokenizer? _tokenizer;
  Completer<void>? _pipelineCompleter;
  OnnxWebSession? _session;
  final Set<OnnxWebSession> _openSessions = {};

  /// Open sessions still waiting for the pipeline: they count against
  /// [maxConcurrentSessions] from the check on, so two calls that overlap
  /// cannot both pass it.
  int _openingSessions = 0;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  static bool _seedNoted = false;
  static bool _topPNoted = false;

  /// Says once per app run what web does not apply. Printed, because a
  /// release build is where it gets reported and edgeAiLog is silent there.
  /// The seed is not wired to Transformers.js' global `random.seed` yet, and
  /// Transformers.js 4.3.0 samples with top-k only.
  static void _noteIgnoredOnWeb({
    required int? randomSeed,
    required double? topP,
  }) {
    if (randomSeed != null && !_seedNoted) {
      _seedNoted = true;
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_onnx] WARNING: randomSeed is not applied on web '
        'yet. Shown once.',
      );
    }
    if (topP != null && !_topPNoted) {
      _topPNoted = true;
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_onnx] WARNING: topP is ignored on web: '
        'Transformers.js samples with top-k only. Shown once.',
      );
    }
  }

  @override
  InferenceModelSession? get session => _session;

  @override
  List<InferenceModelSession> get engineSessions => [
    ?_session,
    ..._openSessions,
  ];

  Future<void> _ensurePipeline() async {
    if (_pipeline != null) return;
    // Concurrent-call guard: a second caller awaits the first pipeline()
    // instead of starting its own (which would leak a second WebGPU/WASM
    // session and repo download).
    if (_pipelineCompleter != null) {
      await _pipelineCompleter!.future;
      return;
    }
    final completer = _pipelineCompleter = Completer<void>();
    try {
      await _createPipeline();
      completer.complete();
    } catch (e, st) {
      _pipelineCompleter = null; // allow retry
      // Only a concurrent caller listens; with none, the error is this
      // call's alone and must not also surface as an uncaught one.
      completer.future.ignore();
      completer.completeError(e, st);
      rethrow;
    }
  }

  Future<void> _createPipeline() async {
    final repoId = await resolver.resolveActiveRepoId();

    // The host page wires up `window.transformersReady` (a Promise resolving
    // once `window.transformers` is set) in its index.html `<script
    // type="module">` block — module scripts are deferred, so Dart can reach
    // here before the ESM finishes loading. See `example/web/index.html`.
    await transformersReady.toDart;

    final sw = Stopwatch()..start();
    TransformersPipeline pipe;
    PreferredBackend backend;
    if (preferredBackend == PreferredBackend.cpu) {
      // Explicit CPU request — go straight to WASM, no WebGPU attempt.
      pipe = await _loadPipeline(repoId, device: 'wasm');
      backend = PreferredBackend.cpu;
    } else {
      try {
        pipe = await _loadPipeline(repoId, device: 'webgpu');
        backend = PreferredBackend.gpu;
      } catch (e) {
        // WebGPU unavailable, or its ONNX Runtime backend failed to
        // initialize — retry on WASM (mirrors `OrtWebClient`'s
        // `['webgpu', 'wasm']` fallback intent; Transformers.js has no
        // built-in multi-backend try-list for `device`, so retry manually).
        if (kDebugMode) {
          edgeAiLog(
            '[OnnxWebInferenceModel] pipeline(webgpu) failed for $repoId, '
            'retrying on wasm: $e',
          );
        }
        pipe = await _loadPipeline(repoId, device: 'wasm');
        backend = PreferredBackend.cpu;
      }
    }
    if (kDebugMode) {
      edgeAiLog(
        '[OnnxWebInferenceModel/perf] pipeline($repoId, $backend): '
        '${sw.elapsedMilliseconds}ms',
      );
    }
    _pipeline = pipe;
    _tokenizer = pipe.tokenizer;
    _activeBackend = backend;
  }

  Future<TransformersPipeline> _loadPipeline(
    String repoId, {
    required String device,
  }) {
    final options =
        <String, Object?>{'dtype': 'q4', 'device': device}.jsify() as JSObject;
    return transformers
        .pipeline('text-generation'.toJS, repoId.toJS, options)
        .toDart;
  }

  /// Opens a session with a history of its own on the shared pipeline,
  /// independent of [session] and of every other open session; turns of
  /// different sessions are served one at a time.
  ///
  /// Throws [StateError] when [maxConcurrentSessions] sessions are already
  /// open.
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
    _checkRequest(
      loraPath: loraPath,
      enableVisionModality: enableVisionModality,
      enableAudioModality: enableAudioModality,
      enableThinking: enableThinking,
      tools: tools,
    );
    final cap = maxConcurrentSessions;
    if (cap != null && _openSessions.length + _openingSessions >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one. The createSession session is not counted.',
      );
    }
    // Checked before the pipeline loads: values it rejects must not load it.
    final sampling = SamplingParams(
      temperature: temperature,
      topK: topK,
      topP: topP,
      randomSeed: randomSeed,
    )..validate();
    _noteIgnoredOnWeb(randomSeed: randomSeed, topP: topP);
    // Counted from the cap check until the session is in [_openSessions]:
    // the await below would otherwise let a second call pass the check.
    _openingSessions++;
    try {
      await _ensurePipeline();
    } finally {
      _openingSessions--;
    }
    // Closed while the pipeline was loading: the model has dropped it.
    if (_isClosed) {
      throw StateError('Model was closed while opening a session');
    }
    late final OnnxWebSession opened;
    opened = OnnxWebSession(
      pipeline: _pipeline!,
      tokenizer: _tokenizer!,
      systemInstruction: systemInstruction,
      maxOutputTokens: maxOutputTokens,
      sampling: sampling,
      generationMutex: generationMutex,
      onClose: () => _openSessions.remove(opened),
    );
    _openSessions.add(opened);
    return opened;
  }

  /// [openChat]'s unset model type is this model's own (D8), so a Qwen3
  /// repo chats with Qwen3's thinking rules rather than Gemma's; the rest
  /// are core's defaults: the web session is text-only.
  @override
  ResolvedChatRequest resolveChatRequest(ChatRequest request) =>
      ResolvedChatRequest(
        modelType: request.modelType ?? modelType,
        supportImage: request.supportImage ?? false,
        supportAudio: request.supportAudio ?? false,
        supportsFunctionCalls: request.supportsFunctionCalls ?? false,
        tools: request.tools,
        maxFunctionBufferLength:
            request.maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
        temperature: request.temperature,
        randomSeed: request.randomSeed,
        topK: request.topK,
        topP: request.topP,
        tokenBuffer: request.tokenBuffer,
        loraPath: request.loraPath,
        enableThinking: request.enableThinking,
        toolChoice: request.toolChoice,
        systemInstruction: request.systemInstruction,
        maxOutputTokens: request.maxOutputTokens,
      );

  /// What [createSession] and [openEngineSession] refuse, and what they
  /// accept but do not apply.
  void _checkRequest({
    required String? loraPath,
    required bool? enableVisionModality,
    required bool? enableAudioModality,
    required bool enableThinking,
    required List<Tool> tools,
  }) {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    if (loraPath != null) {
      throw UnsupportedError(
        'LoRA weights are not supported on the ONNX web (Transformers.js) '
        'path (loraPath=$loraPath). Use a MediaPipe .task or .litertlm model.',
      );
    }
    if (enableVisionModality == true || enableAudioModality == true) {
      throw UnsupportedError(
        'Vision/audio modalities are not supported on the ONNX web '
        '(Transformers.js) session (v1, text-only). Use a MediaPipe .task '
        'or .litertlm model.',
      );
    }
    if (enableThinking && kDebugMode) {
      edgeAiLog(
        '[OnnxWebInferenceModel] enableThinking is not driven by this '
        "engine — the repo's own chat_template decides whether/how a "
        'thinking channel is emitted; ignoring.',
      );
    }
    if (tools.isNotEmpty && kDebugMode) {
      edgeAiLog(
        '[OnnxWebInferenceModel] Native tool calling is not yet wired on '
        'the Transformers.js path — ignoring ${tools.length} tool(s).',
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
    _checkRequest(
      loraPath: loraPath,
      enableVisionModality: enableVisionModality,
      enableAudioModality: enableAudioModality,
      enableThinking: enableThinking,
      tools: tools,
    );

    // Single-flight guard for concurrent callers; sequential calls fall
    // through and close the previous session before opening a fresh one —
    // same rationale as `OnnxInferenceModel.createSession` (native arm).
    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<InferenceModelSession>();

    try {
      // Checked first: values it rejects must not cost the live session.
      final sampling = SamplingParams(
        temperature: temperature,
        topK: topK,
        topP: topP,
        randomSeed: randomSeed,
      )..validate();
      _noteIgnoredOnWeb(randomSeed: randomSeed, topP: topP);
      await _ensurePipeline();
      await _session?.close();

      if (_isClosed) {
        throw StateError('Model was closed while creating a session');
      }

      late final OnnxWebSession newSession;
      newSession = OnnxWebSession(
        pipeline: _pipeline!,
        tokenizer: _tokenizer!,
        systemInstruction: systemInstruction,
        maxOutputTokens: maxOutputTokens,
        sampling: sampling,
        generationMutex: generationMutex,
        onClose: () {
          if (identical(_session, newSession)) _session = null;
        },
      );
      _session = newSession;
      completer.complete(newSession);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _createCompleter = null;
    }
    return completer.future;
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
    try {
      await _session?.close();
      // Copied: close() takes a session out of the set.
      for (final s in _openSessions.toList()) {
        await s.close();
      }
    } finally {
      _pipeline = null;
      _tokenizer = null;
      onClose();
      fireCloseListeners();
    }
  }
}

/// `InferenceModelSession` over a Transformers.js text-generation pipeline.
///
/// Accumulates the FULL chat history as a `List<Map<String, String>>` (each
/// entry `{role, content}`) and re-sends the whole list on every
/// [getResponseAsync] call — the pipeline itself is stateless per call (see
/// [OnnxWebInferenceModel]'s module doc). [addQueryChunk] always appends a
/// `role: 'user'` entry; the assistant's streamed reply is appended once
/// generation completes.
class OnnxWebSession extends InferenceModelSession {
  OnnxWebSession({
    required this.pipeline,
    required this.tokenizer,
    this.systemInstruction,
    this.maxOutputTokens,
    this.sampling = const SamplingParams(),
    required this.generationMutex,
    required this.onClose,
  }) {
    final instruction = systemInstruction;
    if (instruction != null && instruction.isNotEmpty) {
      _history.add({'role': 'system', 'content': instruction});
    }
  }

  final TransformersPipeline pipeline;
  final TransformersTokenizer tokenizer;
  final String? systemInstruction;
  final int? maxOutputTokens;

  /// What the caller set; unset fields keep the repo's generation_config.json.
  final SamplingParams sampling;

  /// Shared across the owning model — serializes generation. Acquired for
  /// the whole duration of a getResponse(Async) call.
  final Mutex generationMutex;
  final VoidCallback onClose;

  static const int _defaultMaxNewTokens = 512;

  final List<Map<String, String>> _history = [];
  bool _isClosed = false;

  /// Set while a generation is in flight; `.interrupt()`ed by
  /// [stopGeneration] / a cancelled subscription / [close].
  InterruptableStoppingCriteria? _activeStoppingCriteria;

  /// How to stop each of this session's turns that is listened to and not
  /// over yet: the one generating, and any still waiting for the mutex.
  final Set<void Function()> _turnStops = {};

  void _assertNotClosed() {
    if (_isClosed) throw StateError('Session is closed');
  }

  @override
  Future<void> addQueryChunk(Message message) async {
    _assertNotClosed();
    if (message.hasImage || message.hasAudio) {
      throw UnsupportedError(
        'Image/audio input is not supported on the ONNX web '
        '(Transformers.js) session (v1, text-only). Use a MediaPipe .task '
        'or .litertlm model.',
      );
    }
    _history.add({'role': 'user', 'content': message.text});
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
  Stream<String> getResponseAsync() => _turn().text;

  /// One turn: its text, and whether it was stopped — by its own stop
  /// ([stopGeneration] while it was listened to, or a cancelled
  /// subscription), never by another turn's.
  ({Stream<String> text, bool Function() stopped}) _turn() {
    _assertNotClosed();

    final controller = StreamController<String>();
    final replyBuffer = StringBuffer();
    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;

    // `mutexHeld` is the SINGLE source of truth for lock ownership — the lock
    // is released exactly once, and only ever while we actually hold it. (An
    // earlier `released` flag that a pre-acquire cancel could set would wedge
    // the lock forever: the flag went true before ownership, so the real
    // post-acquire release then no-op'd — see review.)
    var mutexHeld = false;
    var cancelled = false;

    // Where this turn's input ends in [_history]: the entries up to here
    // that follow the last reply are its user messages. Set when it is
    // listened to, then when it snapshots the history.
    var inputEnd = 0;

    // A turn stopped before it produced anything leaves no trace: its user
    // messages leave the history, so the history keeps alternating (Gemma
    // 3's template raises on two user turns in a row). There is no rewind on
    // web to replay the stopped exchange. Messages added after this turn's
    // input are kept.
    void dropInput() {
      final end = inputEnd < _history.length ? inputEnd : _history.length;
      var start = end;
      while (start > 0 && _history[start - 1]['role'] == 'user') {
        start--;
      }
      _history.removeRange(start, end);
    }

    void releaseMutexIfHeld() {
      if (mutexHeld) {
        mutexHeld = false;
        generationMutex.release();
      }
    }

    // Signal only — never releases the mutex. The onListen coroutine owns
    // release in every terminal path; for an in-flight generation the lock
    // must stay held until the Transformers.js Promise SETTLES (via
    // runGeneration), and for a still-queued turn onListen releases right
    // after it acquires and sees `cancelled`. Releasing here would either
    // race a pre-acquire cancel into a deadlock or let a next turn overlap.
    void stop() {
      cancelled = true;
      // Interrupt ONLY when THIS stream owns the running generation: the
      // mutex is model-wide, and this session's criteria may belong to an
      // earlier turn of it that is running while this one waits.
      if (mutexHeld) {
        _activeStoppingCriteria?.interrupt();
        return;
      }
      // Still waiting for the mutex: end it now rather than when the turn
      // ahead finishes. Its onListen bails (and drops its input) right after
      // it acquires, before any later turn of this session can read the
      // history: the mutex serves turns in order.
      if (!controller.isClosed) unawaited(controller.close());
    }

    void onToken(String text) {
      firstChunkMs ??= genSw.elapsedMilliseconds;
      chunkCount++;
      replyBuffer.write(text);
      if (!controller.isClosed) controller.add(text);
    }

    Future<void> runGeneration(List<Map<String, String>> messages) async {
      final streamerOptions = JSObject()
        ..setProperty('skip_prompt'.toJS, true.toJS)
        ..setProperty('skip_special_tokens'.toJS, true.toJS)
        ..setProperty(
          'callback_function'.toJS,
          ((JSString chunk) => onToken(chunk.toDart)).toJS,
        );
      final streamer = TextStreamer(tokenizer, streamerOptions);

      final stoppingCriteria = InterruptableStoppingCriteria();
      _activeStoppingCriteria = stoppingCriteria;

      final messagesJs = messages.jsify();
      final generateOptions = JSObject()
        ..setProperty(
          'max_new_tokens'.toJS,
          (maxOutputTokens ?? _defaultMaxNewTokens).toJS,
        )
        ..setProperty('streamer'.toJS, streamer)
        ..setProperty('stopping_criteria'.toJS, stoppingCriteria);
      // Only what the caller set; the rest comes from the repo's
      // generation_config.json. The seed is not applied on web yet (see
      // _noteIgnoredOnWeb).
      for (final MapEntry(:key, :value) in onnxSearchOptions(
        sampling,
      ).entries) {
        if (key == 'random_seed') continue;
        generateOptions.setProperty(key.toJS, value.jsify());
      }

      try {
        final result = pipeline.generate(messagesJs, generateOptions);
        // Await the WHOLE pipeline Promise — a cancel/interrupt stops decoding
        // at the next token boundary, but the Promise only settles a moment
        // later, and the generation mutex MUST stay held until then so a next
        // turn can't overlap this one and clobber `_activeStoppingCriteria`.
        await result.toDart;
      } finally {
        _activeStoppingCriteria = null;
      }
    }

    controller.onListen = () async {
      _turnStops.add(stop);
      inputEnd = _history.length;
      try {
        await generationMutex.acquire();
        mutexHeld = true;
        // Cancelled/closed while we were queued behind another turn's lock —
        // release and bail WITHOUT generating.
        if (cancelled || controller.isClosed || _isClosed) {
          if (cancelled) dropInput();
          releaseMutexIfHeld();
          if (!controller.isClosed) await controller.close();
          return;
        }
        // Snapshot history AFTER acquiring the lock: a turn queued behind a
        // still-running turn must see that turn's appended assistant reply,
        // not a stale pre-reply snapshot.
        final messages = List<Map<String, String>>.from(_history);
        inputEnd = messages.length;
        await runGeneration(messages);
        // Record the (possibly interrupted) assistant reply that was streamed
        // to the consumer, so the next turn's history reflects it. Skip an
        // empty reply (interrupted before the first token) to avoid a blank
        // assistant turn polluting the context.
        if (replyBuffer.isNotEmpty) {
          _history.add({
            'role': 'assistant',
            'content': replyBuffer.toString(),
          });
        } else if (cancelled) {
          dropInput();
        }
        if (kDebugMode) {
          edgeAiLog(
            '[OnnxWebSession/perf] generation total: '
            '${genSw.elapsedMilliseconds}ms (prefill ${firstChunkMs ?? 0}ms, '
            '$chunkCount chunks)',
          );
        }
        releaseMutexIfHeld();
        if (!controller.isClosed) await controller.close();
      } catch (e, st) {
        releaseMutexIfHeld();
        if (!controller.isClosed) {
          controller.addError(e, st);
          await controller.close();
        }
      } finally {
        _turnStops.remove(stop);
      }
    };
    // Also runs once the turn has closed the stream itself; only a cancel
    // before that is the consumer's stop.
    controller.onCancel = () {
      if (!controller.isClosed) stop();
    };
    return (text: controller.stream, stopped: () => cancelled);
  }

  /// Exact token count via the pipeline's own tokenizer — NOT an estimate
  /// (unlike the LiteRT-LM web arm, which has no tokenizer access and falls
  /// back to a character-based heuristic). Uses `tokenizer.encode(text)`,
  /// which returns a plain `number[]` (real `.length`) — NOT the tokenizer's
  /// callable form, whose `input_ids` is a Tensor with no usable `.length`.
  @override
  Future<int> sizeInTokens(String text) async {
    return tokenizer.encode(text.toJS).toDart.length;
  }

  /// How the turn ended, for core's chat: a stop is [TurnEnd.stopped], a
  /// close the consumer did not ask for [TurnEnd.closed] (the chat keeps the
  /// partial reply, then raises: decision H).
  ///
  /// A turn that runs to its end reports [TurnEnd.endOfSequence]: a
  /// placeholder. Transformers.js resolves the same way at the end of
  /// sequence and at `max_new_tokens` (512 when `maxOutputTokens` is unset),
  /// so the two are not told apart; nothing reads it in core 2.6.0's plain
  /// turns, and this engine keeps `StructuredOutputSupport.none`.
  @override
  EngineTurn startTurn() {
    final turn = _turn();
    return reportedEngineTurn(
      turn.text,
      stopped: turn.stopped,
      closed: () => _isClosed,
      completed: TurnEnd.endOfSequence,
    );
  }

  /// Interrupts this session's generation at the next token boundary (not
  /// instantaneous — see [InterruptableStoppingCriteria]'s doc), and ends at
  /// once a turn of it still waiting behind another turn. A turn stopped
  /// before it produced anything takes its user messages out of the
  /// history. A no-op if this session has no turn listened to; another
  /// session's turn is never touched.
  @override
  Future<void> stopGeneration() async {
    for (final stop in _turnStops.toList()) {
      stop();
    }
  }

  /// Transformers.js does not surface a benchmark-info API; return empty
  /// metrics — same posture as the LiteRT-LM web arm.
  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    // Interrupt any in-flight generation BEFORE the model tears the
    // pipeline down — mirrors every other engine's "stop before teardown"
    // ordering (use-after-free guard).
    _activeStoppingCriteria?.interrupt();
    _history.clear();
    onClose();
  }
}
