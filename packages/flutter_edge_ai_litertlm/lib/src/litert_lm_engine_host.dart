// What `LiteRtLmEngine.createModel` reaches outside Dart and outside
// litertlm_dart — the app's support directory and the platform layer the NPU
// asks — behind one object, so a VM test can drive a whole load without
// path_provider or a device. Not exported.

import 'dart:ffi' show Abi;
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:litertlm_dart/internal_io.dart'
    show AndroidGpuFamily, androidGpuFamilyFrom;
import 'package:litertlm_dart/litertlm_dart.dart' show NpuPlatform;

import 'flutter_npu_platform.dart';

/// The app's support directory (path_provider): the default
/// [LiteRtLmEngineHost.cacheDir].
Future<String> applicationSupportDirectoryPath() async =>
    (await getApplicationSupportDirectory()).path;

/// What a native `.litertlm` LLM load reaches outside Dart: the app's
/// support directory, the platform layer the NPU asks, the host ABI and the
/// Android GPU family. Injected so a VM test can drive a whole load without
/// path_provider or a device; the native side is litertlm_dart's
/// `debugEngineHost`.
class LiteRtLmEngineHost {
  const LiteRtLmEngineHost({
    this.cacheDirectory = applicationSupportDirectoryPath,
    this.npuPlatform = const FlutterNpuPlatform(),
  });

  /// Where [cacheDir] comes from.
  final Future<String> Function() cacheDirectory;

  /// What the NPU asks of the app: the build manifest and, on Android, the
  /// vendor's dispatch directory.
  final NpuPlatform npuPlatform;

  /// The directory LiteRT-LM keeps its caches in.
  Future<String> cacheDir() async => cacheDirectory();

  /// `Abi.current()`, as its `toString()`.
  String get abi => '${Abi.current()}';

  /// The GPU family of an Android device, told by the device node its driver
  /// exposes (`/dev/kgsl-3d0` Adreno, `/dev/mali0` Mali, `/dev/pvr_sync`
  /// PowerVR); null elsewhere.
  AndroidGpuFamily? androidGpuFamily() => Platform.isAndroid
      ? androidGpuFamilyFrom((path) => File(path).existsSync())
      : null;
}

LiteRtLmEngineHost _host = const LiteRtLmEngineHost();

/// The host every native `.litertlm` LLM load goes through.
LiteRtLmEngineHost get liteRtLmEngineHost => _host;

/// Replaces [liteRtLmEngineHost]; null restores the real one.
@visibleForTesting
set debugLiteRtLmEngineHost(LiteRtLmEngineHost? host) =>
    _host = host ?? const LiteRtLmEngineHost();
