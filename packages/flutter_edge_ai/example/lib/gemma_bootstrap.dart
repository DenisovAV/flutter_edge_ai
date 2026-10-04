import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_edge_ai_onnx/flutter_edge_ai_onnx.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart' as rag;
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

/// The opt-in inference engines the example registers. Single source of truth —
/// used by [bootstrapGemma] and by the diagnostics screen so the two never
/// drift. The example ships both formats (`.litertlm` + `.task`). The element
/// type (`InferenceEngineProvider`) is inferred from the concrete engines, so
/// the example needn't import the internal provider interface.
const kExampleInferenceEngines = [
  LiteRtLmEngine(),
  MediaPipeEngine(),
  BuiltInAiEngine(),
  OnnxEngine(),
];

/// The opt-in embedding backends the example registers. Single source of
/// truth. `OnnxEmbeddingBackend` (priority 10) outranks
/// `LiteRtEmbeddingBackend`'s catch-all (priority 0) for `.onnx`/`.ort`
/// models — see each backend's `canHandle` doc. Also proves the
/// `flutter_edge_ai_onnx` barrel split (ONNX web PR, `feat/onnx-web`): this
/// single, unbranched registration list compiles for both native
/// (dart:ffi ORT) and web (onnxruntime-web) builds.
const kExampleEmbeddingBackends = [
  LiteRtEmbeddingBackend(),
  OnnxEmbeddingBackend(),
];

/// The tokenizer families the example registers. Separate from the backends
/// above because the choice belongs to the MODEL, not the engine: the same
/// EmbeddingGemma needs SentencePiece whether LiteRT or ONNX Runtime runs it.
/// Supplying it here is also what lets both engine packages stay off
/// `flutter_edge_ai_embeddings` — an app that never embeds registers nothing and
/// does not resolve the package at all.
const kExampleEmbeddingTokenizers = [GemmaEmbeddingTokenizers()];

/// The opt-in STT backends the example registers. Single source of truth.
const kExampleSttBackends = [LiteRtSttBackend()];

/// The opt-in TTS backends the example registers. Single source of truth.
const kExampleTtsBackends = [LiteRtTtsBackend()];

// The Hugging Face resolvers are NOT listed here on purpose: each engine that
// ships one (LiteRtLmEngine → litertlm_manifest.json, OnnxEngine,
// BuiltInAiEngine) implements `HuggingFaceResolverSource`, so
// `FlutterEdgeAi.initialize(inferenceEngines: …)` auto-registers them — no
// parallel `huggingFaceResolvers:` list to keep in sync. So
// `FlutterEdgeAi.resolveHuggingFace(repo, fileType:)` gives a clear result for
// `.litertlm` / `.onnx` / `.builtIn` (MediaPipe `.task`/`.bin` has no resolver,
// so `fileType: task` still throws the generic "no resolver registered").
// Pass `huggingFaceResolvers:` to `initialize` only to OVERRIDE an engine's
// default — e.g. `LitertlmManifestResolver(revision: 'abc123')` to pin a commit.

/// The agentic skill executors the example registers (text / JS / native
/// intent). Registered through `FlutterEdgeAi.initialize(skillExecutors: …)` —
/// the recommended global path — so any [AgentSession.fromModel] built without
/// an explicit `executors:` list picks them up from the core registry. The JS
/// executor resolves each bundled skill's HTML via [AssetSkillSource]; MCP is
/// omitted (no server configured in the demo). The demo screen shows the
/// alternative explicit-list path in a comment.
final kExampleSkillExecutors = <SkillExecutor>[
  TextSkillExecutor(),
  JsSkillExecutor(sourceFor: AssetSkillSource().jsSkillSourceFor),
  NativeIntentExecutor(),
];

/// RAG is instance-scoped and independent from [FlutterEdgeAi.initialize].
/// Each provider creates a fresh store for every opened [rag.RagIndex].
final exampleRag = rag.FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider(), QdrantVectorStoreProvider()],
);

const kRagDemoFilterSchema = rag.FilterSchema(
  fields: [rag.FilterField(name: 'category', type: rag.FilterFieldType.string)],
);

/// The RAG vector-store backends the example can switch between.
enum RagBackend {
  sqlite('sqlite', 'SQLite'),
  qdrant('qdrant', 'Qdrant');

  const RagBackend(this.providerId, this.label);

  final String providerId;
  final String label;

  /// Provider support is probed through its conditional implementation. App
  /// code never needs a platform branch to choose a vector-store class.
  bool get isSupportedOnThisPlatform => exampleRag.canOpen(
    rag.VectorStoreSpec(providerId: providerId, location: 'support-probe'),
  );

  /// One persistent location represents one embedding space. Including the
  /// explicit profile ID prevents a later Gecko/EmbeddingGemma selection from
  /// reopening vectors produced by a different model.
  String storageName(String embeddingProfileId) => switch (this) {
    RagBackend.sqlite => 'rag_demo_sqlite_$embeddingProfileId.db',
    RagBackend.qdrant => 'rag_demo_qdrant_$embeddingProfileId',
  };
}

/// Single source of truth for [FlutterEdgeAi.initialize], called at app startup.
/// RAG indexes have their own lifecycle and never reset this runtime.
///
/// `WebStorageMode.streaming` (OPFS-backed) is required for `.litertlm`
/// web models since flutter_edge_ai 0.16.2 — the @litert-lm/core engine consumes a
/// ReadableStream from OPFS, avoiding Chrome's ~2 GB blob-fetch limit
/// that bites the cacheApi path on Gemma 4 E2B/E4B web variants.
/// MediaPipe `.task` models also work fine under streaming mode.
Future<void> bootstrapGemma() {
  return FlutterEdgeAi.initialize(
    webStorageMode: WebStorageMode.streaming,
    inferenceEngines: kExampleInferenceEngines,
    embeddingBackends: kExampleEmbeddingBackends,
    embeddingTokenizers: kExampleEmbeddingTokenizers,
    sttBackends: kExampleSttBackends,
    ttsBackends: kExampleTtsBackends,
    // huggingFaceResolvers: omitted — resolvers auto-register from the engines
    // above (each implements HuggingFaceResolverSource). See the note there.
    skillExecutors: kExampleSkillExecutors,
  );
}
