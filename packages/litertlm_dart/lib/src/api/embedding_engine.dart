// LiteRT-LM's Kotlin/Swift `EmbeddingEngine` for EmbeddingGemma 2 `.litertlm`
// bundles: text, images, audio, or all three in one vector, on the CPU, the
// GPU (where measured) or a per-SoC bundle's NPU, over the runtime's
// LiteRtLmEmbedder.

import 'dart:ffi' show Abi, Allocator;
import 'dart:typed_data' show Float32List, Uint8List;

import 'package:ffi/ffi.dart' show calloc;
import 'package:meta/meta.dart' show immutable;

import '../bundle/litertlm_bundle_info.dart' show NpuStamp, npuVendorOf;
import '../bundle/litertlm_npu_target.dart' show readLiteRtLmNpuTarget;
import '../embedder/embedder_constants.dart'
    show liteRtLmDefaultVisionTokensPerImage;
import '../embedder/embedder_types.dart';
import '../embedder/litert_lm_embedder.dart';
import '../ffi/litert_lm_embedding_bindings.dart'
    show LiteRtLmEmbeddingBindings;
import '../ffi/npu_vendor_host.dart';
import '../runtime/native_hosts.dart'
    show liteRtLmEmbeddingGpuAbis, liteRtLmEmbeddingGpuRefusedAbis;
import 'backend.dart';
import 'engine.dart' show currentEngineHost;
import 'message.dart';

/// What an [EmbeddingEngine] loads, and on what: LiteRT-LM's
/// `EmbeddingEngineConfig`.
@immutable
final class EmbeddingEngineConfig {
  EmbeddingEngineConfig({
    required this.modelPath,
    required this.cacheDir,
    Backend? backend,
    this.visionBackend,
    this.audioBackend,
    this.visionTokensPerImage,
    this.requireWeightCache = false,
  }) : backend = backend ?? const Backend.cpu();

  /// The EmbeddingGemma 2 `.litertlm` bundle.
  final String modelPath;

  /// Where the engine keeps one weight-cache directory per bundle copy. Use a
  /// directory that is not backed up; a purged cache is rebuilt at the next
  /// load.
  final String cacheDir;

  /// The text tower's backend. A per-SoC bundle runs on the NPU only, a
  /// generic one never there; the GPU is honoured where it was measured and
  /// the bundle runs on the CPU elsewhere.
  final Backend backend;

  /// Null: images are not taken. Set: they are, and a bundle without a vision
  /// tower is refused. The towers a bundle has run where it allows (vision on
  /// the CPU beside a GPU text tower, audio on the CPU), so only whether this
  /// is set counts today.
  final Backend? visionBackend;

  /// Null: audio is not taken. Set: it is, and a bundle without an audio
  /// tower is refused.
  final Backend? audioBackend;

  /// Vision tokens per image: 140 (null) or 70.
  final int? visionTokensPerImage;

  /// Refuse a load that leaves no real weight cache behind, instead of
  /// warning.
  final bool requireWeightCache;
}

/// An EmbeddingGemma 2 model, loaded.
final class EmbeddingEngine {
  EmbeddingEngine._(this._embedder, this.info);

  final LiteRtLmEmbedder _embedder;

  /// The dimension, the input limit, the modalities and the backend that
  /// loaded.
  final EmbedderInfo info;

  /// Loads [config.modelPath]. Throws [EmbedderLoadException] for a bundle
  /// that cannot run as asked (never moved to another backend: vectors of an
  /// NPU bundle and of the generic one live in different spaces).
  static Future<EmbeddingEngine> create(EmbeddingEngineConfig config) async =>
      createEmbeddingEngineWith(await embedderConfigFor(config));

  /// The engine's own cache directory, once loaded.
  String? get cacheDir => _embedder.cacheDir;

  /// The embedding of [contents]: at most one text part (its task prefix
  /// already in front), any image parts and at most one audio part, one
  /// vector for all of them. Throws [EmbedderInputTooLongException] for an
  /// input over the limit (never truncated).
  Future<Float32List> computeEmbedding(List<Content> contents) async {
    String? text;
    final images = <Uint8List>[];
    Uint8List? audio;
    for (final part in contents) {
      switch (part) {
        case TextContent(text: final t):
          if (text != null) {
            throw ArgumentError.value(contents, 'contents', 'has two texts');
          }
          text = t;
        case ImageBytesContent(:final bytes):
          images.add(bytes);
        case AudioBytesContent(:final bytes):
          if (audio != null) {
            throw ArgumentError.value(contents, 'contents', 'has two audios');
          }
          audio = bytes;
        case ImageFileContent() || AudioFileContent() || ToolResponseContent():
          throw ArgumentError.value(
            part,
            'contents',
            'an embedding takes text, image bytes and audio bytes',
          );
      }
    }
    final vector = await _embedder.embed(
      EmbedderInput(text: text, images: images, audio: audio),
    );
    return Float32List.fromList(vector);
  }

  /// Deletes the engine.
  Future<void> close() => _embedder.close();
}

/// Where [config] runs, as the embedder's own config: the bundle's NPU
/// stamp, read from its bytes, decides; nothing moves to another backend on
/// its own.
Future<LiteRtLmEmbeddingConfig> embedderConfigFor(
  EmbeddingEngineConfig config,
) async {
  final path = config.modelPath;
  final file = path.split(RegExp(r'[/\\]')).last;
  Never refuse(String message) => throw EmbedderLoadException(message);
  final target = await readLiteRtLmNpuTarget(path);
  final backend = config.backend;
  final abi = '${Abi.current()}';
  var gpu = false;
  String? dispatchDir;
  NpuStamp? npuTarget;
  switch (backend) {
    case CpuBackend():
      if (target != null) {
        refuse('$file is compiled for the $target NPU and runs only there.');
      }
    case GpuBackend():
      if (target != null) {
        refuse('$file is compiled for the $target NPU and runs only there.');
      }
      if (liteRtLmEmbeddingGpuRefusedAbis.contains(abi)) {
        refuse(
          "EmbeddingGemma 2 on the GPU ends the process on $abi with this "
          "release's native libraries; load $file on the CPU.",
        );
      }
      gpu = liteRtLmEmbeddingGpuAbis.contains(abi);
    case NpuBackend(:final platform, dispatchDir: final dir):
      if (target == null) {
        refuse(
          '$file is the generic EmbeddingGemma 2 bundle: it has no NPU graph '
          "and runs on the CPU only. Load the bundle compiled for this "
          "device's SoC to embed on the NPU.",
        );
      }
      final vendor = npuVendorOf(target);
      if (vendor == null) {
        refuse(
          '$file is compiled for a ${target.vendor} NPU, which no '
          'dispatch here runs.',
        );
      }
      npuTarget = target;
      if (dir != null) {
        dispatchDir = dir;
      } else {
        final host = currentEngineHost.npuHost(platform);
        if (await chooseNpuVendor(target: target, host: host) case NpuRefused(
          :final reason,
        )) {
          refuse('$file needs the $target NPU, and $reason.');
        }
        dispatchDir = await host.prepareDispatchDir(vendor);
      }
  }
  final declared = {
    if (config.visionBackend != null) EmbedderModality.image,
    if (config.audioBackend != null) EmbedderModality.audio,
  };
  // The towers a bundle has load with the text tower: vision on the CPU beside
  // a GPU text tower, audio on the CPU everywhere (LiteRT-LM's EG2 audio
  // encoder is compiled for cpu/gpu only).
  final onAccelerator = gpu || npuTarget != null;
  final towers = onAccelerator
      ? readLiteRtLmMediaTowers(path)
      : (vision: false, audio: false);
  return LiteRtLmEmbeddingConfig(
    modelPath: path,
    cacheBase: config.cacheDir,
    declaredMedia: declared,
    numThreads: switch (backend) {
      CpuBackend(:final threadCount) => threadCount,
      _ => null,
    },
    visionTokensPerImage:
        config.visionTokensPerImage ?? liteRtLmDefaultVisionTokensPerImage,
    requireWeightCache: config.requireWeightCache,
    npuTarget: npuTarget,
    npuDispatchDir: dispatchDir,
    gpu: gpu,
    visionTowerOnCpu: gpu && towers.vision,
    audioTowerOnCpu: onAccelerator && towers.audio,
  );
}

/// An [EmbeddingEngine] over the embedder config [config], already placed:
/// for a caller that decides the placement itself, on another isolate (the
/// Flutter adapter places on the app's isolate, where the platform channel
/// that prepares an Android NPU dispatch directory is, and loads on a worker).
/// [openBindings], [allocator] and [clock] are for tests.
Future<EmbeddingEngine> createEmbeddingEngineWith(
  LiteRtLmEmbeddingConfig config, {
  LiteRtLmEmbeddingBindings Function()? openBindings,
  Allocator allocator = calloc,
  DateTime Function()? clock,
}) async {
  final embedder = LiteRtLmEmbedder(
    config,
    openBindings: openBindings,
    allocator: allocator,
    clock: clock,
  );
  return EmbeddingEngine._(embedder, await embedder.load());
}
