import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// `kernelBatchSizeFor` decides the #364 flush a GPU load hands LiteRT-LM:
/// 2 on an Adreno, the engine's default (no setter call: `createEngineWith`
/// sets nothing for null) everywhere else (#763).

/// A file system on which `/dev/kgsl-3d0`, Adreno's KGSL node, exists or not.
final class _KgslOverrides extends IOOverrides {
  _KgslOverrides({required this.adreno});

  final bool adreno;
  final probed = <String>[];

  @override
  File createFile(String path) {
    if (path == '/dev/kgsl-3d0') {
      probed.add(path);
      return _Node(path, present: adreno);
    }
    return super.createFile(path);
  }
}

class _Node implements File {
  _Node(this.path, {required this.present});

  @override
  final String path;
  final bool present;

  @override
  bool existsSync() => present;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('$path: ${invocation.memberName}');
}

void main() {
  group('the default probe reads /dev/kgsl-3d0', () {
    test('Android GPU with the node (Adreno): 2', () {
      final fs = _KgslOverrides(adreno: true);
      final batch = IOOverrides.runWithIOOverrides(
        () => kernelBatchSizeFor('gpu', isAndroid: true),
        fs,
      );
      expect(batch, 2);
      expect(fs.probed, ['/dev/kgsl-3d0']);
    });

    test('Android GPU without the node (Mali and others): null, the '
        "engine's default", () {
      final fs = _KgslOverrides(adreno: false);
      final batch = IOOverrides.runWithIOOverrides(
        () => kernelBatchSizeFor('gpu', isAndroid: true),
        fs,
      );
      expect(batch, isNull);
      expect(fs.probed, ['/dev/kgsl-3d0']);
    });
  });

  test('a backend other than the GPU on Android: null, the GPU is not '
      'probed', () {
    for (final backend in ['cpu', 'npu']) {
      expect(
        kernelBatchSizeFor(
          backend,
          isAndroid: true,
          isAdreno: () => fail('probed for $backend'),
        ),
        isNull,
        reason: backend,
      );
    }
  });

  test('off Android: null, the GPU is not probed', () {
    for (final backend in ['gpu', 'cpu', 'npu']) {
      expect(
        kernelBatchSizeFor(
          backend,
          isAndroid: false,
          isAdreno: () => fail('probed off Android for $backend'),
        ),
        isNull,
        reason: backend,
      );
    }
  });
}
