/// Text-frontend seam: resolves the pipeline-specific frontend (currently
/// only Matcha-CFM's `MatchaTextFrontend`) from a [TtsModelProfile]. The
/// analog of STT's tokenizer seam — `TtsCore` only ever talks to this
/// interface, never to a concrete frontend class.
library;

import '../model/tts_model_profile.dart';
import 'matcha_text_frontend.dart';
import 'tts_frontend_input.dart';

/// Resolves an out-of-dictionary word to its IPA transcription via a neural
/// G2P model (`TtsCore.neuralG2p`), wired in by the worker. A frontend
/// built without a resolver still throws on OOV.
typedef NeuralG2pResolver = String Function(String word);

/// text -> `TtsCore`-ready frontend input, dispatched by
/// [TtsModelProfile.pipeline]. No FFI, pure Dart.
abstract class TtsTextFrontend {
  /// text -> frontend input (symbol embeddings + mask + real length).
  MatchaFrontendInput encode(String chunk);

  /// text -> one or more inputs, each within the model's MAX_TEXT budget
  /// (over-long chunks are word-boundary split). See [MatchaTextFrontend].
  List<MatchaFrontendInput> encodeChunks(String chunk);

  /// Load the frontend for [profile], resolving artifact paths from
  /// [paths] (keyed by the profile's file-role names, e.g.
  /// `paths[profile.configFile]`).
  static Future<TtsTextFrontend> load(
    TtsModelProfile profile,
    Map<String, String> paths, {
    NeuralG2pResolver? neuralG2p,
  }) => switch (profile) {
    MatchaProfile p => MatchaTextFrontend.load(p, paths, neuralG2p: neuralG2p),
    // Qwen3 does its own BPE tokenization (`Qwen2BpeEncoder` +
    // `Qwen3Prompt`) and is driven by `Qwen3TtsCore`, not this
    // Matcha-only frontend seam — the worker (`_runQwen3Worker`) dispatches
    // to it directly and never calls `TtsTextFrontend.load` for this pipeline
    // kind. Fail-loud rather than silently running Matcha's phoneme
    // frontend against a Qwen3 bundle.
    Qwen3Profile() => throw StateError(
      'TtsTextFrontend: qwen3ArCodec is handled by Qwen3TtsCore, not the '
      'Matcha TtsTextFrontend path.',
    ),
    // Inflect maps IPA to RAW token ids (no blank-interspersing / embedding
    // gather), so it has its own `InflectTextFrontend` (List<int> ids, not a
    // MatchaFrontendInput) and is dispatched by the worker directly — this
    // Matcha-shaped seam is the wrong return type for it.
    InflectProfile() => throw StateError(
      'TtsTextFrontend: inflectVits is handled by InflectTextFrontend, not the '
      'Matcha TtsTextFrontend path.',
    ),
  };
}
