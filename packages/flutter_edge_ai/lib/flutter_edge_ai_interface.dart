import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/tool.dart';
import 'package:flutter_edge_ai/core/chat.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/sampling.dart';
import 'package:flutter_edge_ai/model_file_manager_interface.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// Conditional default instance: the mobile/desktop default pulls dart:io;
// the web variant is a throwing stub (FlutterEdgeAiWeb registers itself at
// runtime). This keeps dart:io off the web/wasm import graph.
import 'flutter_edge_ai_default.dart'
    if (dart.library.js_interop) 'flutter_edge_ai_default_web.dart';

const supportedLoraRanks = [4, 8, 16];

/// Low-level platform-interface tier (the federated-plugin SPI) for
/// flutter_edge_ai. It hosts the abstract runtime types (`InferenceModel`,
/// `InferenceModelSession`, `InferenceChat`, `EmbeddingModel`,
/// `SpeechRecognizer`, `SpeechSynthesizer`, …) and the platform-dispatch
/// singleton [instance].
///
/// **App code should use the `FlutterEdgeAi` static facade instead** — it is the
/// canonical, complete entry point (install / run / introspect / uninstall /
/// storage). `FlutterEdgeAiPlugin.instance` is
/// retained for engine authors, the federated-plugin mock seam, and backward
/// compatibility; every consumer-facing operation here is also exposed on the
/// facade.
abstract class FlutterEdgeAiPlugin extends PlatformInterface {
  FlutterEdgeAiPlugin() : super(token: _token);

  static final Object _token = Object();
  static FlutterEdgeAiPlugin _instance = defaultFlutterEdgeAiInstance();

  static FlutterEdgeAiPlugin get instance => _instance;

  static set instance(FlutterEdgeAiPlugin instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  ModelFileManager get modelManager;

  InferenceModel? get initializedModel;

  EmbeddingModel? get initializedEmbeddingModel;

  /// Creates and returns a new [InferenceModel] instance.
  ///
  /// [modelType] — model type to create.
  /// [maxTokens] — the model's CONTEXT WINDOW: the total number of tokens
  /// shared by input (system prompt + history + current message) AND the
  /// generated output, i.e. the KV-cache budget. It is NOT the maximum
  /// response length — to cap how much is generated, use `maxOutputTokens`
  /// on [InferenceModel.createSession]. `.litertlm` models require a context
  /// window of at least 1024 (their baked `kv_cache_max_len`); a smaller
  /// value is clamped up to 1024 to avoid a native tensor-allocation crash
  /// (#318). The default (1024) is safe for every supported model.
  /// [preferredBackend] — backend preference (e.g., CPU, GPU).
  /// [preferredVisionBackend] — vision-encoder backend override; null
  /// defaults to CPU (optional).
  /// [preferredAudioBackend] — audio-encoder backend override; null defaults
  /// to CPU (optional).
  /// [loraRanks] — optional supported LoRA ranks.
  /// [maxNumImages] — maximum number of images (for multimodal models).
  /// [supportImage] — whether the model supports images.
  /// [supportAudio] — whether the model supports audio (Gemma 3n E4B only).
  /// [enableSpeculativeDecoding] — Multi-Token Prediction toggle for Gemma 4
  /// E2B/E4B (LiteRT-LM v0.11.0+). `null` honors the model's default;
  /// `true`/`false` forces on/off. Older `.litertlm` files without an MTP
  /// drafter ignore this flag at the SDK level.
  /// [activationDataType] — activation type for the text decoder of native
  /// `.litertlm` models (Android, iOS, desktop). `null` honors the model file;
  /// when set, it overrides LiteRT-LM's activation type selection (float16 on
  /// GPU by default). [ActivationDataType.float32] fixes GPUs that write wrong
  /// digits (LiteRT-LM#2814, #3012) at more GPU memory, and a GPU engine that
  /// cannot be created falls back to CPU without an error. The vision and
  /// audio encoders keep the model's own type, and MediaPipe, ONNX, built-in
  /// AI and the web engines ignore the setting.
  /// [maxConcurrentSessions] — optional cap on the number of sessions open
  /// at once via [InferenceModel.openSession]. `null` (default) = no cap,
  /// backward-compatible. When set, the (cap+1)-th [InferenceModel.openSession]
  /// throws [StateError]. Use this on mobile with large models to guard
  /// against OOM from multiple concurrent KV caches.
  Future<InferenceModel> createModel({
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.task,
    int maxTokens = 1024,
    PreferredBackend? preferredBackend,
    PreferredBackend? preferredVisionBackend,
    PreferredBackend? preferredAudioBackend,
    List<int>? loraRanks,
    int? maxNumImages, // Add image support
    bool supportImage = false, // Add image support flag
    bool supportAudio = false, // Add audio support flag (Gemma 3n E4B)
    bool? enableSpeculativeDecoding,
    ActivationDataType? activationDataType,
    int? maxConcurrentSessions,
  });

  /// Creates and returns a new [EmbeddingModel] instance.
  ///
  /// Modern API: If paths are not provided, uses the active embedding model set via
  /// `FlutterEdgeAi.installEmbedder()` or
  /// `modelManager.ensureModelReadyFromSpec()`.
  ///
  /// Legacy API: Provide explicit paths for backward compatibility.
  ///
  /// [modelPath] — path to the embedding model file (optional if active model set).
  /// [tokenizerPath] — path to the tokenizer file (optional if active model set).
  /// [preferredBackend] — backend preference (e.g., CPU, GPU).
  Future<EmbeddingModel> createEmbeddingModel({
    String? modelPath,
    String? tokenizerPath,
    PreferredBackend? preferredBackend,
  });

  /// Creates and returns a new [SpeechRecognizer] instance.
  ///
  /// Modern API: If paths are not provided, uses the active STT model set via
  /// `FlutterEdgeAi.installStt()` or
  /// `modelManager.ensureModelReadyFromSpec()`.
  ///
  /// [modelPath] — path to the STT model file (optional if active model set).
  /// [tokenizerPath] — path to the tokenizer file (optional if active model set).
  /// [preferredBackend] — backend preference (e.g., CPU, GPU).
  /// [language] — the OUTPUT language for transcripts, Whisper only: a bare
  /// lowercase code (`'en'`, `'de'`, …). It sets [SpeechRecognizer.language],
  /// the default for calls to [SpeechRecognizer.transcribe] that pass none, and
  /// it RETARGETS the recognizer when one already exists — this returns a
  /// process-wide singleton, so a language fixed at construction would take
  /// effect only on the first call in a process. Throws [ArgumentError] for a
  /// malformed code, or for any language on a model with no language token
  /// (moonshine, parakeet). `null` leaves the model's own default in place.
  Future<SpeechRecognizer> createSttModel({
    String? modelPath,
    String? tokenizerPath,
    PreferredBackend? preferredBackend,
    String? language,
  });

  /// Creates and returns a new [SpeechSynthesizer] for the active TTS model.
  ///
  /// Uses the active TTS model set via `FlutterEdgeAi.installTts()` /
  /// `modelManager.ensureModelReadyFromSpec()`. Native-only — throws on web.
  ///
  /// [language] is TTS-only (Qwen3; ignored by Matcha) — see
  /// `RuntimeConfig.language`'s doc. Forwarded into the `RuntimeConfig` the
  /// active model's backend builds from. A singleton for the same active
  /// model is reused across calls, so switching languages requires
  /// explicitly closing the previous [SpeechSynthesizer] first — a new
  /// [language] alone does not force a rebuild.
  Future<SpeechSynthesizer> createTtsModel({
    PreferredBackend? preferredBackend,
    String? language,
  });
}

/// Represents an LLM model instance.
abstract class InferenceModel {
  /// The single session created via [createSession]. Singleton lane —
  /// each [createSession] call overwrites this field with a new session
  /// and closes the previous one.
  ///
  /// For concurrent dialogues on a single loaded model use [openSession]
  /// instead — it returns detached sessions that don't touch this field.
  /// Read [sessions] to enumerate all live sessions (legacy + open).
  InferenceModelSession? get session;

  InferenceChat? chat;

  int get maxTokens;

  ModelFileType get fileType;

  /// Backend that the runtime initialized for this model, when known.
  ///
  /// This value is set after runtime creation and must reflect any fallback the
  /// plugin performed internally. FFI runtimes may fall back silently from a
  /// requested accelerator to another backend, so callers should check this
  /// value when the exact backend matters. It is null when the platform runtime
  /// does not expose a final backend.
  PreferredBackend? get activeBackend;

  /// Creates a new [InferenceModelSession] for generation.
  ///
  /// [temperature], [randomSeed], [topK], [topP] — sampling. A value you set
  /// is used as is; one no engine can sample with throws an [ArgumentError].
  /// An unset one comes from the model itself when the engine can read it (a
  /// native `.litertlm` bundle's sampler, an ONNX model's
  /// `genai_config.json`), otherwise from the family's published defaults
  /// ([SamplingParams.forModelType]), otherwise from [SamplingParams.fallback].
  /// Engines that cannot take a value say so once, and two depart from this:
  /// ONNX leaves unset fields to its config, and built-in AI sends
  /// `temperature: 0.8, topK: 1`. Pass `topK: 1` or `temperature: 0` for
  /// greedy decoding. On `.litertlm` the sampler is fixed by the engine's
  /// first generation (LiteRT-LM#2080), so a later session with different
  /// values needs the model reloaded.
  /// [loraPath] — optional path to LoRA model.
  /// [enableVisionModality] — enable vision modality for multimodal models.
  /// [enableAudioModality] — enable audio modality for Gemma 3n E4B models.
  ///
  /// [maxOutputTokens] — optional cap on how many tokens this session
  /// *generates* per response. This is the GENERATION length, distinct from
  /// the model's `maxTokens` (the whole CONTEXT WINDOW — input + output —
  /// passed to `createModel`/`getActiveModel`). To make the model produce a
  /// short reply, set `maxOutputTokens` (e.g. 100) and leave `maxTokens` at
  /// the default; do NOT lower `maxTokens` to 100 — `.litertlm` models require
  /// a context window of at least 1024 and will fail to allocate tensors
  /// below it (#318). Currently honored on the `.litertlm` (FFI) path; the
  /// MediaPipe `.task` path has no session-level output cap and ignores it
  /// (a log line is emitted).
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality, // Add vision modality support
    bool? enableAudioModality, // Add audio modality support (Gemma 3n E4B)
    String? systemInstruction,
    bool enableThinking =
        false, // Enable thinking mode (Gemma 4 via extraContext)
    List<Tool> tools =
        const [], // Native tool calling (Gemma 4 → SDK tools_json)
    int? maxOutputTokens, // Cap GENERATED tokens (not the context window)
  });

  /// Opens a new session detached from [session]. Each call returns a
  /// fresh independent session sharing the loaded model weights but with
  /// isolated context (history / KV cache). Use this for concurrent
  /// dialogues on a single loaded model.
  ///
  /// **Why:** the (expensive) model weights are loaded once and shared across
  /// every session; each session only adds its own lightweight context. This
  /// lets one loaded model back several independent conversations — e.g. a
  /// tabbed chat UI, two different system instructions / roles side by side,
  /// or background summarization alongside an active chat — without reloading
  /// the weights or clearing+rebuilding a single session's history on every
  /// switch. If you only ever have one conversation at a time, use
  /// [createSession] / [createChat] instead.
  ///
  /// Unlike [createSession], this does NOT modify the legacy [session]
  /// field. Concurrent sessions are tracked separately and surface via
  /// [sessions].
  ///
  /// **Concurrent contexts, serialized inference.** The sessions are
  /// logically independent — each keeps its own conversation — but
  /// generation is *serialized*: only one session runs inference at a time.
  /// Calling `getResponse()` / `getResponseAsync()` on a second session
  /// while another is still generating blocks until the first finishes; the
  /// calls do NOT run in parallel. This is intentional (parallel on-device
  /// inference would contend for the accelerator and risk OOM) and is the
  /// same on every backend:
  /// - `.litertlm` (FFI, all native): the engine allows one live
  ///   conversation at a time, so sessions multiplex — the active session's
  ///   history is replayed into the single conversation on switch.
  /// - `.litertlm` (web, `@litert-lm/core`): separate conversations, but
  ///   generation is still serialized.
  /// - `.task` (MediaPipe, Android/iOS): N real `LlmInferenceSession` live
  ///   at once (each with its own KV cache), generation serialized by a
  ///   mutex.
  ///
  /// **Memory caveat**: each concurrent session holds its own context
  /// (~100-500 MB depending on model + maxTokens). On mobile with large
  /// models (Gemma 4 E2B+), several concurrent sessions can OOM the process.
  /// Multi-session is most reliable on desktop and on high-end mobile with
  /// small models (Gemma 3 1B / 270M). For larger models on phones the safer
  /// pattern is still close+recreate with [InferenceChat]'s built-in history
  /// replay. Use [maxConcurrentSessions] on `createModel` to cap the count.
  ///
  /// Not yet available on the MediaPipe **web** `.task` path — throws
  /// [UnsupportedError] there.
  ///
  /// Throws [StateError] if `maxConcurrentSessions` (set on
  /// [FlutterEdgeAiPlugin.createModel]) is exceeded — close an existing
  /// session before opening a new one.
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
    throw UnsupportedError(
      'openSession() is not supported for $runtimeType. '
      'Concurrent sessions are available on `.litertlm` (FFI native + web) '
      'and `.task` (MediaPipe Android/iOS); the MediaPipe Web `.task` path '
      'does not support concurrent sessions.',
    );
  }

  /// Live sessions owned by this model — union of the legacy [session]
  /// (if any) and every active [openSession] result. Returns an
  /// unmodifiable view; mutate via [openSession], `session.close()`, or
  /// [close].
  List<InferenceModelSession> get sessions {
    final legacy = session;
    return List.unmodifiable([if (legacy != null) legacy]);
  }

  Future<InferenceChat> createChat({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool enableThinking = false,
    ModelType? modelType, // Add modelType parameter
    ToolChoice toolChoice = ToolChoice.auto, // Tool calling mode
    int? maxFunctionBufferLength,
    String? systemInstruction,
    int? maxOutputTokens, // Cap GENERATED tokens (see createSession)
  }) async {
    chat = InferenceChat(
      sessionCreator: () => createSession(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage ?? false,
        enableAudioModality: supportAudio ?? false,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        // Load-bearing, and it was missing: for a format whose
        // `runtimeInjectsToolDeclarations` is true (Gemma 4 ->
        // SdkPassthroughFunctionCallFormat), `InferenceChat` deliberately does
        // NOT weave a text tools prompt — it expects the runtime to have the
        // declarations. Without this line they reached neither path, so tools
        // were silently absent from the model's context. `openSession` below
        // always passed them; only this creator dropped them, which is why the
        // FFI engine (which overrides createChat) worked and every engine using
        // this base did not.
        tools: tools,
        maxOutputTokens: maxOutputTokens,
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? false,
      supportAudio: supportAudio ?? false,
      supportsFunctionCalls: supportsFunctionCalls ?? false,
      maxFunctionBufferLength:
          maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
      tools: tools,
      enableThinking: enableThinking,
      modelType: modelType ?? ModelType.gemmaIt,
      fileType: fileType,
      toolChoice: toolChoice,
      systemInstruction: systemInstruction,
    );
    await chat!.initSession();
    return chat!;
  }

  /// Same as [createChat], but uses [openSession] internally so the
  /// resulting chat owns an independent session that does not touch the
  /// legacy [session] field or other open chats. Use this when you need
  /// concurrent chats on a single loaded model.
  ///
  /// Each chat's own context-overflow rotation
  /// (`_recreateSessionWithReducedChunks`) creates a fresh sibling
  /// session via [openSession], so peer chats are unaffected.
  ///
  /// See [openSession] for the memory caveat. The returned chat is NOT
  /// stored in [chat] — that field tracks only the legacy [createChat]
  /// singleton. Hold the returned chat reference yourself and close it
  /// when done.
  Future<InferenceChat> openChat({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool enableThinking = false,
    ModelType? modelType,
    ToolChoice toolChoice = ToolChoice.auto,
    int? maxFunctionBufferLength,
    String? systemInstruction,
    int? maxOutputTokens, // Cap GENERATED tokens (see createSession)
  }) async {
    final independentChat = InferenceChat(
      sessionCreator: () => openSession(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage ?? false,
        enableAudioModality: supportAudio ?? false,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? false,
      supportAudio: supportAudio ?? false,
      supportsFunctionCalls: supportsFunctionCalls ?? false,
      maxFunctionBufferLength:
          maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
      tools: tools,
      enableThinking: enableThinking,
      modelType: modelType ?? ModelType.gemmaIt,
      fileType: fileType,
      toolChoice: toolChoice,
      systemInstruction: systemInstruction,
    );
    await independentChat.initSession();
    return independentChat;
  }

  /// Register a callback fired once when this model is closed. The lifecycle
  /// OWNER (core) uses this to reset its singleton bookkeeping for models built
  /// by an engine package. Concrete models satisfy this via [CloseNotifier].
  void addCloseListener(void Function() listener);

  Future<void> close();
}

/// Session metrics containing token usage and performance statistics.
class SessionMetrics {
  SessionMetrics({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.totalTokens = 0,
    this.timeToFirstTokenMs,
    this.tokensPerSecond,
    this.initTimeMs,
  });

  /// Number of input tokens (prompt tokens).
  final int inputTokens;

  /// Number of output tokens (generated tokens).
  final int outputTokens;

  /// Total tokens (input + output).
  final int totalTokens;

  /// Time to first token in milliseconds (if available).
  final double? timeToFirstTokenMs;

  /// Average tokens per second generation speed (if available).
  final double? tokensPerSecond;

  /// Session initialization time in milliseconds (if available).
  final double? initTimeMs;

  @override
  String toString() {
    return 'SessionMetrics(inputTokens: $inputTokens, outputTokens: $outputTokens, '
        'totalTokens: $totalTokens, ttft: ${timeToFirstTokenMs?.toStringAsFixed(2)}ms, '
        'tps: ${tokensPerSecond?.toStringAsFixed(2)})';
  }
}

/// Session managing response generation from the model.
abstract class InferenceModelSession {
  Future<String> getResponse();

  /// Streams generated tokens.
  ///
  /// To stop generating early, prefer [stopGeneration] — it reaches the native
  /// engine and stops it decoding on every engine. `cancel()`ing the
  /// [StreamSubscription] also stops native decoding on the `.litertlm` FFI
  /// engine, but on other engines it only detaches the Dart side while native
  /// keeps decoding, so [stopGeneration] is the portable choice.
  ///
  /// Silently *abandoning* the stream (dropping the subscription without
  /// cancelling, so it is only GC'd) cannot be intercepted on any engine — the
  /// accelerator keeps decoding the whole turn for output no one consumes,
  /// wasting compute and delaying the next turn's teardown.
  Stream<String> getResponseAsync();

  Future<int> sizeInTokens(String text);

  Future<void> addQueryChunk(Message message);

  /// Stops the current generation, cancelling native decoding on the
  /// `.litertlm` FFI path. Call this (or `cancel()` the response subscription)
  /// whenever a streamed response is superseded or no longer needed.
  Future<void> stopGeneration();

  /// Get session metrics including token usage and performance stats.
  ///
  /// **FFI (LiteRT-LM)**: Returns accurate token counts from benchmark info.
  /// **MediaPipe (Mobile)**: Returns estimated counts (uses internal metrics if available).
  ///
  /// Call this after [getResponse] or [getResponseAsync] completes for accurate results.
  SessionMetrics getSessionMetrics();

  Future<void> close();
}

/// Mixin for sessions that surface the SDK's structured raw JSON response
/// (LiteRT-LM Gemma 4 path with `tool_calls`). Allows [InferenceChat] to read
/// the structured tool calls without a hard dependency on a concrete session
/// type, and lets non-FFI sessions opt out by simply not implementing this
/// mixin.
mixin RawSdkResponseSession on InferenceModelSession {
  /// Most recent raw SDK JSON. Null until first generation completes.
  String? get lastRawResponse;
}

/// Task type for embedding generation, following Google RAG SDK convention.
///
/// EmbeddingGemma models are trained with different prefixes for queries
/// and documents to improve retrieval quality.
enum TaskType {
  /// For search queries. Prepends query prefix before embedding.
  retrievalQuery,

  /// For document indexing. Prepends document prefix before embedding.
  retrievalDocument;

  /// Canonical prefix prepended to user text before tokenization. Single
  /// source of truth across all native platforms — fixes cross-platform
  /// drift on `retrievalQuery` (issue #264) by construction. The prefix
  /// strings are stable, so corpora indexed with earlier releases remain
  /// valid.
  String get prefix => switch (this) {
    TaskType.retrievalQuery => 'task: search result | query: ',
    TaskType.retrievalDocument => 'title: none | text: ',
  };
}

/// Represents an embedding model instance.
abstract class EmbeddingModel {
  /// Generate embedding vector for given text.
  ///
  /// [taskType] controls the prefix applied before embedding:
  /// - [TaskType.retrievalQuery] (default) — for search queries
  /// - [TaskType.retrievalDocument] — for document indexing
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  });

  /// Generate embedding vectors for multiple texts.
  ///
  /// [taskType] controls the prefix applied before embedding.
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  });

  /// Get the dimension of embedding vectors generated by this model.
  Future<int> getDimension();

  /// Backend this embedder actually uses, when known — the counterpart of
  /// [InferenceModel.activeBackend], and the answer to
  /// `getActiveEmbedder(preferredBackend:)` that survives a release build.
  ///
  /// Every native backend answers [PreferredBackend.cpu] whatever was asked:
  /// LiteRT because its GPU delegate returns all-zero vectors for
  /// EmbeddingGemma's int4 weights, ONNX because it appends no execution
  /// provider. So a caller who passed `gpu` can read here that it did not
  /// happen, instead of learning it from a debug-only log line.
  ///
  /// Null on web, where the runtime picks for itself and does not report back:
  /// LiteRT.js selects per COMPILE (with per-operation delegation only in the
  /// JSPI partial case) and reports it through
  /// `window.getLiteRtEmbeddingAccelerator()` and
  /// `getLiteRtEmbeddingFullyAccelerated()` rather than here, and
  /// onnxruntime-web resolves `['webgpu', 'wasm']` in order.
  ///
  /// Null also means "this implementation did not say" — a native engine whose
  /// forward-pass descriptor omitted `activeBackend`, or any implementation
  /// that does not override this getter. Treat null as unknown, never as CPU.
  ///
  /// Defaulted rather than abstract so an existing SUBCLASS keeps compiling.
  /// `implements` does not inherit a default body, so those break regardless —
  /// which is why the CHANGELOG calls this breaking for engine authors. Override
  /// it wherever the answer is actually known.
  PreferredBackend? get activeBackend => null;

  /// Whether [close] has already been called.
  ///
  /// Core's embedder cache is the caller that needs this. It evicts on the close
  /// listener, which means it trusts an implementation to fire one — and a model
  /// that never does, or that was already closed before the cache took custody,
  /// would otherwise be handed to every later caller, whose first
  /// `generateEmbedding` throws. This lets the cache check instead of trust.
  ///
  /// Defaulted to `false` rather than abstract: it reproduces exactly what the
  /// cache assumed before it existed, so an implementation that does not answer
  /// behaves as it does today. `implements` does not inherit a default body, so
  /// those break — which is the same break this release already takes for
  /// [activeBackend], not a second one.
  bool get isClosed => false;

  /// See [InferenceModel.addCloseListener].
  void addCloseListener(void Function() listener);

  /// Close the embedding model and release resources.
  Future<void> close();
}

/// Represents a speech-to-text model instance.
abstract class SpeechRecognizer {
  /// Transcribe 16 kHz mono 16-bit little-endian PCM. Batch (fixed-window)
  /// for now; streaming is a follow-on.
  ///
  /// [language] selects the OUTPUT language for this call (Whisper only): a
  /// bare lowercase code such as `'en'`, `'de'`, `'uk'`, any of Whisper's 99.
  /// `null` uses the recognizer's current default.
  ///
  /// Whisper's shipped checkpoints are multilingual (no `.en` suffix), so this
  /// changes what the model WRITES, not what it understands. Measured on one
  /// German clip, same audio and build, one token apart:
  ///
  ///     'en' -> " This weather is very beautiful and the sun is shining."
  ///     'de' -> " Das Wetter ist heute sehr schön und die Sonne scheint."
  ///
  /// So asking for the wrong language does not garble the output — it
  /// TRANSLATES, fluently and without error, which is why a value that silently
  /// failed to take effect was worth treating as a bug (#500).
  ///
  /// Cheap by construction: the decoder's seed prompt is rebuilt per call, so
  /// switching language costs a map lookup and never reloads the model.
  /// Throws [ArgumentError] for a code this checkpoint's tokenizer does not
  /// have, and for any language on a model whose prompt has no language slot
  /// (moonshine, parakeet) — it is never silently ignored.
  Future<String> transcribe(Uint8List pcm16kMono, {String? language});

  /// The output language used by [transcribe] calls that pass none.
  ///
  /// Settable, and that is load-bearing: `FlutterEdgeAi.getActiveStt` returns a
  /// process-wide singleton, so if the language were fixed at construction the
  /// second `getActiveStt(language: …)` in a process would hand back the
  /// recognizer built for the FIRST language and transcribe into it with no
  /// error. Retargeting is free here, so there is nothing to invalidate.
  ///
  /// Setting an unusable value must throw [ArgumentError] — a malformed code,
  /// or any code on a model with no language token. `abstract` for exactly that
  /// reason: a plain field cannot validate, and a stored-but-never-read value
  /// is the shape of the bug this whole API exists to fix (#500).
  ///
  /// `null` means the model's own default (`'en'` for Whisper), and assigning
  /// `null` CLEARS a previously set language rather than leaving it in place.
  abstract String? language;

  /// See [InferenceModel.addCloseListener].
  void addCloseListener(void Function() listener);

  /// Close the STT model and release resources.
  Future<void> close();
}

/// Represents a text-to-speech model instance.
///
/// Sibling of [SpeechRecognizer]. Note [sampleRate] is an intentional
/// divergence: STT consumes caller-supplied audio, TTS produces it, so the
/// caller must be told the rate to play it or wrap it in WAV.
abstract class SpeechSynthesizer {
  /// Synthesize [text] to 16-bit little-endian mono PCM at [sampleRate].
  /// Batch (full text → full audio) for now; streaming is a follow-on.
  Future<Uint8List> synthesize(String text);

  /// Output sample rate, Hz.
  int get sampleRate;

  /// See [InferenceModel.addCloseListener].
  void addCloseListener(void Function() listener);

  /// Close the TTS model and release resources.
  Future<void> close();
}
