import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_edge_ai/engine.dart';
import 'package:llamadart/llamadart.dart' as llama;

import 'gguf_header.dart';
import 'gpu_layer_fit.dart';

/// Layers of [location] to offload to the GPU at [contextTokens].
///
/// Offloading more than fits in free VRAM crashes the driver during the load
/// instead of failing it, so the count is capped to what fits. Returns
/// `ModelParams.maxGpuLayers` when everything fits or when the model or the
/// GPU cannot be measured, which keeps the load as it was before this check.
Future<int> planGpuLayers(String location, int contextTokens) async {
  try {
    final model = await _readShape(location);
    final freeBytes = await _freeDiscreteVram();
    if (freeBytes == null) return llama.ModelParams.maxGpuLayers;
    final layers = fitGpuLayers(
      freeBytes: freeBytes,
      fileBytes: model.fileBytes,
      shape: model.shape,
      contextTokens: contextTokens,
    );
    edgeAiLog(
      'GGUF offload: $layers of ${model.shape.blockCount} layers fit in '
      '$freeBytes free VRAM bytes at $contextTokens context tokens.',
    );
    return layers >= model.shape.blockCount
        ? llama.ModelParams.maxGpuLayers
        : layers;
  } catch (error) {
    edgeAiLog('GPU layer sizing failed, loading all layers on the GPU: $error');
    return llama.ModelParams.maxGpuLayers;
  }
}

Future<({int fileBytes, GgufModelShape shape})> _readShape(String path) async {
  final file = await File(path).open();
  try {
    final fileBytes = await file.length();
    final shape = await readGgufModelShape((offset, length) async {
      await file.setPosition(offset);
      return file.read(length);
    });
    return (fileBytes: fileBytes, shape: shape);
  } finally {
    await file.close();
  }
}

/// Free bytes on the largest discrete GPU that llamadart can see, or null.
Future<int?> _freeDiscreteVram() async {
  // A probe engine: it reads the GPU list without loading a model.
  final engine = llama.LlamaEngine(llama.LlamaBackend());
  try {
    final devices = await engine.listGpuDevices(
      probeBackends: const [llama.GpuBackend.cuda, llama.GpuBackend.vulkan],
    );
    return largestFreeDiscreteVram(devices);
  } finally {
    await engine.dispose();
  }
}

/// The most free memory on any discrete GPU in [devices], or null.
///
/// A device reporting zero free bytes cannot measure its memory, so it is
/// treated as unknown rather than as full.
int? largestFreeDiscreteVram(Iterable<llama.GpuDeviceInfo> devices) {
  final freeBytes = [
    for (final device in devices)
      if (device.isDiscreteGpu && device.memoryFreeBytes > 0)
        device.memoryFreeBytes,
  ];
  if (freeBytes.isEmpty) return null;
  return freeBytes.reduce((best, bytes) => math.max(best, bytes));
}
