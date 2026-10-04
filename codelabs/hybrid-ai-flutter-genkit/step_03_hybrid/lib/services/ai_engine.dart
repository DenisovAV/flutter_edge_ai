import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart' show GenkitPlugin;
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
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerUrl =
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model';

// Pass at build time: --dart-define=HF_TOKEN=hf_xxx --dart-define=GEMINI_API_KEY=AIza...
const _hfToken = String.fromEnvironment('HF_TOKEN');
const _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

const kLocalModel = 'gemma-3-1b-it';
const kCloudModel = 'gemini-3.7-flash';
const kEmbedder = 'embedding-gemma-300m';

/// Context window for the on-device branch, in tokens. `maxTokens` is the
/// WHOLE window (input + output) and genkit_flutter_edge_ai defaults it to 1024.
/// RagService's take(3) of ~600-token city guides alone is ~1.7k tokens —
/// measured on device: "Input token ids are too long … 1713 >= 1024". The
/// bundled Gemma-3-1B `.litertlm` is built for 4096 (`ekv4096`), so use it.
const kOnDeviceContextTokens = 4096;

/// The five routing policies the chat exposes. Each maps to one genkit_hybrid
/// construct (see [modelFor] / [strategyFor]), and carries the UI facts about
/// itself — its label, which branches it needs, whether it is text-only — so
/// the screen renders the dropdown from `PolicyMode.values` instead of
/// restating all five modes by hand.
enum PolicyMode {
  cloud('Cloud', needsLocal: false),
  local('Local', needsCloud: false, textOnly: true),
  smart('Smart (image-aware)'),
  cascade('Cascade (escalate on quality)', textOnly: true),
  budget('Budget (cost-gated)');

  const PolicyMode(
    this.label, {
    this.needsCloud = true,
    this.needsLocal = true,
    this.textOnly = false,
  });

  /// Dropdown text.
  final String label;

  /// Which branches the composite for this mode requires.
  final bool needsCloud;
  final bool needsLocal;

  /// True when the primary route starts on the text-only on-device model, so
  /// an attached image cannot be handled (the UI blocks send with a hint).
  final bool textOnly;

  bool availableWith({required bool cloud, required bool local}) =>
      (!needsCloud || cloud) && (!needsLocal || local);
}

/// Owns a single Genkit instance with both plugins (cloud + on-device),
/// resolves the two base models, and composes them via genkit_hybrid per the
/// selected [PolicyMode]. Replaces the old Cloud/Local/HybridAIService trio.
class AiEngine {
  Genkit? _ai;
  Model? _local;
  Model? _cloud;

  /// One composite [Model] per policy, built AND registered once by
  /// [_registerPolicyModels] — genkit reduces `generate(model: ...)` to the
  /// model's name and looks it up in the registry, so a freshly built,
  /// never-registered composite would fail every call with NOT_FOUND.
  final Map<PolicyMode, Model> _models = {};

  bool cloudReady = false;
  bool localReady = false;

  // CostStrategy demo signal: the app counts cloud calls against a small cap.
  int cloudCallsSpent = 0;
  int budgetCap = 3;
  bool get budgetAvailable => cloudCallsSpent < budgetCap;

  AiEngine();

  /// Test seam: skips [FlutterEdgeAi.initialize]/`installModel` (real I/O that
  /// can't run in a unit test) and takes already-resolved branch models
  /// directly, then runs the same build+register path [initialize] uses — so
  /// a test driving [modelFor] through `ai.generate` here exercises the real
  /// registration wiring, not just [strategyFor]. [local] is nullable —
  /// mirrors [cloud] — so a cloud-only engine (the symmetric mirror of the
  /// cloud-absent case) is constructible too.
  @visibleForTesting
  AiEngine.forTest({required Genkit ai, Model? local, Model? cloud}) {
    _ai = ai;
    _local = local == null ? null : _withContextBudget(local);
    _cloud = cloud;
    localReady = local != null;
    cloudReady = cloud != null;
    _registerPolicyModels();
  }

  Genkit get ai {
    final ai = _ai;
    if (ai == null) throw StateError('AiEngine not initialized');
    return ai;
  }

  String get embedderName => kEmbedder;

  Future<void> initialize({
    void Function(int progress)? onProgress,
    // Test seam: install the LLM from a pre-staged local file instead of
    // downloading it — avoids a flaky ~500MB on-device download on CI / FTL.
    String? localModelPath,
    // Test seam: skip the embedder download when RAG isn't exercised.
    bool downloadEmbedder = true,
  }) async {
    // RAG runs on every platform, web included. The four LiteRT.js files in
    // web/ come from flutter_edge_ai_litertlm 1.8.0, which is where that bundle
    // lives; the WASM runtime behind them is fetched from a CDN, so there is
    // nothing else to host. The only thing left that can turn embeddings off
    // here is the test seam.
    final embeddingsSupported = downloadEmbedder;

    // Declarative plugin config — always includes the on-device plugin (its
    // models/embedders are looked up by name later, independent of whether
    // the install below actually succeeds).
    final plugins = <GenkitPlugin>[
      if (_geminiApiKey.isNotEmpty) googleAI(apiKey: _geminiApiKey),
      GenkitFlutterEdgeAiPlugin(
        models: [
          FlutterEdgeAiModelConfig(
            name: kLocalModel,
            modelType: _modelType,
            fileType: ModelFileType.litertlm,
          ),
        ],
        embedders: embeddingsSupported
            ? [FlutterEdgeAiEmbedderConfig(name: kEmbedder)]
            : const [],
      ),
    ];

    // Build Genkit BEFORE any on-device engine registration/install so `_ai`
    // (and `_resolve`, and the `ai` getter) are always available afterward —
    // the plugin list above is purely declarative (no I/O, no dependency on
    // FlutterEdgeAi.initialize() having run), so cloud resolution below needs
    // no on-device engine and must not be taken down by a failure
    // registering/installing it.
    _ai = Genkit(plugins: plugins);

    // CLOUD: needs no install, so its readiness never depends on the local
    // LLM or the (optional) embedder below.
    if (_geminiApiKey.isNotEmpty) {
      try {
        _cloud = await _resolve(googleAI.gemini(kCloudModel));
        cloudReady = true;
      } catch (e) {
        debugPrint('⚠️ AiEngine: CLOUD backend unavailable — $e');
        cloudReady = false;
      }
    }

    // LOCAL: register the on-device engine, then install + resolve the LLM.
    // flutter_edge_ai 1.x registers no engines by default; that registration
    // now lives inside this try/catch (not before Genkit is built) so an
    // engine-init failure only suppresses localReady, never cloud.
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
        // Since flutter_edge_ai 1.9.0 a backend no longer carries a tokenizer:
        // which one a model needs is a property of the model, so the app
        // registers it. Without this the first embedding throws a StateError.
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
      _local = _withContextBudget(
        await _resolve(flutterEdgeAi.model(kLocalModel)),
      );
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
        debugPrint('⚠️ AiEngine: embedder install failed, RAG disabled — $e');
      }
    }

    _registerPolicyModels();
  }

  // A plugin model is registered by name; genkit's `Model` is an `Action`, so
  // look the concrete model up from the registry and cast.
  Future<Model> _resolve(ModelRef ref) async {
    final action = await ai.registry.lookupAction(ActionType.model, ref.name);
    if (action == null) {
      throw StateError('model "${ref.name}" is not registered');
    }
    return action as Model;
  }

  /// Wraps the on-device branch so every request carries the context budget
  /// unless the caller set one. Copies the request rather than mutating it:
  /// genkit_hybrid hands the SAME ModelRequest to the next branch when
  /// cascade escalates, so an in-place write would leak a Gemma-only
  /// maxTokens into the Gemini call. The metadata copy is required too —
  /// genkit's Model constructor writes into the map it is handed.
  Model _withContextBudget(Model inner) => Model(
    name: '${inner.name}/ctx',
    metadata: {...inner.metadata},
    fn: (request, context) {
      if (request == null || request.config?['maxTokens'] != null) {
        return inner.fn(request, context);
      }
      final budgeted = ModelRequest.fromJson({
        ...request.toJson(),
        'config': {...?request.config, 'maxTokens': kOnDeviceContextTokens},
      });
      return inner.fn(budgeted, context);
    },
  );

  Map<String, Model> get _branches => {kOnDevice: ?_local, kCloud: ?_cloud};

  /// Builds AND registers one composite [Model] per [PolicyMode] whose
  /// required branches are available, populating [_models]. A mode that needs
  /// `kCloud` (every mode but `local`) is skipped when there's no API key, so
  /// a missing cloud branch degrades to a clear [modelFor] error instead of
  /// crashing here on a half-built `cascadeModel` (its `order` validates
  /// eagerly against `branches`, unlike `hybridModel`).
  void _registerPolicyModels() {
    for (final mode in PolicyMode.values) {
      if (!mode.availableWith(cloud: _cloud != null, local: _local != null)) {
        continue;
      }
      final model = _buildModel(mode);
      ai.registry.register(model);
      _models[mode] = model;
    }
  }

  /// The composable Genkit `Model` for [mode]. Cascade is a `cascadeModel`;
  /// every other mode is `hybridModel(strategy: strategyFor(mode))`. Called
  /// once per mode by [_registerPolicyModels] — not a per-request factory.
  Model _buildModel(PolicyMode mode) {
    if (mode == PolicyMode.cascade) {
      return cascadeModel(
        branches: _branches,
        order: const [kOnDevice, kCloud],
        // DEMO PROXY — not a real quality signal. A production cascade
        // escalates on model *confidence*; the best training-free signal is
        // the reply's average token log-probability. We can't use it here:
        // LiteRT-LM gives `accept` only decoded text (no per-token
        // probabilities), and asking a ~1B model to self-rate confidence is
        // unreliable — small models are confidently wrong. So we escalate on a
        // crude "too short to be a real answer" check. See the codelab's
        // "A real cascade signal" note.
        accept: (r) => r.text.trim().length > 20,
        name: 'cascade',
      );
    }
    return hybridModel(
      branches: _branches,
      strategy: strategyFor(mode),
      name: mode.name,
    );
  }

  /// The registered, resolvable `Model` for [mode] — built once by
  /// [_registerPolicyModels] during [initialize] (or [AiEngine.forTest]).
  Model modelFor(PolicyMode mode) {
    final model = _models[mode];
    if (model == null) {
      throw StateError(
        'No model registered for $mode — call initialize() first (or, if '
        'this mode needs the cloud branch, make sure a cloud API key is set).',
      );
    }
    return model;
  }

  /// Pure policy → RoutingStrategy mapping (no models needed), so the routing
  /// decisions are unit-testable. [PolicyMode.cascade] has no strategy — it is
  /// a Model, built in [_buildModel].
  RoutingStrategy strategyFor(PolicyMode mode) {
    switch (mode) {
      case PolicyMode.cloud:
        return PreRoutingStrategy((_) => kCloud);
      case PolicyMode.local:
        return PreRoutingStrategy((_) => kOnDevice);
      case PolicyMode.smart:
        // Image → cloud only (only it declares vision). Text → both qualify,
        // cloud-first in `supports` insertion order, on-device as the tail.
        // No WithFallback: CapabilityStrategy already yields the on-device
        // tail for text, and for an image a forced on-device tail would hand
        // the picture to a model that cannot see it. Offline + image should
        // fail loudly, not silently degrade to text-only.
        return CapabilityStrategy(
          supports: {
            kCloud: {ModelCapability.vision},
            kOnDevice: <ModelCapability>{},
          },
        );
      case PolicyMode.budget:
        return CostStrategy(
          budgetAvailable: () => budgetAvailable,
          premium: kCloud,
          cheap: kOnDevice,
        );
      case PolicyMode.cascade:
        throw ArgumentError('cascade has no RoutingStrategy; use modelFor');
    }
  }

  void dispose() {
    _ai = null;
    _local = null;
    _cloud = null;
    _models.clear();
  }
}
