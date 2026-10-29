// The page alignment of an Android shared library, read from its ELF program
// headers. Google Play rejects an app that targets API 35+ and ships a 4 KB
// aligned library, and a 16 KB-page device cannot load one at all, so the
// build hook refuses such a library instead of bundling a dead engine.
import 'dart:io';
import 'dart:typed_data';

/// The page size every `PT_LOAD` segment of an Android library must be aligned
/// to: 16 KB.
const androidPageAlign = 0x4000;

const _ptLoad = 1;

/// The smallest `p_align` among the `PT_LOAD` segments of the 64-bit
/// little-endian ELF in [bytes], or null when it has none.
///
/// Throws [FormatException] when [bytes] is not such a file.
int? smallestLoadAlign(Uint8List bytes) {
  if (bytes.length < 0x40 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 || // E
      bytes[2] != 0x4c || // L
      bytes[3] != 0x46) {
    throw const FormatException('not an ELF file');
  }
  // 2 = 64-bit, 1 = little-endian: all Android arm64 builds.
  if (bytes[4] != 2 || bytes[5] != 1) {
    throw const FormatException('not a 64-bit little-endian ELF file');
  }
  final data = ByteData.sublistView(bytes);
  final phoff = data.getUint64(0x20, Endian.little);
  final phentsize = data.getUint16(0x36, Endian.little);
  final phnum = data.getUint16(0x38, Endian.little);
  if (phentsize < 56 || phoff + phentsize * phnum > bytes.length) {
    throw const FormatException('ELF program headers are out of range');
  }
  int? smallest;
  for (var i = 0; i < phnum; i++) {
    final at = phoff + i * phentsize;
    if (data.getUint32(at, Endian.little) != _ptLoad) continue;
    final align = data.getUint64(at + 48, Endian.little);
    if (smallest == null || align < smallest) smallest = align;
  }
  return smallest;
}

/// Throws [StateError] naming [library] when a `PT_LOAD` segment of it is
/// aligned below 16 KB.
void requireAndroidPageAlign(File library) {
  final bytes = library.readAsBytesSync();
  final int? align;
  try {
    align = smallestLoadAlign(bytes);
  } on FormatException catch (e) {
    throw StateError(
      'flutter_edge_ai_onnx: ${library.path} is not a readable Android '
      'library (${e.message}).',
    );
  }
  if (align != null && align < androidPageAlign) {
    throw StateError(
      'flutter_edge_ai_onnx: ${library.path} has a PT_LOAD segment aligned to '
      '0x${align.toRadixString(16)}, below 16 KB (0x4000). Google Play rejects '
      'such a library for apps that target API 35+, and a 16 KB-page device '
      'cannot load it. Use a build linked with -z max-page-size=16384.',
    );
  }
}
