// A load the caller gave a prepared NPU dispatch directory: the Intel stack
// is looked for there, not beside the executable (a `dart run` program's
// executable is dart.exe in the SDK), and the directory is the one used.
import 'dart:io';

import 'package:litertlm_dart/src/ffi/npu_stack_manifest.dart';
import 'package:litertlm_dart/src/ffi/npu_vendor_host.dart';
import 'package:litertlm_dart/src/runtime/npu_stacks.dart';
import 'package:test/test.dart';

final class _Host implements LiteRtLmNpuHost {
  @override
  String get operatingSystem => 'windows';
  @override
  String get abi => 'windows_x64';
  @override
  Future<NpuStackCheck> stack(NpuStack vendor) async =>
      const NpuStackCheck.missing('not beside the executable');
  @override
  String? unreachable(NpuStack vendor) => null;
  @override
  Future<String> prepareDispatchDir(NpuStack vendor) async => '/exe';
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('npu_dispatch_dir'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the Intel stack is checked in the prepared directory', () async {
    final host = npuHostWithDispatchDir(_Host(), dir.path);
    expect((await host.stack(NpuStack.intel)).reason, contains(dir.path));
    File('${dir.path}${Platform.pathSeparator}$intelNpuDispatchLib')
        .writeAsStringSync('');
    expect((await host.stack(NpuStack.intel)).reason, isNull);
    expect(await host.prepareDispatchDir(NpuStack.intel), dir.path);
  });

  test('without a directory the host is used as it is', () async {
    final host = _Host();
    expect(identical(npuHostWithDispatchDir(host, null), host), isTrue);
  });
}
