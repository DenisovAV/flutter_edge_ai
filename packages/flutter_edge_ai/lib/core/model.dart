enum ModelType {
  general,
  gemmaIt,
  gemma4, // Gemma 4 E2B/E4B with native function calling tokens
  deepSeek,

  /// ChatML Qwen with no ` /no_think` soft switch: Qwen2.5, Qwen3-2507
  /// (Instruct and Thinking), Qwen-based fine-tunes and speech models.
  qwen,

  /// The original hybrid Qwen3 (2025-04). With thinking off, core appends
  /// ` /no_think` to each text turn — the only off switch a bundle with a
  /// legacy template has.
  qwen3,

  /// Qwen3.5, 3.6 and 3.8: thinking is switched by the `enable_thinking`
  /// template argument only; the soft switch is not supported.
  qwen35,
  llama,
  hammer,
  functionGemma,
  phi,
}

enum ModelFileType {
  task, // .task files - MediaPipe handles chat templates internally
  binary, // .bin and .tflite files - require manual chat template formatting
  litertlm, // .litertlm files - LiteRT-LM applies the chat template, on every platform
  builtIn, // OS system models (Gemini Nano, Apple Foundation Models) - no file, native side owns templates
  onnx, // ORT-GenAI model dirs (genai_config.json + .onnx[+.onnx_data] + tokenizer) - flutter_edge_ai_onnx engine
}
