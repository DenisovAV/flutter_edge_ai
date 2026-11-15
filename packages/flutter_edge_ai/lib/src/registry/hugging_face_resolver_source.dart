import 'package:flutter_edge_ai/src/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver;

/// Opt-in capability interface: a provider — an `InferenceEngineProvider`,
/// `EmbeddingBackendProvider`, `SttBackendProvider` or `TtsBackendProvider` —
/// that also ships a Hugging Face [HuggingFaceResolver] for its own models.
///
/// A provider that implements this exposes its resolver via
/// [huggingFaceResolver], and `FlutterEdgeAi.initialize` auto-registers it
/// from any of its four provider lists (`inferenceEngines`,
/// `embeddingBackends`, `sttBackends`, `ttsBackends`) — so an app that adds
/// the provider gets its resolver WITHOUT maintaining a parallel
/// `huggingFaceResolvers:` list. The provider and its resolver ship in the
/// same package, so the capability travels with the provider.
///
/// The resolver must serve the role of the list its provider is passed in
/// ([HuggingFaceResolver.type]: `inference` for an engine, `embedding` for an
/// embedding backend, `stt`, `tts`): `initialize` throws [StateError] naming
/// the provider otherwise. A package with resolvers for two roles carries
/// each on the provider of that role. A provider carries one resolver, so one
/// provider object passed in two role lists (say, as an inference engine and
/// as an embedding backend) fails `initialize` for the list whose role its
/// resolver does not serve.
///
/// Kept SEPARATE from the provider interfaces on purpose (Interface
/// Segregation): putting this getter on a base provider would force every
/// provider — including MediaPipe, which has no HF resolver — to implement
/// it, and (because providers are `implements`ed, so default bodies are not
/// inherited) would be a breaking change to every existing provider, first-
/// and third-party. Instead a provider WITH a resolver opts in
/// (`implements InferenceEngineProvider, HuggingFaceResolverSource`); one
/// without simply does not implement this.
///
/// The provider only POINTS to its resolver here; it does not perform
/// resolution. The manifest IO stays in the standalone [HuggingFaceResolver]
/// (e.g. `LitertlmManifestResolver`), so the provider keeps its single
/// responsibility — this is a reference, not a merge of the two roles.
///
/// Explicit `huggingFaceResolvers:` still wins: `initialize` registers the
/// explicit list FIRST, so an app-supplied resolver overrides a provider's
/// built-in one of the same role at equal priority (the registry breaks ties
/// by first-registered). Pass the explicit list only to override a
/// provider's default (e.g. pin a manifest revision or inject a custom
/// fetch).
///
/// A provider that has nothing to resolve does NOT implement this interface — or,
/// if it wants to reserve its `ModelFileType` slot so the caller gets a specific
/// error instead of core's generic "no resolver registered", returns a resolver
/// whose `resolve` throws (the pattern `OnnxHuggingFaceResolver` /
/// `BuiltInAiHuggingFaceResolver` use). Either way is more informative than a
/// `null`, which is why [huggingFaceResolver] is non-nullable.
abstract interface class HuggingFaceResolverSource {
  /// The Hugging Face resolver this provider ships. Non-null: a provider that
  /// implements this interface always contributes a resolver (see the class doc
  /// for how to express "no resolver").
  HuggingFaceResolver get huggingFaceResolver;
}
