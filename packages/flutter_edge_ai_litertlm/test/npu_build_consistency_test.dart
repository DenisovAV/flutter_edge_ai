// The build side of each NPU vendor ([NpuVendor]) agrees with the table: the
// places the compiler cannot reach — the release gate that every native
// tarball passes and the core plugin's AndroidManifest.xml — name what the
// table says. A vendor added to the table without them fails here instead of
// shipping a dispatch no tarball carries or a probe whose dlopen the app's
// linker namespace refuses.

import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

/// `REQUIRED=( … )` of verify_tarball_manifest.sh, as `<tarball>:<path>`.
Set<String> _requiredInTarballs() {
  final script = File(
    'native/litert_lm/verify_tarball_manifest.sh',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final block = RegExp(
    r'^REQUIRED=\(\n(.*?)^\)',
    multiLine: true,
    dotAll: true,
  ).firstMatch(script);
  expect(block, isNotNull, reason: 'REQUIRED=( … ) not found');
  return {
    for (final line in block!.group(1)!.split('\n'))
      if (RegExp(r'^\s*"([^"]+)"').firstMatch(line) case final m?) m.group(1)!,
  };
}

/// The native tarball of [abi]: its `<os>_<arch>` with x64 spelled x86_64, as
/// the hook's `_prebuiltDirName` names it.
String _tarballOf(String abi) => abi.replaceFirst(RegExp(r'_x64$'), '_x86_64');

String _osOf(String abi) => abi.split('_').first;

/// [name] as a file on [os].
String _fileOf(String name, String os) =>
    os == 'windows' ? '$name.dll' : 'lib$name.so';

/// A workflow file with CRLF folded: a Windows checkout may carry either.
String _workflow(String name) => File(
  '../../.github/workflows/$name',
).readAsStringSync().replaceAll('\r\n', '\n');

/// `$ovWanted = @( … )` of a Windows native workflow: the OpenVINO DLLs CI
/// copies into the tarball (TBB is matched by wildcard there, not listed).
Set<String> _ovWanted(String workflow) {
  // Up to the line that is only `)`: the comments inside the list hold
  // parentheses of their own.
  final block = RegExp(
    r'\$ovWanted = @\(\n(.*?)^\s*\)\s*$',
    multiLine: true,
    dotAll: true,
  ).firstMatch(_workflow(workflow));
  expect(block, isNotNull, reason: '\$ovWanted not found in $workflow');
  return {
    for (final line in block!.group(1)!.split('\n'))
      if (RegExp(r"^\s*'([^']+)'").firstMatch(line) case final m?) m.group(1)!,
  };
}

/// The names of `$ovSha256 = @{ … }`: every OpenVINO and TBB DLL the workflow
/// stages, exactly, each with its pinned sha256.
Set<String> _ovPinned(String workflow) {
  final block = RegExp(
    r'\$ovSha256 = @\{\n(.*?)^\s*\}\s*$',
    multiLine: true,
    dotAll: true,
  ).firstMatch(_workflow(workflow));
  expect(block, isNotNull, reason: '\$ovSha256 not found in $workflow');
  return {
    for (final line in block!.group(1)!.split('\n'))
      if (RegExp(r"^\s*'([^']+)' = '[0-9a-f]{64}'$").firstMatch(line)
          case final m?)
        m.group(1)!,
  };
}

const _windowsWorkflows = [
  'build-litertlm-native-windows.yml',
  'build-litertlm-native.yml',
];

void main() {
  test('every vendor\'s dispatch is a required file of the tarball of each of '
      'its ABIs', () {
    final required = _requiredInTarballs();
    for (final vendor in NpuVendor.values) {
      for (final abi in vendor.abis) {
        final entry =
            '${_tarballOf(abi)}:${_fileOf(npuDispatchLib(vendor), _osOf(abi))}';
        expect(required, contains(entry), reason: '${vendor.name} on $abi');
      }
    }
  });

  test('every vendor\'s stack holds its dispatch, on each of its OSes', () {
    for (final vendor in NpuVendor.values) {
      for (final os in {for (final abi in vendor.abis) _osOf(abi)}) {
        expect(
          npuStackLibs(vendor, os),
          contains(npuDispatchLib(vendor)),
          reason: '${vendor.name} on $os',
        );
      }
    }
  });

  test('every system library an Android vendor\'s stack or probe opens is '
      'declared in the core plugin manifest', () {
    final manifest = File(
      '../flutter_edge_ai/android/src/main/AndroidManifest.xml',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final declared = {
      for (final m in RegExp(
        r'<uses-native-library\s+android:name="([^"]+)"',
      ).allMatches(manifest))
        m.group(1)!,
    };
    for (final vendor in NpuVendor.values) {
      final onAndroid = vendor.abis.any((abi) => _osOf(abi) == 'android');
      final libs = npuAndroidSystemLibs(vendor);
      if (!onAndroid) {
        expect(libs, isEmpty, reason: '${vendor.name} does not run on Android');
        continue;
      }
      expect(libs, isNotEmpty, reason: '${vendor.name} needs a device probe');
      expect(declared, containsAll(libs), reason: vendor.name);
    }
  });

  test('a vendor whose stack ships on request names its user_define in the '
      'refusal the runtime prints without it', () {
    // This test does not run the hook. That the hook's vendor loop reads
    // npuUserDefine(vendor) was measured 2026-10-18 on the example's APK:
    // 11 Qualcomm libraries with qualcomm_npu true, none with false.
    for (final vendor in NpuVendor.values) {
      final define = npuUserDefine(vendor);
      final reason = npuNotBundledReason(vendor);
      if (define == null) {
        expect(reason, isNot(contains('user_defines')), reason: vendor.name);
      } else {
        expect(reason, contains('$define: true'), reason: vendor.name);
      }
    }
  });

  test('the OpenVINO DLLs the Windows workflows put in the tarball are the '
      'ones intelNpuLibs bundles into the app', () {
    // One set in two places (npu_stacks.dart): a DLL only in $ovWanted reaches
    // the cache and never the app, as openvino_intel_npu_vm_runtime did.
    final bundled = {
      for (final lib in intelNpuLibs)
        if (lib != intelDispatchLib && !lib.startsWith('tbb')) '$lib.dll',
    };
    for (final workflow in _windowsWorkflows) {
      expect(_ovWanted(workflow), bundled, reason: workflow);
    }
  });

  test('the Windows workflows pin a sha256 for every OpenVINO and TBB DLL '
      'intelNpuLibs bundles, and no other', () {
    // TBB is staged by wildcard: a renamed one would reach the cache and
    // never the app, unless the pinned set names it.
    final bundled = {
      for (final lib in intelNpuLibs)
        if (lib != intelDispatchLib) '$lib.dll',
    };
    for (final workflow in _windowsWorkflows) {
      expect(_ovPinned(workflow), bundled, reason: workflow);
    }
  });

  test('the OpenVINO release the Windows workflows require is the one the '
      'LiteRT patch pins', () {
    final patch = File(
      'native/litert_lm/patches/litert_openvino_2026_4_1.patch',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final version = RegExp(
      r'^\+OPENVINO_PEP440_VERSION = "([^"]+)"',
      multiLine: true,
    ).firstMatch(patch)!.group(1)!;
    final build = RegExp(
      '^\\+.*"windows": ".*_${RegExp.escape(version)}\\.(\\d+)\\.',
      multiLine: true,
    ).firstMatch(patch)!.group(1)!;
    for (final workflow in _windowsWorkflows) {
      expect(
        _workflow(workflow),
        contains("\$ovRelease = '$version-$build'"),
        reason: workflow,
      );
    }
  });
}
