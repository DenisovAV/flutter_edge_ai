@TestOn('vm')
library;

import 'package:flutter_edge_ai_llama/src/gguf_header.dart';
import 'package:flutter_edge_ai_llama/src/gpu_layer_fit.dart';
import 'package:flutter_edge_ai_llama/src/gpu_layer_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;

const _gib = 1024 * 1024 * 1024;

// Ministral-3-8B-Instruct-2512 Q5_K_M: 34 layers, 8 KV heads, head dim 128.
const _ministral = GgufModelShape(
  blockCount: 34,
  kvBytesPerToken: 34 * 8 * (128 + 128) * 2,
);
const _ministralFileBytes = 6060000000;

// RTX 2060 SUPER 8 GB with about 5.4 GiB free.
const _rtx2060FreeBytes = 5798205850;

llama.GpuDeviceInfo _device(llama.GpuDeviceType type, int freeBytes) =>
    llama.GpuDeviceInfo(
      backend: llama.GpuBackend.vulkan,
      mainGpu: 0,
      name: 'Test GPU',
      description: 'Test GPU',
      deviceId: '',
      type: type,
      memoryFreeBytes: freeBytes,
      memoryTotalBytes: freeBytes,
    );

int _fit({
  required int freeBytes,
  required int contextTokens,
  GgufModelShape shape = _ministral,
  int fileBytes = _ministralFileBytes,
  int headroomBytes = gpuHeadroomBytes,
}) => fitGpuLayers(
  freeBytes: freeBytes,
  fileBytes: fileBytes,
  shape: shape,
  contextTokens: contextTokens,
  headroomBytes: headroomBytes,
);

void main() {
  test('fits 15 of 34 layers at 32768 tokens on the 8 GB card', () {
    expect(_fit(freeBytes: _rtx2060FreeBytes, contextTokens: 32768), 15);
  });

  test('keeps every layer when weights and KV cache fit', () {
    expect(_fit(freeBytes: 12 * _gib, contextTokens: 32768), 34);
  });

  test('a shorter context leaves room for more layers', () {
    expect(_fit(freeBytes: _rtx2060FreeBytes, contextTokens: 4096), 24);
  });

  test('no layer fits when free VRAM is within the headroom', () {
    expect(_fit(freeBytes: gpuHeadroomBytes, contextTokens: 4096), 0);
    expect(_fit(freeBytes: 0, contextTokens: 4096), 0);
  });

  test('headroom is subtracted from free VRAM', () {
    final withHeadroom = _fit(
      freeBytes: _rtx2060FreeBytes,
      contextTokens: 32768,
    );
    final withoutHeadroom = _fit(
      freeBytes: _rtx2060FreeBytes,
      contextTokens: 32768,
      headroomBytes: 0,
    );
    expect(withoutHeadroom, greaterThan(withHeadroom));
  });

  test('picks the most free discrete GPU, never an integrated one', () {
    final devices = [
      _device(llama.GpuDeviceType.discreteGpu, 3 * _gib),
      _device(llama.GpuDeviceType.discreteGpu, 6 * _gib),
      _device(llama.GpuDeviceType.integratedGpu, 12 * _gib),
    ];

    expect(largestFreeDiscreteVram(devices), 6 * _gib);
  });

  test('reports unknown when no discrete GPU measures its memory', () {
    final devices = [
      _device(llama.GpuDeviceType.integratedGpu, 12 * _gib),
      _device(llama.GpuDeviceType.discreteGpu, 0),
    ];

    expect(largestFreeDiscreteVram(devices), isNull);
    expect(largestFreeDiscreteVram(const []), isNull);
  });

  test('more free VRAM never fits fewer layers', () {
    var previous = 0;
    for (var free = 0; free <= 12 * _gib; free += 256 * 1024 * 1024) {
      final layers = _fit(freeBytes: free, contextTokens: 32768);
      expect(layers, greaterThanOrEqualTo(previous));
      expect(layers, inInclusiveRange(0, 34));
      previous = layers;
    }
  });
}
