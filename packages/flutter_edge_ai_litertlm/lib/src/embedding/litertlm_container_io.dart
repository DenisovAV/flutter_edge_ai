// The native reader of a `.litertlm` container's section types: the file
// read synchronously from disk (the pass reads it inside core's embedding
// worker, where blocking costs no frame). The parsing is the web-safe
// `litertlm_container.dart`.

import 'dart:io';
import 'dart:typed_data';

import '../litertlm_flatbuffer.dart' show litertlmHeaderEnd;
import 'litertlm_container.dart';

export 'litertlm_container.dart';

/// The `model_type` of every `TFLiteModel` section of [path], lowercased (as
/// LiteRT-LM compares them), in file order. A section without one is left
/// out.
///
/// Throws [FileSystemException] when the file cannot be read and
/// [FormatException] when it is not a `.litertlm` container this reader
/// understands.
List<String> readLitertlmModelTypes(String path) {
  final file = File(path).openSync();
  try {
    final headerEnd = litertlmHeaderEnd(_readExactly(file, 0, 32));
    return litertlmModelTypes(_readExactly(file, 32, headerEnd - 32));
  } finally {
    file.closeSync();
  }
}

Uint8List _readExactly(RandomAccessFile file, int position, int length) {
  file.setPositionSync(position);
  final bytes = file.readSync(length);
  if (bytes.length != length) {
    throw FormatException(
      '.litertlm file ends at ${position + bytes.length}, '
      'expected ${position + length}',
    );
  }
  return bytes;
}
