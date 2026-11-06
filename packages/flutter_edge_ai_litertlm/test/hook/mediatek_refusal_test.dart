// The MediaTek NPU is refused in this release (core 2.6.0 decision K): at
// build time, `mediatek_npu: true` fails the hook before it fetches anything;
// at load, a build never carries the stack, so a MediaTek bundle on the NPU
// is refused with the same reason. These fail if the refusal is turned off.
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart'
    show npuNotBundledReason;
import 'package:flutter_edge_ai_litertlm/src/hook/mediatek_runtime.dart'
    show mediatekNpuBuildRefusal;
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mediatek_npu: true fails the build with the reason, the release that '
      'runs it and the define to remove', () {
    final refusal = mediatekNpuBuildRefusal('flutter_edge_ai_litertlm');
    expect(
      refusal,
      allOf(
        startsWith('[flutter_edge_ai_litertlm] mediatek_npu is set'),
        contains('LiteRtDispatchQueryInterface'),
        contains('#4256'),
        contains('flutter_edge_ai_litertlm 1.19.x'),
        contains('remove `mediatek_npu: true`'),
      ),
    );
  });

  test('the hook throws it first thing when it would register the MediaTek '
      'dispatch, before any fetch', () {
    final hook = File('hook/build.dart').readAsStringSync();
    expect(
      hook,
      contains(
        '  required Uri Function(Uri) stage,\n'
        '}) async {\n'
        '  final refusal = mediatekNpuBuildRefusal(_packageName);\n'
        '  if (refusal != null) throw StateError(refusal);\n',
      ),
    );
  });

  test('at load, a build without the stack is refused with the same reason, '
      'not told to opt in', () {
    expect(npuNotBundledReason(NpuStack.mediatek), mediatekNpuRefusedReason);
    expect(
      npuNotBundledReason(NpuStack.mediatek),
      isNot(contains('mediatek_npu: true\n')),
    );
  });

  test('no message offers the MediaTek NPU', () {
    expect(offeredNpuStacks, isNot(contains(NpuStack.mediatek)));
    expect(
      offeredNpuStacks,
      containsAll([NpuStack.qualcomm, NpuStack.googleTensor, NpuStack.intel]),
    );
  });
}
