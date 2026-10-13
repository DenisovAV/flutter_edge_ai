import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'island_vector_cache.dart';

/// Native: one file per key in `<app support>/tiny_island/`.
IslandVectorCache createIslandVectorCache() => _FileIslandVectorCache();

final class _FileIslandVectorCache implements IslandVectorCache {
  Future<File> _file(String key) async {
    final support = await getApplicationSupportDirectory();
    final dir = await Directory(
      '${support.path}${Platform.pathSeparator}tiny_island',
    ).create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}$key.f32');
  }

  @override
  Future<Float32List?> read(String key) async {
    final file = await _file(key);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.lengthInBytes % 4 != 0) return null;
    // A float view needs a 4-byte aligned start; copy when it is not.
    final aligned = bytes.offsetInBytes % 4 == 0
        ? bytes
        : Uint8List.fromList(bytes);
    return aligned.buffer.asFloat32List(
      aligned.offsetInBytes,
      aligned.lengthInBytes ~/ 4,
    );
  }

  @override
  Future<void> write(String key, Float32List vectors) async {
    final file = await _file(key);
    // Written aside and renamed: a crash mid-write never leaves a short file
    // under the real name.
    final partial = File('${file.path}.partial');
    await partial.writeAsBytes(
      vectors.buffer.asUint8List(vectors.offsetInBytes, vectors.lengthInBytes),
      flush: true,
    );
    await partial.rename(file.path);
  }
}
