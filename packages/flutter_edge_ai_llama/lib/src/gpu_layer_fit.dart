import 'gguf_header.dart';

/// VRAM kept free beyond weights and KV cache, for compute buffers and drivers.
const int gpuHeadroomBytes = 1024 * 1024 * 1024;

/// How many of [shape]'s layers fit in [freeBytes] of VRAM.
///
/// Each layer costs its share of [fileBytes] plus its share of the f16 KV cache
/// for [contextTokens]. The result is between 0 and `shape.blockCount`.
int fitGpuLayers({
  required int freeBytes,
  required int fileBytes,
  required GgufModelShape shape,
  required int contextTokens,
  int headroomBytes = gpuHeadroomBytes,
}) {
  final kvBytes = shape.kvBytesPerToken * contextTokens;
  final perLayerBytes = (fileBytes + kvBytes) ~/ shape.blockCount;
  final usableBytes = freeBytes - headroomBytes;
  final layers = perLayerBytes <= 0 ? 0 : usableBytes ~/ perLayerBytes;
  final capped = layers < 0 ? 0 : layers;
  return capped > shape.blockCount ? shape.blockCount : capped;
}
