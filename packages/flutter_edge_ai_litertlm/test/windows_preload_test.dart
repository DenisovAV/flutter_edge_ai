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

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart'
    show windowsPreloadLibraries;
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart' show intelNpuLibs;
import 'package:flutter_test/flutter_test.dart';

/// `tar -tzf litertlm-windows_x86_64.tar.gz` of native-v0.19.0-a (the L1
/// build the hook's checksum pins). A native bump that changes the Windows
/// archive changes this list with it.
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

  test('every Windows preload is a file of the Windows archive', () {
    expect(windowsPreloadLibraries, isNotEmpty);
    expect(_windowsArchive, containsAll(windowsPreloadLibraries));
    expect(windowsPreloadLibraries.last, 'LiteRtLm.dll');
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
      for (final name in [
        ..._hookList(hook, 'windowsExtraLibs'),
        ..._hookList(hook, 'companions'),
      ])
        '$name.dll',
    };
    expect(named.intersection(forbidden), isEmpty);
  });

  test('the dropped samplers are legacy names: a stale copy is deleted, '
      'never registered', () {
    final legacy = _hookList(hook, 'legacyFileNames');
    expect(
      legacy,
      containsAll([
        'LiteRtTopKWebGpuSampler',
        'libLiteRtTopKWebGpuSampler',
        'LiteRtTopKMetalSampler',
      ]),
    );
    expect(
      _hookList(hook, 'companions').where((n) => n.contains('TopK')),
      isEmpty,
    );
  });
}
