import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;

/// Why a response format is refused in a browser with [userAgent], in an app
/// compiled by dart2wasm when [wasm], for a model loaded on [backend]; null
/// where the discriminating run passed: Chrome on macOS, a dart2wasm build
/// and WebGPU (2026-11-04, Chrome 156 on macOS arm64, bridge assets v0.1.79,
/// SmolLM2 135M). The user agent names macOS, not the CPU: Chrome reports
/// "Intel Mac OS X" on Apple silicon too. Pure, so the VM tests it.
String? webStructuredOutputRefusal(
  edge.PreferredBackend? backend, {
  required String userAgent,
  required bool wasm,
}) {
  final missing = [
    if (!_isChrome(userAgent)) 'in this browser (only Chrome has run)',
    if (!_isMacos(userAgent)) 'on this operating system (only macOS has run)',
    if (!wasm) 'in a dart2js build (only dart2wasm has run)',
    if (backend != edge.PreferredBackend.gpu)
      backend == edge.PreferredBackend.cpu
          ? "on llama.cpp's WebAssembly CPU runtime (only WebGPU has run)"
          : 'on a device the runtime did not report (only WebGPU has run)',
  ];
  if (missing.isEmpty) return null;
  return 'GGUF response formats have not been run on the Web '
      '${missing.join(', ')}; they are refused there until they have.';
}

/// macOS, not iOS or iPadOS (whose Chrome is WebKit and reports `CriOS`).
bool _isMacos(String userAgent) =>
    userAgent.contains('Macintosh') && !userAgent.contains('CriOS/');

/// Chrome itself, not another Chromium browser: those append their own token
/// to Chrome's user agent.
bool _isChrome(String userAgent) =>
    userAgent.contains('Chrome/') &&
    !RegExp(
      r'\b(Edg|EdgA|OPR|SamsungBrowser|YaBrowser|Vivaldi|Brave)/',
    ).hasMatch(userAgent);
