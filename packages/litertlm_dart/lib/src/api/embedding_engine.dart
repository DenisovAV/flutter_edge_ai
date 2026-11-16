// LiteRT-LM's Kotlin/Swift `EmbeddingEngine` for EmbeddingGemma 2 `.litertlm`
// bundles: text, images, audio, or all three in one vector, on the CPU, the
// GPU (where measured) or a per-SoC bundle's NPU, over the runtime's
// LiteRtLmEmbedder.

import 'dart:ffi' show Allocator;
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
    show
        LiteRtLmEg2Bundle,
        liteRtLmEmbeddingGpuAbis,
        liteRtLmEmbeddingGpuMeasured,
        liteRtLmEmbeddingGpuRefusedAbis;
import '../runtime/npu_stacks.dart'
    show NpuStack, mediatekNpuRefused, mediatekNpuRefusedReason;
import '../bundle/litertlm_bundle_info.dart' show LiteRtLmBundleException;
import 'dart:io' show FileSystemException;
import '../runtime/types.dart' show BackendKind;
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
  /// generic one never there; the GPU is taken where it was measured, for the
  /// bundles measured there, and refused elsewhere (never moved to the CPU).
  final Backend backend;

  /// Null: images are not taken. Set: they are, and a bundle without a vision
  /// tower is refused. The vision tower runs on the NPU beside an NPU text
  /// tower and on the CPU otherwise; any other backend is refused.
  final Backend? visionBackend;

  /// Null: audio is not taken. Set: it is, and a bundle without an audio
  /// tower is refused. The audio tower runs on the CPU only; any other
  /// backend is refused.
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
  if (config.backend case CpuBackend(
    :final threadCount?,
  ) when threadCount < 1) {
    throw ArgumentError.value(threadCount, 'threadCount', 'must be 1 or more');
  }
  final path = config.modelPath;
  final file = path.split(RegExp(r'[/\\]')).last;
  Never refuse(String message) => throw EmbedderLoadException(message);
  // A file that cannot be read is a load failure, as every refusal here.
  Future<T> read<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on EmbedderLoadException {
      rethrow;
    } on Object catch (e) {
      if (e is! FileSystemException &&
          e is! FormatException &&
          e is! RangeError &&
          e is! LiteRtLmBundleException) {
        rethrow;
      }
      throw EmbedderLoadException(
        '$file is not a readable .litertlm bundle: $e',
        cause: e,
      );
    }
  }

  final target = await read(() => readLiteRtLmNpuTarget(path));
  final backend = config.backend;
  final abi = currentEngineHost.abi;
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
      // Never moved to the CPU: the GPU is honoured where it was measured,
      // for the bundles that ran there, and refused elsewhere.
      if (!liteRtLmEmbeddingGpuAbis.contains(abi)) {
        refuse(
          'EmbeddingGemma 2 runs on the GPU on '
          '${liteRtLmEmbeddingGpuAbis.join(', ')} only, and this is $abi; '
          'load $file on the CPU.',
        );
      }
      final towers = await read(() async => readLiteRtLmMediaTowers(path));
      final bundle = LiteRtLmEg2Bundle.of(
        vision: towers.vision,
        audio: towers.audio,
      );
      final measured = liteRtLmEmbeddingGpuMeasured[abi] ?? const {};
      if (!measured.contains(bundle)) {
        refuse(
          'EmbeddingGemma 2 on the GPU on $abi has run with '
          '${measured.map((b) => b.label).join(' and ')} only; $file is '
          '${bundle.label}, not run on this GPU yet. Load it on the CPU.',
        );
      }
      if (config.visionBackend != null && !towers.vision) {
        refuse('$file has no vision tower: it takes no images.');
      }
      gpu = true;
    case final NpuBackend npu:
      final dir = npu.dispatchDir;
      if (target == null) {
        refuse(
          '$file is the generic EmbeddingGemma 2 bundle: it has no NPU graph '
          "and runs on the CPU only. Load the bundle compiled for this "
          "device's SoC to embed on the NPU.",
        );
      }
      final vendor = npuVendorOf(target);
      if (vendor == null || !NpuStack.forAbi(abi).contains(vendor)) {
        refuse(
          '$file is compiled for the $target NPU, which no dispatch on $abi '
          'runs.',
        );
      }
      if (vendor == NpuStack.mediatek && mediatekNpuRefused) {
        refuse(
          '$file is compiled for the $target NPU: $mediatekNpuRefusedReason.',
        );
      }
      npuTarget = target;
      if (dir != null) {
        dispatchDir = dir;
      } else {
        final host = currentEngineHost.npuHost(npuPlatformOf(npu));
        if (await chooseNpuVendor(target: target, host: host) case NpuRefused(
          :final reason,
        )) {
          refuse('$file needs the $target NPU, and $reason.');
        }
        dispatchDir = await host.prepareDispatchDir(vendor);
      }
  }
  // The towers run where the bundle puts them: vision on the NPU beside an
  // NPU text tower and on the CPU otherwise, audio on the CPU everywhere
  // (LiteRT-LM's EG2 audio encoder is compiled for the CPU and the GPU, and
  // its GPU is not measured). Another backend is refused, never moved.
  final textKind = backendKindOf(backend);
  final visionKind = textKind == BackendKind.npu
      ? BackendKind.npu
      : BackendKind.cpu;
  if (config.visionBackend case final vision?
      when backendKindOf(vision) != visionKind) {
    refuse(
      "$file's vision tower runs on the ${visionKind.name.toUpperCase()} "
      'beside a ${textKind.name.toUpperCase()} text tower, not on the '
      '${backendKindOf(vision).name.toUpperCase()}: pass visionBackend: '
      'Backend.${visionKind.name}().',
    );
  }
  if (config.audioBackend case final audio? when audio is! CpuBackend) {
    refuse(
      "$file's audio tower runs on the CPU only, not on the "
      '${backendKindOf(audio).name.toUpperCase()}: pass audioBackend: '
      'Backend.cpu().',
    );
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
      ? await read(() async => readLiteRtLmMediaTowers(path))
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
