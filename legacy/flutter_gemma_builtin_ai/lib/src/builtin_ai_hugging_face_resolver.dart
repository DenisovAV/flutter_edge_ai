import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver, ResolvedHfModel;

/// [HuggingFaceResolver] for built-in OS models (Gemini Nano / Apple
/// Foundation Models / Chrome Prompt API).
///
/// Built-in models have NO Hugging Face file — the OS owns the weights, and a
/// `ModelFileType.builtIn` install downloads nothing. This resolver claims the
/// `builtIn` slot only so `FlutterGemma.resolveHuggingFace(repo, fileType:
/// ModelFileType.builtIn)` answers with a clear "not possible" error instead
/// of core's generic "no resolver registered" `StateError`.
///
/// [resolve] always throws [UnsupportedError]: there is nothing on Hugging
/// Face to resolve. Install a built-in model with `ModelFileType.builtIn`
/// directly (see `BuiltInAiModels`).
///
/// Auto-registered from `BuiltInAiEngine` (which implements
/// `HuggingFaceResolverSource`), so registering the engine is enough; pass it in
/// `FlutterGemma.initialize(huggingFaceResolvers: [...])` only to override.
class BuiltInAiHuggingFaceResolver implements HuggingFaceResolver {
  const BuiltInAiHuggingFaceResolver();

  @override
  String get name => 'builtin-ai-huggingface';

  @override
  int get priority => 0;

  @override
  bool canResolve(String repo, {ModelFileType? fileType}) =>
      fileType == ModelFileType.builtIn;

  @override
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  }) async {
    throw UnsupportedError(
      'Built-in AI models (Gemini Nano / Apple Foundation Models) are provided '
      'by the OS — there is no Hugging Face file to resolve for "$repo". '
      'Install a built-in model with ModelFileType.builtIn (no download).',
    );
  }
}
