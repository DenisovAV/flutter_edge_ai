import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_gemma_litertlm/litert_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors the static_asserts upstream added to litert/c/litert_layout.h in
// LiteRT d84656955: LiteRtLayout has one layout on every compiler. The MSVC
// mirror we kept after that fix put shapes 4 bytes off on Windows, which
// failed CreateTensorBufferFromHostMemory with status 3.
void main() {
  test('LiteRtLayout is 68 bytes with dimensions at offset 4', () {
    expect(sizeOf<LiteRtLayoutPosix>(), 68);

    final layout = calloc<LiteRtLayoutPosix>();
    try {
      layout.ref.dimensions[0] = 0x11223344;
      // Word 0 holds rank + has_strides, so dimensions[0] is word 1.
      expect(layout.cast<Int32>()[1], 0x11223344);
    } finally {
      calloc.free(layout);
    }
  });

  test('LiteRtRankedTensorType is 72 bytes', () {
    expect(sizeOf<LiteRtRankedTensorTypePosix>(), 72);
  });

  test('the tensor type view writes where LiteRT reads', () {
    final type = LiteRtRankedTensorTypeView.calloc()
      ..elementType = kLiteRtElementTypeInt32
      ..rank = 2
      ..setDimension(0, 1)
      ..setDimension(1, 256);
    try {
      final words = type.pointer.cast<Int32>();
      expect(words[0], kLiteRtElementTypeInt32);
      expect(words[1] & 0x7f, 2);
      expect(words[2], 1);
      expect(words[3], 256);
    } finally {
      type.free();
    }
  });
}
