// A load the caller gave a prepared NPU dispatch directory: the Intel stack
// is looked for there, not beside the executable (a `dart run` program's
// executable is dart.exe in the SDK), and the directory is the one used.
import 'dart:io';

import 'package:litertlm_dart/src/ffi/native_asset_dir.dart';
import 'package:litertlm_dart/src/ffi/npu_stack_manifest.dart';
import 'package:litertlm_dart/src/ffi/npu_vendor_host.dart';
import 'package:litertlm_dart/src/runtime/npu_stacks.dart';
import 'package:test/test.dart';

/// An app's platform layer whose executable is nowhere near the code assets,
/// as `dart run`'s is (the SDK's dart).
final class _Platform implements NpuPlatform {
  @override
  Future<String> readNativeAssetsManifest() => Future.error('no manifest');
  @override
  Future<String?> prepareAndroidDispatchDir(
    List<String> libFileNames,
    NpuStack vendor,
  ) async => null;
  @override
  String get executableDir => '/nowhere';
}

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
    File(
      '${dir.path}${Platform.pathSeparator}$intelNpuDispatchLib',
    ).writeAsStringSync('');
    expect((await host.stack(NpuStack.intel)).reason, isNull);
    expect(await host.prepareDispatchDir(NpuStack.intel), dir.path);
  });

  test('without a directory the host is used as it is', () async {
    final host = _Host();
    expect(identical(npuHostWithDispatchDir(host, null), host), isTrue);
  });

  test('a Flutter app looks for the NPU stack beside its executable: lib/ on '
      'Linux, the directory itself on Windows', () {
    expect(appNativeLibraryDirOf('linux', '/app'), '/app/lib');
    expect(appNativeLibraryDirOf('windows', r'C:\app'), r'C:\app');
  });

  final hostHasArchive =
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;

  test('under dart test the Intel and the Linux Qualcomm stacks are looked for '
      'in the code assets, not beside the executable', () async {
    final assets = requireNativeAssetDir();
    // No Intel dispatch in this host's code assets (none outside Windows;
    // on Windows the check passes, naming no directory).
    final intel = await npuStackOf(NpuStack.intel, _Platform());
    if (Platform.isWindows) {
      expect(intel.bundled, isTrue);
      expect(
        await prepareNpuDispatchDir(
          NpuStack.intel,
          _Platform(),
          operatingSystem: 'windows',
        ),
        assets,
      );
    } else {
      expect(intel.reason, contains(assets));
      expect(intel.reason, isNot(contains('/nowhere')));
    }
    // Without qualcomm_npu the QNN stack is not among them.
    await expectLater(
      prepareNpuDispatchDir(
        NpuStack.qualcomm,
        _Platform(),
        operatingSystem: 'linux',
      ),
      throwsA(
        isA<Object>().having(
          (e) => '$e',
          'text',
          allOf(contains(assets), isNot(contains('/nowhere'))),
        ),
      ),
    );
  }, skip: hostHasArchive ? false : 'no native archive for this host');
}
