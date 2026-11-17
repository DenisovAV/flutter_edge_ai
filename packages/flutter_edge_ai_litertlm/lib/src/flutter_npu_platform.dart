// The Flutter side of the NPU host: what the runtime's NPU code
// (ffi/npu_vendor_host.dart, ffi/npu_stack_manifest.dart) asks of the app's
// platform layer, answered through Flutter — the build's
// NativeAssetsManifest.json from `rootBundle`, and on Android core's
// `flutter_gemma_bundled` channel. The LLM engine host and the EmbeddingGemma 2
// placement pass [flutterNpuHost]. Not exported.

import 'package:flutter/services.dart';

import 'ffi/npu_vendor_host.dart';
import 'litert_lm_load_errors.dart' show NpuDispatchUnavailableException;
import 'npu_stacks.dart';

/// [NpuPlatformBindings] for a Flutter app.
final class FlutterNpuPlatform implements NpuPlatformBindings {
  const FlutterNpuPlatform();

  /// `flutter_assets/NativeAssetsManifest.json`, uncached: the runtime caches
  /// the answer instead.
  @override
  Future<String> readNativeAssetsManifest() =>
      rootBundle.loadString('NativeAssetsManifest.json', cache: false);

  /// Asks core's plugin (`prepareNpuDispatchDir` on `flutter_gemma_bundled`)
  /// for a directory holding exactly [libFileNames].
  @override
  Future<String?> prepareAndroidDispatchDir(
    List<String> libFileNames,
    NpuStack vendor,
  ) async {
    const bundledChannel = MethodChannel('flutter_gemma_bundled');
    try {
      return await bundledChannel.invokeMethod<String>(
        'prepareNpuDispatchDir',
        {'libs': libFileNames},
      );
    } on MissingPluginException {
      throw const NpuDispatchUnavailableException(
        'the installed flutter_edge_ai has no prepareNpuDispatchDir; '
        'update flutter_edge_ai to the version flutter_edge_ai_litertlm '
        'requires',
      );
    } on PlatformException catch (e) {
      throw NpuDispatchUnavailableException(
        'the ${vendor.label} NPU libraries could not be prepared '
        '(${e.code}: ${e.message})',
      );
    } on Object catch (e) {
      // A channel this isolate cannot reach (a background isolate without
      // BackgroundIsolateBinaryMessenger) throws an Error, not an Exception:
      // it is still a stack that could not be prepared, and the callers'
      // contract is NpuDispatchUnavailableException.
      throw NpuDispatchUnavailableException(
        'the ${vendor.label} NPU libraries could not be prepared: $e',
      );
    }
  }

  /// `Platform.resolvedExecutable`'s directory.
  @override
  String get executableDir => executableDirOf();
}

/// The NPU host of a Flutter app on this device: [LiteRtLmPlatformNpuHost]
/// over [FlutterNpuPlatform].
const LiteRtLmNpuHost flutterNpuHost = LiteRtLmPlatformNpuHost(
  FlutterNpuPlatform(),
);
