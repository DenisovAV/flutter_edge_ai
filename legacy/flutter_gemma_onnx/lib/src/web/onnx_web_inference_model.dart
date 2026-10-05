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

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';
import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/core/tool.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart';

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
class OnnxWebInferenceModel extends InferenceModel with CloseNotifier {
  OnnxWebInferenceModel({
    required this.resolver,
    required this.maxTokens,
    required this.modelType,
    this.fileType = ModelFileType.onnx,
    this.preferredBackend,
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

  /// Serializes generation on the single (singleton-lane) session — v1 has
  /// no `openSession`, but the mutex still guards against overlapping
  /// `getResponseAsync` calls on the same session (mirrors every other
  /// engine's "concurrent contexts, serialized inference" posture).
  final Mutex generationMutex = Mutex();

  final VoidCallback onClose;

  TransformersPipeline? _pipeline;
  TransformersTokenizer? _tokenizer;
  Completer<void>? _pipelineCompleter;
  OnnxWebSession? _session;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  @override
  InferenceModelSession? get session => _session;

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
          gemmaLog(
            '[OnnxWebInferenceModel] pipeline(webgpu) failed for $repoId, '
            'retrying on wasm: $e',
          );
        }
        pipe = await _loadPipeline(repoId, device: 'wasm');
        backend = PreferredBackend.cpu;
      }
    }
    if (kDebugMode) {
      gemmaLog(
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
      gemmaLog(
        '[OnnxWebInferenceModel] enableThinking is not driven by this '
        "engine — the repo's own chat_template decides whether/how a "
        'thinking channel is emitted; ignoring.',
      );
    }
    if (tools.isNotEmpty && kDebugMode) {
      gemmaLog(
        '[OnnxWebInferenceModel] Native tool calling is not yet wired on '
        'the Transformers.js path — ignoring ${tools.length} tool(s).',
      );
    }

    // Single-flight guard for concurrent callers; sequential calls fall
    // through and close the previous session before opening a fresh one —
    // same rationale as `OnnxInferenceModel.createSession` (native arm).
    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<InferenceModelSession>();

    try {
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

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      await _session?.close();
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
  Stream<String> getResponseAsync() {
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
    void releaseMutexIfHeld() {
      if (mutexHeld) {
        mutexHeld = false;
        generationMutex.release();
      }
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
        ..setProperty('do_sample'.toJS, false.toJS)
        ..setProperty('streamer'.toJS, streamer)
        ..setProperty('stopping_criteria'.toJS, stoppingCriteria);

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
      try {
        await generationMutex.acquire();
        mutexHeld = true;
        // Cancelled/closed while we were queued behind another turn's lock —
        // release and bail WITHOUT generating.
        if (cancelled || controller.isClosed || _isClosed) {
          releaseMutexIfHeld();
          if (!controller.isClosed) await controller.close();
          return;
        }
        // Snapshot history AFTER acquiring the lock: a turn queued behind a
        // still-running turn must see that turn's appended assistant reply,
        // not a stale pre-reply snapshot.
        final messages = List<Map<String, String>>.from(_history);
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
        }
        if (kDebugMode) {
          gemmaLog(
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
      }
    };
    controller.onCancel = () {
      // Signal only — do NOT release the mutex here. The onListen coroutine
      // owns release in every terminal path; for an in-flight generation the
      // lock must stay held until the Transformers.js Promise SETTLES (via
      // runGeneration), and for a still-queued turn onListen releases right
      // after it acquires and sees `cancelled`. Releasing here would either
      // race a pre-acquire cancel into a deadlock or let a next turn overlap.
      cancelled = true;
      // Interrupt ONLY when THIS stream owns the running generation.
      // `_activeStoppingCriteria` is session-global and points at whichever
      // turn currently holds the mutex; a still-queued stream (mutexHeld ==
      // false) that interrupted it would truncate a DIFFERENT, un-cancelled,
      // actively-running turn. Its own `cancelled = true` still makes its
      // onListen bail right after it acquires.
      if (mutexHeld) _activeStoppingCriteria?.interrupt();
    };
    return controller.stream;
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

  /// Interrupts the in-flight generation at the next token boundary (not
  /// instantaneous — see [InterruptableStoppingCriteria]'s doc). A no-op if
  /// nothing is currently generating.
  @override
  Future<void> stopGeneration() async {
    _activeStoppingCriteria?.interrupt();
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
