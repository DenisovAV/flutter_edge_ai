import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_hybrid/genkit_hybrid.dart';

// Prod installs the on-device LLM straight from Hugging Face by repo + file
// (the plugin applies the configured token to gated huggingface.co URLs). The
// browser engine only runs dedicated web builds — Gemma 3 1B has none — so on
// web this installs Gemma 4 E2B's public web build instead (~2.0 GB, vs
// ~0.6 GB for the gated native file).
const _hfRepo = kIsWeb
    ? 'litert-community/gemma-4-E2B-it-litert-lm'
    : 'litert-community/Gemma3-1B-IT';
const _hfModelFile = kIsWeb
    ? 'gemma-4-E2B-it-web.litertlm'
    : 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm';
const _modelType = kIsWeb ? ModelType.gemma4 : ModelType.gemmaIt;
const _embeddingModelUrl =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq1024_mixed-precision.tflite';
const _tokenizerUrl =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model';

// Pass at build time: --dart-define=HF_TOKEN=hf_xxx --dart-define=GEMINI_API_KEY=AIza...
const _hfToken = String.fromEnvironment('HF_TOKEN');
const _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

const kLocalModel = 'gemma-3-1b-it';
const kCloudModel = 'gemini-3.7-flash';
const kEmbedder = 'embedding-gemma-300m';

/// Context window for the on-device target, in tokens. `maxTokens` is the
/// WHOLE window (input + output) and genkit_flutter_edge_ai defaults it to 1024.
/// RagService's take(3) of ~600-token city guides alone is ~1.7k tokens —
/// measured on device: "Input token ids are too long … 1713 >= 1024". The
/// bundled Gemma-3-1B `.litertlm` is built for 4096 (`ekv4096`), so use it.
const kOnDeviceContextTokens = 4096;

/// The five routing policies the chat exposes. Each is one genkit_hybrid
/// [RoutePolicy] of the engine's router (see [AiEngine.policyFor]), and
/// carries the UI facts about itself — its label, which targets it needs,
/// whether it is text-only — so the screen renders the dropdown from
/// `PolicyMode.values` instead of restating all five modes by hand.
enum PolicyMode {
  cloud('Cloud', needsLocal: false),
  local('Local', needsCloud: false, textOnly: true),
  smart('Smart (image-aware)'),
  cascade('Cascade (escalate on quality)'),
  budget('Budget (cost-gated)');

  const PolicyMode(
    this.label, {
    this.needsCloud = true,
    this.needsLocal = true,
    this.textOnly = false,
  });

  /// Dropdown text.
  final String label;

  /// Which targets the policy for this mode requires.
  final bool needsCloud;
  final bool needsLocal;

  /// True when every route of the policy ends on the text-only on-device
  /// model, so an attached image cannot be handled (the UI blocks send with a
  /// hint).
  final bool textOnly;

  bool availableWith({required bool cloud, required bool local}) =>
      (!needsCloud || cloud) && (!needsLocal || local);
}

/// The on-device model as a router target sees it: the plugin's model, with
/// the context window the RAG prompt needs as its config. A routed call
/// carries no config of its own — each target owns its own — so this is the
/// one place the window is set, and Gemini never sees it.
ModelRef<FlutterEdgeAiModelOptions> onDeviceModel(String name) =>
    modelRef<FlutterEdgeAiModelOptions>(
      flutterEdgeAi.model(name).name,
      customOptions: FlutterEdgeAiModelOptions.$schema,
      config: FlutterEdgeAiModelOptions(maxTokens: kOnDeviceContextTokens),
    );

/// Owns the app's Genkit instance (the on-device plugin only) and one
/// genkit_hybrid router over the two targets, with one policy per
/// [PolicyMode]. The Gemini plugin is handed to the router alone: the app's
/// Genkit cannot reach the cloud without it.
class AiEngine {
  Genkit? _ai;
  HybridRouter? _router;

  bool cloudReady = false;
  bool localReady = false;

  /// Why the embedding model did not install, or null. The chat screen reads
  /// it before it starts RAG: an app that ran before still has its old
  /// embedder active, and RAG must not quietly run on that one.
  String? embedderError;

  // Budget demo signal: the app counts cloud calls against a small cap.
  int cloudCallsSpent = 0;
  int budgetCap = 3;
  bool get budgetAvailable => cloudCallsSpent < budgetCap;

  AiEngine();

  /// Test seam: skips [FlutterEdgeAi.initialize]/`installModel` (real I/O that
  /// can't run in a unit test). [ai] must already serve [localModel], the
  /// plugin model name, and [cloudPlugin] must resolve [cloudModel]; either
  /// side may be absent. Then it defines the router the way [initialize]
  /// does, so a test driving [router] exercises the real wiring.
  @visibleForTesting
  AiEngine.forTest({
    required Genkit ai,
    String? localModel,
    ModelRef? cloudModel,
    GenkitPlugin? cloudPlugin,
  }) {
    _ai = ai;
    localReady = localModel != null;
    cloudReady = cloudModel != null;
    _defineRouter(
      local: localModel == null ? null : onDeviceModel(localModel),
      cloud: cloudModel,
      cloudPlugins: [?cloudPlugin],
    );
  }

  Genkit get ai {
    final ai = _ai;
    if (ai == null) throw StateError('AiEngine not initialized');
    return ai;
  }

  /// The router every chat message goes through.
  HybridRouter get router {
    final router = _router;
    if (router == null) {
      throw StateError(
        'No router — call initialize() first; it needs at least one of the '
        'on-device model or a cloud API key.',
      );
    }
    return router;
  }

  String get embedderName => kEmbedder;

  Future<void> initialize({
    void Function(int progress)? onProgress,
    // Test seam: install the LLM from a pre-staged local file instead of
    // downloading it — avoids a flaky ~500MB on-device download on CI / remote phones.
    String? localModelPath,
    // Test seam: skip the embedder download when RAG isn't exercised.
    bool downloadEmbedder = true,
  }) async {
    // RAG runs on every platform, web included. The four LiteRT.js files in
    // web/ are copied from flutter_edge_ai_litertlm's own web/, which is where
    // that bundle lives; the WASM runtime behind them is fetched from a CDN, so
    // there is nothing else to host. The only thing left that can turn
    // embeddings off here is the test seam.
    final embeddingsSupported = downloadEmbedder;

    // Building Genkit first keeps `ai` available whatever the installs below
    // do: its plugin list is declarative (no I/O).
    _ai = appGenkit(embedders: embeddingsSupported);

    // CLOUD: needs no install; the key is all it takes.
    cloudReady = _geminiApiKey.isNotEmpty;

    // LOCAL: register the on-device engine, then install the LLM.
    // flutter_edge_ai registers no engines by default; that registration
    // lives inside this try/catch so an engine-init failure only suppresses
    // localReady, never cloud.
    try {
      // Opt into LiteRT-LM (.litertlm inference) and its LiteRT embedding
      // backend, on every platform (see embeddingsSupported above). `webStorageMode:
      // streaming` (OPFS-backed) is what the size demands: the 2.0 GB web
      // build sits right on the ~2 GB blob ceiling the default cacheApi
      // mode would have to buffer it into, so the @litert-lm/core engine
      // reads it from OPFS as a ReadableStream. Ignored on non-web.
      await FlutterEdgeAi.initialize(
        webStorageMode: WebStorageMode.streaming,
        inferenceEngines: [LiteRtLmEngine()],
        embeddingBackends: embeddingsSupported
            ? [LiteRtEmbeddingBackend()]
            : const [],
        // A backend carries no tokenizer: which one a model needs is a
        // property of the model, so the app registers it. Without this the
        // embedder fails to load on Android, iOS and desktop, and the error
        // names the package to add.
        embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
      );

      // fileType MUST be litertlm to match the LiteRT-LM engine registered
      // above.
      final llm = FlutterEdgeAi.installModel(
        modelType: _modelType,
        fileType: ModelFileType.litertlm,
      );
      if (localModelPath != null) {
        await llm.fromFile(localModelPath).install();
      } else {
        await llm
            .fromHuggingFace(
              _hfRepo,
              file: _hfModelFile,
              token: _hfToken.isEmpty ? null : _hfToken,
            )
            .withProgress((p) => onProgress?.call(p)) // p is int 0..100
            .install();
      }
      localReady = true;
    } catch (e) {
      debugPrint('⚠️ AiEngine: on-device backend unavailable — $e');
      localReady = false;
    }

    // EMBEDDER (OPTIONAL): RAG-only, never blocks chat — a
    // failure here must not flip localReady or rethrow.
    if (embeddingsSupported && localReady) {
      try {
        await FlutterEdgeAi.installEmbedder()
            .modelFromNetwork(
              _embeddingModelUrl,
              token: _hfToken.isEmpty ? null : _hfToken,
            )
            .tokenizerFromNetwork(
              _tokenizerUrl,
              token: _hfToken.isEmpty ? null : _hfToken,
            )
            .install();
      } catch (e) {
        debugPrint('⚠️ AiEngine: embedder install failed — $e');
        embedderError = '$e';
      }
    }

    try {
      _defineRouter(
        local: localReady ? onDeviceModel(kLocalModel) : null,
        cloud: cloudReady ? googleAI.gemini(kCloudModel) : null,
        cloudPlugins: [if (cloudReady) googleAI(apiKey: _geminiApiKey)],
      );
    } catch (e) {
      // A policy naming a target the router lacks, say: nothing can be sent,
      // so nothing may look ready.
      cloudReady = false;
      localReady = false;
      rethrow;
    }
  }

  /// The app's Genkit: the on-device plugin ONLY, and no default `model:` —
  /// the router refuses one, because a call that forgot the router would go
  /// there. Gemini goes to the router alone (see [initialize]).
  @visibleForTesting
  static Genkit appGenkit({required bool embedders}) => Genkit(
    plugins: [
      GenkitFlutterEdgeAiPlugin(
        models: [
          FlutterEdgeAiModelConfig(
            name: kLocalModel,
            modelType: _modelType,
            fileType: ModelFileType.litertlm,
          ),
        ],
        embedders: embedders
            ? [FlutterEdgeAiEmbedderConfig(name: kEmbedder)]
            : const [],
      ),
    ],
  );

  /// Defines the router over whichever targets are available, with the
  /// policies of the modes they allow. With neither target there is no router.
  void _defineRouter({
    required ModelRef? local,
    required ModelRef? cloud,
    required List<GenkitPlugin> cloudPlugins,
  }) {
    final targets = {
      // Gemma 3 1B reads text only: declaring no capability keeps an image
      // away from it, so Smart sends a photo to Gemini and never falls back.
      kOnDevice: ?(local == null
          ? null
          : HybridTarget.onDevice(local, supports: const {})),
      kCloud: ?(cloud == null ? null : HybridTarget.cloud(cloud)),
    };
    if (targets.isEmpty) return;
    final policies = {
      for (final mode in PolicyMode.values)
        if (mode.availableWith(cloud: cloud != null, local: local != null))
          mode.name: policyFor(mode),
    };
    _router = defineHybridRouter(
      ai,
      targets: targets,
      cloudPlugins: cloudPlugins,
      policies: policies,
      defaultPolicy: policies.keys.first,
    );
  }

  /// The router's policy name for [mode]; throws a [StateError] when the
  /// mode needs a target this engine does not have.
  String policyName(PolicyMode mode) {
    if (_router?.policies.containsKey(mode.name) ?? false) return mode.name;
    throw StateError(
      'No policy for $mode — call initialize() first (or, if this mode needs '
      'the cloud target, make sure a cloud API key is set).',
    );
  }

  /// Pure mode → [RoutePolicy] mapping (no models needed), so the routing
  /// decisions are unit-testable. Cascade starts on the device; an image
  /// skips it, because the router moves a `prefer` decision past a target
  /// that cannot see to the first fallback that can.
  RoutePolicy policyFor(PolicyMode mode) => switch (mode) {
    PolicyMode.cloud => RoutePolicy(
      rules: [
        RouteRule.custom('cloud', (_) => const RouteDecision.only(kCloud)),
      ],
    ),
    PolicyMode.local => RoutePolicy(
      rules: [
        RouteRule.custom('local', (_) => const RouteDecision.only(kOnDevice)),
      ],
    ),
    // Cloud first, on-device when the cloud fails transiently (offline). An
    // image never falls back: the on-device target declares no vision, so
    // offline + image fails loudly instead of silently dropping the picture.
    // Toward the device any transient failure moves the call, offline
    // included; toward the cloud only an UNAVAILABLE-style Genkit status
    // does, never INTERNAL.
    PolicyMode.smart => RoutePolicy(
      rules: [
        RouteRule.custom(
          'cloud-first',
          (_) => const RouteDecision.prefer(kCloud),
        ),
      ],
      fallback: const [kOnDevice],
    ),
    PolicyMode.cascade => RoutePolicy(
      rules: [
        RouteRule.custom(
          'device-first',
          (_) => const RouteDecision.prefer(kOnDevice),
        ),
      ],
      fallback: const [kCloud],
      // DEMO PROXY — not a real quality signal. A production cascade
      // escalates on model *confidence*; the best training-free signal is
      // the reply's average token log-probability. We can't use it here:
      // LiteRT-LM gives the check only decoded text (no per-token
      // probabilities), and asking a ~1B model to self-rate confidence is
      // unreliable — small models are confidently wrong. So we escalate on a
      // crude "too short to be a real answer" check. See the codelab's
      // "A real cascade signal" note.
      cascade: (result) => result.text.trim().length > 20,
    ),
    PolicyMode.budget => RoutePolicy(
      rules: [
        RouteRule.budget(
          available: () => budgetAvailable,
          premium: kCloud,
          cheap: kOnDevice,
        ),
      ],
      fallback: const [kOnDevice],
    ),
  };

  void dispose() {
    _ai = null;
    _router = null;
  }
}
