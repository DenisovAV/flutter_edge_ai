/// GGUF inference connector for Flutter Edge AI.
///
/// llamadart owns templates, typed output and execution. This adapter owns
/// independent transcripts, session scheduling and Edge AI lifecycle contracts.
library;

export 'src/llama_engine_provider.dart';
export 'src/llama_inference_chat.dart';
export 'src/llama_inference_model.dart';
export 'src/llama_inference_session.dart';
export 'src/llama_tool.dart'
    show LlamaFunctionCallResponse, LlamaToolResponseMessage;
