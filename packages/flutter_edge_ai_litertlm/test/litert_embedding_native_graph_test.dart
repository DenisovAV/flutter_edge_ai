// The native `.tflite` embedding graph on the REAL LiteRT library: a load that
// fails inside a C call must free every pointer it allocated for that call.
// The output pointers used to be freed only after the call succeeded, so a
// failing `.check()` leaked them.
//
// Needs the LiteRT native library on the host (a macOS dev box has it in the
// download cache); skipped where it cannot be opened.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_litertlm/litert_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

/// [calloc], counting what is still allocated.
final class _CountingAllocator implements Allocator {
  int live = 0;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    live++;
    return calloc.allocate<T>(byteCount, alignment: alignment);
  }

  @override
  void free(Pointer<NativeType> pointer) {
    live--;
    calloc.free(pointer);
  }
}

void main() {
  test('a load that fails in createModelFromFile frees every pointer it '
      'allocated', () {
    try {
      LiteRtBindings.open();
    } catch (e) {
      markTestSkipped('LiteRT native library not available here: $e');
      return;
    }
    final allocator = _CountingAllocator();
    final graph = nativeLiteRtEmbeddingGraph(allocator: allocator);

    expect(
      () => graph.open('/nonexistent/flutter_edge_ai/model.tflite'),
      throwsA(anything),
    );
    expect(allocator.live, 0, reason: 'leaked ${allocator.live} pointer(s)');
    graph.close();
  });
}
