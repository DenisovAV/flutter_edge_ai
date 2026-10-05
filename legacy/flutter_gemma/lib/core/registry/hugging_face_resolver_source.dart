import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver;

/// Opt-in capability interface: an `InferenceEngineProvider` that also ships a
/// Hugging Face manifest [HuggingFaceResolver] for its own model family.
///
/// An engine that implements this exposes its resolver via
/// [huggingFaceResolver], and `FlutterGemma.initialize(inferenceEngines: …)`
/// auto-registers it — so an app that adds the engine gets that engine's
/// `.litertlm` / `.onnx` / `.builtIn` resolver WITHOUT maintaining a parallel
/// `huggingFaceResolvers:` list. The engine and its resolver ship in the same
/// package, so the capability travels with the engine.
///
/// Kept SEPARATE from `InferenceEngineProvider` on purpose (Interface
/// Segregation): putting this getter on the base provider would force every
/// engine — including MediaPipe, which has no HF resolver — to implement it,
/// and (because engines `implements` the provider, so default bodies are not
/// inherited) would be a breaking change to every existing engine, first- and
/// third-party. Instead an engine WITH a resolver opts in
/// (`implements InferenceEngineProvider, HuggingFaceResolverSource`); one
/// without simply does not implement this.
///
/// The engine only POINTS to its resolver here; it does not perform resolution.
/// The manifest IO stays in the standalone [HuggingFaceResolver] (e.g.
/// `LitertlmManifestResolver`), so the engine keeps its single responsibility —
/// this is a reference, not a merge of the two roles.
///
/// Explicit `huggingFaceResolvers:` still wins: `initialize` registers the
/// explicit list FIRST, so an app-supplied resolver overrides an engine's
/// built-in one at equal priority (the registry breaks ties by
/// first-registered). Pass the explicit list only to override an engine's
/// default (e.g. pin a manifest revision or inject a custom fetch).
///
/// An engine that has nothing to resolve does NOT implement this interface — or,
/// if it wants to reserve its `ModelFileType` slot so the caller gets a specific
/// error instead of core's generic "no resolver registered", returns a resolver
/// whose `resolve` throws (the pattern `OnnxHuggingFaceResolver` /
/// `BuiltInAiHuggingFaceResolver` use). Either way is more informative than a
/// `null`, which is why [huggingFaceResolver] is non-nullable.
abstract interface class HuggingFaceResolverSource {
  /// The Hugging Face resolver this engine provides. Non-null: an engine that
  /// implements this interface always contributes a resolver (see the class doc
  /// for how to express "no resolver").
  HuggingFaceResolver get huggingFaceResolver;
}
