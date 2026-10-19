// The embedding engine SPI (R5 §2.2.2, D1/D2/D4): an engine DESCRIBES what to
// run; core builds it, hosts it (a worker isolate on native, inline on the web
// page), validates every request against what it reported, and closes it.

import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';

import 'embedding_input.dart';
import 'embedding_modality.dart';
import 'task_type.dart';

/// What an engine runs: in core's worker isolate on native, inline on the page
/// on web.
///
/// Lifecycle: build → [load] → [embed]* → [close]. Core calls each from one
/// place, one at a time, never concurrently. Engines that tokenize in Dart
/// extend `TokenEmbeddingPass` instead of implementing this directly.
abstract base class EmbeddingPass {
  /// Loads the model and reports what it can do. Called once. On a throw core
  /// calls [close] and reports `EmbeddingLoadException` (an
  /// `EmbeddingLoadException` thrown here keeps its code and message).
  Future<EmbeddingPassInfo> load();

  /// The FINAL vector for [input] — pooled and L2-normalised, of length
  /// `EmbeddingPassInfo.dimension`.
  ///
  /// Core guarantees before calling: [load] succeeded; `input.modalities` is a
  /// subset of the model's modalities; it has one part (one text, one image or
  /// one audio clip) unless `EmbeddingPassInfo.combinedInputs`; every media
  /// part's sniffed format is
  /// in `EmbeddingPassInfo.imageFormats` / `audioFormats`; one call at a time.
  ///
  /// The pass owns tokenization and the prefix: text parts get
  /// `taskType.prefix`, media parts never do. Throws
  /// `EmbeddingInputTooLongException` when the input exceeds
  /// `EmbeddingPassInfo.maxInputTokens`, and `EmbeddingEngineException` for
  /// any other failure (anything else thrown is reported as one).
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType);

  /// Frees everything the pass holds. Called exactly once by core on every
  /// path after construction (load failure, close, host shutdown).
  /// Idempotent; must not throw for a pass that never loaded.
  Future<void> close();
}

/// What a loaded pass can do. Core checks the model's declared media against
/// it at load, and every request against it before the request is sent (D4).
///
/// Sendable: sets of enums and of [EncodedMediaFormat] constants.
final class EmbeddingPassInfo {
  const EmbeddingPassInfo({
    required this.dimension,
    this.modalities = const {EmbeddingModality.text},
    this.maxInputTokens,
    this.imageFormats = const {},
    this.audioFormats = const {},
    this.combinedInputs = false,
    this.visionTokensPerImage,
    this.activeBackend,
  });

  /// Accelerator reported by the loaded runtime, authoritative after load.
  /// A provider advertising GPU through honouredBackends must supply this;
  /// core refuses a missing answer rather than guessing from the descriptor.
  /// Providers using the legacy default retain descriptor fallback.
  final PreferredBackend? activeBackend;

  /// Length of every vector [EmbeddingPass.embed] returns. Must be > 0.
  final int dimension;

  /// What THIS engine version serves for THIS model file.
  final Set<EmbeddingModality> modalities;

  /// Longest input in tokens, prefix and terminators included, that the
  /// loaded engine can accept. Include configured context and single-pass
  /// batch limits; null when no effective limit is known.
  final int? maxInputTokens;

  /// Image containers the engine decodes. Non-empty exactly when
  /// [EmbeddingModality.image] is in [modalities].
  final Set<EncodedMediaFormat> imageFormats;

  /// Audio containers the engine decodes. Non-empty exactly when
  /// [EmbeddingModality.audio] is in [modalities].
  final Set<EncodedMediaFormat> audioFormats;

  /// Whether one input may carry several parts: several modalities (text with
  /// an image, …) or several images.
  final bool combinedInputs;

  /// How many tokens the engine encodes each image into, when that is a
  /// setting of the engine (EmbeddingGemma 2: 140 or 70). The same image gives
  /// another vector under another budget, so whatever stores image vectors
  /// keys them by it. Null when the engine has no such setting or serves no
  /// images; when set, positive and only with [EmbeddingModality.image] in
  /// [modalities].
  final int? visionTokensPerImage;

  @override
  String toString() =>
      'EmbeddingPassInfo(dimension: $dimension, modalities: $modalities, '
      'maxInputTokens: $maxInputTokens, imageFormats: $imageFormats, '
      'audioFormats: $audioFormats, combinedInputs: $combinedInputs, '
      'visionTokensPerImage: $visionTokensPerImage, activeBackend: $activeBackend)';
}

/// Everything core needs to build an engine's [EmbeddingPass], with the
/// engine's own configuration [C] opaque to core (D2): a new engine knob never
/// needs a core release.
///
/// On native the descriptor crosses to the worker isolate, so [config] must be
/// sendable within the isolate group (no `Pointer`, no `ReceivePort`, no open
/// handle), and the factory must be a top-level or static function — a
/// tear-off, never a closure over local state. [build] is the only way core
/// uses the factory; it stays private so a supertype view
/// (`EmbeddingPassDescriptor<Object>`) never reads a contravariant field.
final class EmbeddingPassDescriptor<C extends Object> {
  const EmbeddingPassDescriptor({
    required this.engineTag,
    required EmbeddingPass Function(C config) factory,
    required this.config,
    required this.activeBackend,
  }) : _factory = factory;

  /// The engine's name in messages and errors, e.g. `LiteRT`.
  final String engineTag;

  /// The engine's configuration, handed to the factory.
  final C config;

  /// Pre-load placement claim. The pass's loaded activeBackend takes
  /// precedence. Retained as fallback for providers using the legacy default;
  /// a provider advertising GPU must report placement from load instead.
  /// Null means unknown, never CPU.
  final PreferredBackend? activeBackend;

  final EmbeddingPass Function(C config) _factory;

  /// Builds the pass. Core calls this once, on the isolate that will run it.
  EmbeddingPass build() => _factory(config);
}
