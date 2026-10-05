// Pure `ModelSource` -> Transformers.js repo-id mapping, split out of
// `TransformersWebResolver` on purpose: this file has NO web-only imports
// (only core's `ModelSource` domain), so it — unlike the resolver, which
// transitively imports the web-only `WebModelManager` — CAN be unit-tested on
// the VM (`flutter test`). See `test/web/transformers_repo_id_test.dart`.
import 'package:flutter_gemma/core/domain/model_source.dart';

/// Maps a [ModelSource] to the Transformers.js (`@huggingface/transformers`)
/// repo id it identifies:
///
/// - [NetworkSource] whose url is `https://huggingface.co/<owner>/<name>`
///   (any path/query suffix beyond the first two segments is ignored) → repo
///   id `<owner>/<name>`.
/// - [BundledSource] → its `resourceName` verbatim — a self-hosted / local id
///   (served from the app's own origin via Transformers.js's
///   `env.localModelPath`). Note [BundledSource] forbids `/`, so this is a
///   single flat id, not an `<owner>/<name>` pair; use a [NetworkSource] HF
///   URL for the owner/name form.
/// - [AssetSource] / [FileSource] → not meaningful Transformers.js repo
///   identities; throws [UnsupportedError] with actionable guidance.
String transformersRepoIdFromSource(ModelSource source) {
  return switch (source) {
    NetworkSource(:final url) => _repoIdFromHuggingFaceUrl(url),
    BundledSource(:final resourceName) => resourceName,
    AssetSource() || FileSource() => throw UnsupportedError(
      'ONNX web text generation identifies its model by Hugging Face repo id '
      '(NetworkSource) or a self-hosted id (BundledSource); got a '
      '${source.runtimeType}. Use FlutterGemma.installModel().fromNetwork('
      "'https://huggingface.co/<owner>/<name>') or .fromBundled('<owner>/"
      "<name>').",
    ),
  };
}

String _repoIdFromHuggingFaceUrl(String url) {
  final uri = Uri.parse(url);
  if (uri.host != 'huggingface.co' || uri.pathSegments.length < 2) {
    throw ArgumentError(
      'Not a Hugging Face repo URL for ONNX web text generation: "$url". '
      'Expected https://huggingface.co/<owner>/<name>.',
    );
  }
  return '${uri.pathSegments[0]}/${uri.pathSegments[1]}';
}
