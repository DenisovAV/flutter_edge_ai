import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Why EmbeddingGemma 2 cannot run in this browser, or null when it can.
///
/// On the web the bundles run on WebGPU only (`@litert-lm/core` 0.18.0 cannot
/// load them on its CPU path), and core refuses a page without it at load.
/// Asking first — as core does: `navigator.gpu`, then an adapter — lets the
/// screen say so plainly instead of offering a model list where no model
/// would load.
Future<String?> islandWebGpuProblem() async {
  const fix =
      'EmbeddingGemma 2 runs on WebGPU in a browser, and no model on the '
      'list can run without it. Open this page in a browser with WebGPU '
      'turned on and a GPU it can use (recent Chrome or Edge on desktop or '
      'Android, Safari 26).';
  final navigator = globalContext['navigator'];
  if (navigator == null || navigator.isUndefinedOrNull) {
    return 'This page has no navigator. $fix';
  }
  final gpu = (navigator as JSObject)['gpu'];
  if (gpu == null || gpu.isUndefinedOrNull) {
    return 'This browser has no WebGPU (navigator.gpu). $fix';
  }
  try {
    final options = JSObject()..['powerPreference'] = 'high-performance'.toJS;
    final adapter = await (gpu as JSObject)
        .callMethod<JSPromise<JSAny?>>('requestAdapter'.toJS, options)
        .toDart;
    if (adapter == null || adapter.isUndefinedOrNull) {
      return 'WebGPU found no GPU adapter here. $fix';
    }
  } catch (e) {
    return 'Asking the browser for a WebGPU adapter failed ($e). $fix';
  }
  return null;
}
