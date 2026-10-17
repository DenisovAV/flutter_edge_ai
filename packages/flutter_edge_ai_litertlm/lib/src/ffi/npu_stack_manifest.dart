import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show rootBundle;

import '../npu_stacks.dart';

/// Whether this build carries a vendor's NPU stack ([NpuVendor]) where LiteRT
/// will load it, and why not: from NativeAssetsManifest.json for a stack the
/// build registers ([checkNpuStackInManifest]; Qualcomm on Android and Linux
/// arm64), by file presence for Intel's beside the Windows executable
/// (`checkIntelNpuStack`). The LLM engine and the EmbeddingGemma 2 placement
/// both ask, through `npuStackOf`.
final class NpuStackCheck {
  const NpuStackCheck.bundled() : bundled = true, known = true, reason = null;
  const NpuStackCheck.missing(String this.reason)
    : bundled = false,
      known = true;

  /// The manifest could not answer (no Flutter binding in this isolate, a
  /// format this version does not know). Not a "no": the npu attempt goes
  /// ahead, and core's prepareNpuDispatchDir — which checks every library in
  /// the APK before anything is loaded — turns a missing stack into the
  /// fallback instead.
  const NpuStackCheck.unknown(String this.reason)
    : bundled = false,
      known = false;

  final bool bundled;

  /// Whether the manifest answered at all; see [NpuStackCheck.unknown].
  final bool known;

  /// Why npu cannot run on account of the build, or why that is unknown; null
  /// when [bundled].
  final String? reason;
}

/// Reads `flutter_assets/NativeAssetsManifest.json`.
typedef NativeAssetsManifestReader = Future<String> Function();

Future<String> _readFromBundle() =>
    rootBundle.loadString('NativeAssetsManifest.json', cache: false);

final _cached = <NpuVendor, NpuStackCheck>{};

/// Whether this build registered [vendor]'s NPU stack on [operatingSystem]
/// ([npuStackLibs]).
///
/// The authority is `NativeAssetsManifest.json`, which Flutter regenerates on
/// every build and the engine itself reads at startup to resolve native
/// assets: it lists exactly the assets this build's hooks registered. File
/// presence is not an answer — on Windows stale DLLs outlive a rebuild, and
/// on Android a Play install keeps the libraries in a config split.
///
/// Only a successful read is cached. A failed read is not an answer about the
/// build either, so it is [NpuStackCheck.unknown], not "not enabled".
Future<NpuStackCheck> checkNpuStackInManifest(
  NpuVendor vendor, {
  NativeAssetsManifestReader? read,
  String? abi,
  String? operatingSystem,
}) async {
  final stack = npuStackLibs(
    vendor,
    operatingSystem ?? Platform.operatingSystem,
  );
  if (read == null && _cached[vendor] != null) return _cached[vendor]!;
  final String text;
  try {
    text = await (read ?? _readFromBundle)();
  } on Object catch (e) {
    return NpuStackCheck.unknown(
      'NativeAssetsManifest.json could not be read ($e), so whether this '
      'build bundles the ${vendor.label} NPU stack is unknown',
    );
  }
  final NpuStackCheck result;
  try {
    final assets =
        ((jsonDecode(text) as Map)['native-assets'] as Map?)?[abi ??
                Abi.current().toString()]
            as Map?;
    final missing = [
      for (final name in stack)
        if (!(assets?.containsKey(nativeAssetId(name)) ?? false))
          androidLibFileName(name),
    ];
    result = missing.isEmpty
        ? const NpuStackCheck.bundled()
        : missing.length == stack.length
        ? NpuStackCheck.missing(npuNotBundledReason(vendor))
        : NpuStackCheck.missing(
            'this build bundles only part of the ${vendor.label} NPU stack '
            '(missing ${missing.join(', ')})',
          );
  } on Object catch (e) {
    return NpuStackCheck.unknown(
      'NativeAssetsManifest.json is not in a format this version understands '
      '($e), so whether this build bundles the ${vendor.label} NPU stack is '
      'unknown',
    );
  }
  if (read == null) _cached[vendor] = result;
  return result;
}

/// Why a build that carries none of [vendor]'s stack cannot use its NPU: how
/// to opt in, for a stack that is opt-in; a broken native bundle otherwise,
/// since every build for the vendor's ABIs is meant to carry it.
String npuNotBundledReason(NpuVendor vendor) => switch (vendor) {
  NpuVendor.qualcomm => qualcommNpuNotEnabledReason,
  NpuVendor.intel =>
    'this build carries none of the Intel NPU stack; use a '
        'flutter_edge_ai_litertlm whose native release bundles it and rebuild',
};

/// What an app that did not opt in sees when it asks for npu.
const qualcommNpuNotEnabledReason =
    'this app was built without the Qualcomm NPU stack. It is opt-in, because '
    "the QNN runtime is Qualcomm's code under Qualcomm's licence: add\n"
    '  hooks:\n'
    '    user_defines:\n'
    '      flutter_edge_ai_litertlm:\n'
    '        $qualcommNpuUserDefine: true\n'
    "to the app's pubspec.yaml (the workspace root pubspec if the app is a "
    'pub workspace member) and rebuild';
