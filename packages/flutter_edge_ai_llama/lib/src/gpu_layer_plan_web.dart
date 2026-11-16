import 'package:llamadart/llamadart.dart' as llama;

/// Web loads GGUF from a URL and reports no VRAM, so every layer stays on the
/// GPU as before.
Future<int> planGpuLayers(String location, int contextTokens) async =>
    llama.ModelParams.maxGpuLayers;
