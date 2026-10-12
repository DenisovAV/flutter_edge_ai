// ONNX Runtime embedding backend — native arm. It only DESCRIBES what to run
// (`describe()` is pure: no native library, no isolate); core builds the
// `OnnxEmbeddingPass` in its embedding worker, hosts it, checks every request
// and closes it.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

import 'onnx_embedding_pass.dart';
import 'ort_token_graph.dart';

/// ONNX Runtime embedding backend — plain ORT (no GenAI, no text generation)
/// over a single-file `.onnx`/`.ort` embedding model. Text only, CPU.
///
/// Priority 10 (above LiteRT's 0) so an app that registers both backends and
/// installs an `.onnx` model gets this one.
final class OnnxEmbeddingBackend extends EmbeddingBackendProvider {
  const OnnxEmbeddingBackend();

  /// Unlike `OnnxEngine`, [canHandle] here stays extension-based (not
  /// platform-gated): if it went false on an unsupported host, another
  /// backend could claim the `.onnx` file and fail deep inside its own native
  /// load with a confusing error. So the platform gate lives in [describe],
  /// which refuses loudly — same `_isSupportedHost` shape as `OnnxEngine`,
  /// kept in lockstep with `hook/build.dart`'s platform table (macOS arm64,
  /// Linux x64, Windows x64, Android arm64, iOS arm64; `Abi.iosArm64` covers
  /// the device and the Apple-Silicon simulator).
  static bool get _isSupportedHost {
    if (debugForceUnsupportedHost == true) return false;
    final abi = Abi.current();
    // Keep in lockstep with hook/build.dart's `_archivesFor` table.
    return (Platform.isMacOS && abi == Abi.macosArm64) ||
        (Platform.isLinux && abi == Abi.linuxX64) ||
        (Platform.isWindows && abi == Abi.windowsX64) ||
        (Platform.isAndroid && abi == Abi.androidArm64) ||
        (Platform.isIOS && abi == Abi.iosArm64);
  }

  /// Test-only override — see `OnnxEngine.debugForceUnsupportedHost` (same
  /// seam, same rationale). Never read or set outside `test/`. Reset to
  /// `null` in `tearDown`.
  @visibleForTesting
  static bool? debugForceUnsupportedHost;

  @override
  String get name => 'ONNX Embedding';

  @override
  int get priority => 10;

  /// `EmbeddingModelSpec` has no `fileType`; the installed model file's
  /// extension is this backend's identity signal: `.onnx` (single-file
  /// export) or `.ort` (ORT-optimized format), ASCII case-insensitive.
  @override
  bool canHandle(EmbeddingModelSpec spec) =>
      isOnnxEmbeddingFilename(spec.files.first.filename);

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    if (!_isSupportedHost) {
      throw EmbeddingLoadException(
        'OnnxEmbeddingBackend: unsupported host '
        '${Platform.operatingSystem}/${Abi.current()} — ONNX embedding native '
        'archives are macOS-arm64/linux-x64/windows-x64/android-arm64/'
        'ios-arm64-only.',
        engine: _onnx,
      );
    }
    if (config.supportImage || config.supportAudio) {
      throw const EmbeddingLoadException(
        'ONNX embeddings are text-only',
        engine: _onnx,
      );
    }
    final tokenizerPath =
        config.tokenizerPath ??
        (throw EmbeddingLoadException(
          'identity corrupt: the active embedder ${spec.name} names a '
          'tokenizer, but core resolved no tokenizer path for it. Install the '
          'embedder again.',
          engine: _onnx,
        ));
    return EmbeddingPassDescriptor<OnnxEmbeddingConfig>(
      engineTag: _onnx,
      factory: _buildOnnxEmbeddingPass,
      config: OnnxEmbeddingConfig(
        modelPath: config.modelPath,
        tokenizerPath: tokenizerPath,
        tokenizerFactory: EmbeddingTokenizerRegistry.instance.resolveFor(spec),
      ),
      // CPU: the client creates its session with no
      // SessionOptionsAppendExecutionProvider call, so ORT runs its default
      // CPU provider. Stated here rather than assumed by core.
      activeBackend: PreferredBackend.cpu,
    );
  }
}

const _onnx = 'ONNX';

/// The descriptor factory: a top-level tear-off, so it survives the trip into
/// core's worker isolate.
EmbeddingPass _buildOnnxEmbeddingPass(OnnxEmbeddingConfig config) =>
    OnnxEmbeddingPass(config);
