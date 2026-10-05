/// Built-in OS AI engine for flutter_gemma (Gemini Nano / Apple Foundation
/// Models / Windows AI Foundry / Chrome Prompt API).
///
/// A pure-Dart adapter: every OS backend comes from the standalone
/// `flutter_local_ai` plugin, and this package maps it onto flutter_gemma's
/// engine contracts. There are no platform arms to swap here any more — that
/// split lives in flutter_local_ai — so nothing below is a conditional export.
library;

export 'src/availability.dart' show BuiltInAi;
export 'src/availability_types.dart'
    show BuiltInAiAvailability, BuiltInAiUnavailableException;
export 'src/builtin_ai_engine.dart' show BuiltInAiEngine;
// Claims the `ModelFileType.builtIn` slot so `resolveHuggingFace(...)` says
// "not possible" clearly (no HF file). Auto-registered by BuiltInAiEngine.
export 'src/builtin_ai_hugging_face_resolver.dart'
    show BuiltInAiHuggingFaceResolver;
export 'src/builtin_ai_models.dart' show BuiltInAiModels;
// Exported for their `localAiModel` / `localAiSession` getters only.
// flutter_gemma hands back an `InferenceModel` / `InferenceModelSession`, and
// native tool calling and schema-constrained output have no slot on those
// interfaces, so reaching them means naming the concrete type to cast to.
// Additive: the six names above are unchanged.
export 'src/builtin_ai_model.dart' show BuiltInAiModel;
export 'src/builtin_ai_session.dart' show BuiltInAiSession;
