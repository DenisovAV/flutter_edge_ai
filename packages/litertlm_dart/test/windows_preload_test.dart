// The Windows client loads libraries into the process before LiteRtLm.dll
// (`windowsPreloadLibraries`), and the hook registers Windows code assets by
// name (`windowsExtraLibs`). Each must be a file the Windows native archive
// ships: a name it does not ship fails every Windows load at startup
// ("Failed to preload …"), and a stale copy of a dropped library would be
// loaded instead. native-v0.19.0-a dropped the TopK WebGPU sampler (section
// 20, CPU sampling on Windows); a preload of it is what this holds off.
@TestOn('vm')
library;

import 'dart:io';

import 'package:litertlm_dart/src/ffi/litert_lm_client.dart'
    show windowsPreloadLibraries;
import 'package:litertlm_dart/src/ffi/native_asset_dir.dart'
    show windowsGpuAssetLibraries;
import 'package:litertlm_dart/src/runtime/npu_stacks.dart' show intelNpuLibs;
import 'package:test/test.dart';

/// The sha256 of the Windows archive [_windowsArchive] lists. The hook's pin
/// must equal it: a native bump that changes the Windows archive fails here
/// until this list is taken again from the new archive.
const _windowsArchiveSha256 =
    'c114569468a5bbe8a68ca48ba1c5ff31a5c96d635042b71ab84cf56ed3c3a1dc';

/// `tar -tzf litertlm-windows_x86_64.tar.gz` of native-v0.19.1-b, the archive
/// of [_windowsArchiveSha256].
const _windowsArchive = {
  'GemmaModelConstraintProvider.dll',
  'LiteRt.dll',
  'LiteRtDispatch.dll',
  'LiteRtLm.dll',
  'LiteRtWebGpuAccelerator.dll',
  'StreamProxy.dll',
  'dxcompiler.dll',
  'dxil.dll',
  'libGemmaModelConstraintProvider.dll',
  'libLiteRt.dll',
  'libLiteRtWebGpuAccelerator.dll',
  'libwebgpu_dawn.dll',
  'openvino.dll',
  'openvino_intel_npu_compiler.dll',
  'openvino_intel_npu_compiler_loader.dll',
  'openvino_intel_npu_plugin.dll',
  'openvino_intel_npu_vm_runtime.dll',
  'openvino_tensorflow_lite_frontend.dll',
  'tbb12.dll',
  'tbbbind_2_5.dll',
  'tbbmalloc.dll',
  'tbbmalloc_proxy.dll',
  'webgpu_dawn.dll',
};

/// The quoted names of the hook's `[field]: [ … ]` list.
List<String> _hookList(String hook, String field) {
  final block = RegExp(
    '  $field: \\[(.*?)\\n  \\],',
    dotAll: true,
  ).firstMatch(hook)!.group(1)!;
  return [
    for (final line in block.split('\n'))
      if (!line.trimLeft().startsWith('//'))
        for (final m in RegExp(r"'([A-Za-z0-9_]+)'").allMatches(line))
          m.group(1)!,
  ];
}

/// The Windows file names verify_tarball_manifest.sh forbids.
Set<String> _forbiddenOnWindows() {
  final script = File(
    'native/litert_lm/verify_tarball_manifest.sh',
  ).readAsStringSync();
  return {
    for (final m in RegExp(r'"windows_x86_64:([^"]+)"').allMatches(script))
      m.group(1)!,
  }..removeAll(_windowsArchive);
}

void main() {
  final hook = File('hook/build.dart').readAsStringSync();

  test('the listing is of the Windows archive the hook pins', () {
    final pinned = RegExp(
      r"'litertlm-windows_x86_64\.tar\.gz':\s*'([0-9a-f]{64})'",
    ).firstMatch(hook)?.group(1);
    expect(pinned, _windowsArchiveSha256);
  });

  test('every Windows preload is a file of the Windows archive', () {
    expect(windowsPreloadLibraries, isNotEmpty);
    expect(_windowsArchive, containsAll(windowsPreloadLibraries));
    expect(windowsPreloadLibraries.last, 'LiteRtLm.dll');
  });

  test('a plain Dart program loads LiteRt, the shader compiler and Dawn '
      'before the GPU accelerator, every one a file of the archive', () {
    final list = windowsGpuAssetLibraries;
    expect(_windowsArchive, containsAll(list));
    expect(list.first, 'LiteRt.dll');
    expect(list.last, 'libLiteRtWebGpuAccelerator.dll');
    // The name LiteRT's GPU registry opens, and the one the app preloads.
    expect(windowsPreloadLibraries, contains(list.last));
    // The accelerator's PE import, and the compiler's runtime dependency.
    expect(
      list,
      containsAll(['webgpu_dawn.dll', 'dxcompiler.dll', 'dxil.dll']),
    );
    expect(list.indexOf('dxil.dll'), lessThan(list.indexOf('dxcompiler.dll')));
    expect(list.toSet(), hasLength(list.length));
  });

  test('the two Windows load lists name their shared libraries in one order, '
      'so a plain Dart program and an app cannot drift apart', () {
    final shared = windowsGpuAssetLibraries
        .where(windowsPreloadLibraries.contains)
        .toList();
    expect(shared, ['LiteRt.dll', 'libLiteRtWebGpuAccelerator.dll']);
    expect(windowsPreloadLibraries.where(shared.contains).toList(), shared);
  });

  test('every Windows extra the hook registers is a file of the archive', () {
    final extras = [
      for (final name in _hookList(hook, 'windowsExtraLibs')) '$name.dll',
      for (final name in intelNpuLibs) '$name.dll',
    ];
    expect(extras, isNotEmpty);
    expect(_windowsArchive, containsAll(extras));
  });

  test('neither names a library the manifest forbids on Windows, the TopK '
      'WebGPU sampler included', () {
    final forbidden = _forbiddenOnWindows();
    expect(forbidden, contains('libLiteRtTopKWebGpuSampler.dll'));
    final named = {
      ...windowsPreloadLibraries,
      ...windowsGpuAssetLibraries,
      for (final name in [
        ..._hookList(hook, 'windowsExtraLibs'),
        ..._hookList(hook, 'companions'),
      ])
        '$name.dll',
    };
    expect(named.intersection(forbidden), isEmpty);
  });

  test('the dropped samplers are never registered (each release tag has a '
      'cache directory of its own, so no stale copy sits beside them)', () {
    expect(
      _hookList(hook, 'companions').where((n) => n.contains('TopK')),
      isEmpty,
    );
  });
}
