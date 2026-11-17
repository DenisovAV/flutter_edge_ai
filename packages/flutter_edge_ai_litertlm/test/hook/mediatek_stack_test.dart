// The MediaTek NPU on LiteRT-LM 0.19 (native-v0.19.1-c): an app that sets
// `mediatek_npu: true` bundles our adapter from the native archive, which
// LiteRT loads, and Google's dispatch from its AAR behind it. These fail if
// the build-time or load-time refusal of 1.20.x comes back.
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart'
    show npuNotBundledReason, mediatekNpuNotEnabledReason;
import 'package:flutter_edge_ai_litertlm/src/runtime/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final hook = File('hook/build.dart').readAsStringSync();

  test('the hook registers the adapter from the native bundle and Google\'s '
      'dispatch from the AAR cache, under the names of the stack', () {
    final start = hook.indexOf('Future<void> _registerMediatekNpu(');
    expect(start, isNot(-1));
    final body = hook.substring(start, hook.indexOf('\n}\n', start));
    expect(
      body,
      allOf(
        contains(
          'final adapter = prebuiltDir.resolve(\n'
          '    _dylibFileName(OS.android, mediatekDispatchLib),\n'
          '  );',
        ),
        contains('mediatekDispatchLib: adapter,'),
        contains(
          'mediatekLegacyDispatchLib: dir.uri.resolve(\n'
          '      _dylibFileName(OS.android, mediatekLegacyDispatchLib),',
        ),
        contains('_ensureMediatekRuntime(input, output)'),
        isNot(contains('Refus')),
      ),
    );
    // The adapter is checked before anything is fetched.
    expect(
      body.indexOf('File.fromUri(adapter).existsSync()'),
      lessThan(body.indexOf('_ensureMediatekRuntime')),
    );
  });

  test('the hook passes it the native bundle on Android', () {
    expect(
      hook,
      contains(
        '      case NpuStack.mediatek when os == OS.android:\n'
        '        await _registerMediatekNpu(\n'
        '          input: input,\n'
        '          output: output,\n'
        '          prebuiltDir: prebuiltDir,\n'
        '          stage: stage,\n'
        '        );',
      ),
    );
  });

  test('the stack is the adapter and the legacy dispatch, and the adapter is '
      'in the native tarball', () {
    expect(mediatekNpuLibs, [mediatekDispatchLib, mediatekLegacyDispatchLib]);
    expect(npuDispatchLib(NpuStack.mediatek), mediatekDispatchLib);
    expect(npuDispatchInNativeTarball(NpuStack.mediatek), isTrue);
  });

  test('at load, a build without the stack is told to opt in', () {
    expect(npuNotBundledReason(NpuStack.mediatek), mediatekNpuNotEnabledReason);
    expect(
      npuNotBundledReason(NpuStack.mediatek),
      contains('$mediatekNpuUserDefine: true\n'),
    );
  });
}
