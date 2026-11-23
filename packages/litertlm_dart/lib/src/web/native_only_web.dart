// The public calls that need the file system or LiteRT-LM's native benchmark
// mode, on the web: each refuses with an [UnsupportedError] that says so. The
// public library exports these in place of the native ones where
// `dart.library.js_interop` is true, so an app that calls them on every
// platform compiles everywhere.

import 'dart:typed_data' show Uint8List;

import 'package:meta/meta.dart' show experimental;

import '../api/backend.dart';
import '../api/benchmark_result.dart';
import '../api/config.dart' show SamplerConfig;
import '../bundle/litertlm_bundle_info.dart' show BundleInfo;
import '../bundle/litertlm_generic_limits.dart';
import 'web_runtime_version.dart';

/// Refused on the web: the page cannot read a file by path.
Future<BundleInfo> readBundleInfo(String path) => throw UnsupportedError(
  'readBundleInfo reads a .litertlm file by path, which the web cannot.',
);

/// Refused on the web: the page cannot read a file by path.
Future<Uint8List?> readBundleGenericData(
  String path,
  String name, {
  int maxBytes = maxGenericDataBytes,
}) => throw UnsupportedError(
  'readBundleGenericData reads a .litertlm file by path, which the web '
  'cannot.',
);

/// Refused on the web: [liteRtLmWebRuntime] has no benchmark mode.
@experimental
Future<LlmBenchmarkResult> benchmark({
  required String modelPath,
  required Backend backend,
  Backend? visionBackend,
  Backend? audioBackend,
  int prefillTokens = 256,
  int decodeTokens = 256,
  String prompt = 'How are you',
  int? maxNumTokens,
  String? cacheDir,
  SamplerConfig? samplerConfig,
}) => throw UnsupportedError(
  'benchmark() runs LiteRT-LM\'s native benchmark mode, which the web runtime '
  '($liteRtLmWebRuntime) does not have.',
);
