@JS()
library llm_inference;

import 'dart:js_interop';

extension type FilesetResolver._(JSObject _) implements JSObject {
  external static JSPromise<FilesetResolver> forGenAiTasks(JSString path);
}

extension type LlmInference._(JSObject _) implements JSObject {
  external static JSPromise<LlmInference> createFromOptions(
    FilesetResolver fileset,
    LlmInferenceOptions options,
  );
  external JSPromise<JSString> generateResponse(
    JSString text,
    JSFunction? callback, // Function(String, bool)?
  );

  // Multimodal overload for arrays (text + images)
  @JS('generateResponse')
  external JSPromise<JSString> generateResponseMultimodal(
    JSAny prompt, // Can be JSString or JSArray
    JSFunction? callback,
  );
  external JSNumber sizeInTokens(JSString text);
  external JSPromise addQueryChunk(JSString text);

  // Cancel ongoing inference processing (MediaPipe 0.10.26+)
  external void cancelProcessing();

  // Cleanup method to free WASM resources (critical for memory management)
  external void close();
}

@JS()
@anonymous
@staticInterop
class LlmInferenceOptions {
  external factory LlmInferenceOptions({
    required LlmInferenceBaseOptions baseOptions,
    int maxTokens = 1024,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    double temperature = 1.0,
    JSInt32Array? supportedLoraRanks,
    String? loraPath,
    int? maxNumImages,
  });
}

@JS()
@anonymous
@staticInterop
class LlmInferenceBaseOptions {
  external factory LlmInferenceBaseOptions({
    String? modelAssetPath, // For cacheApi/none modes (Blob URL)
    JSAny?
    modelAssetBuffer, // For streaming mode (ReadableStreamDefaultReader from OPFS)
  });
}

extension JSAnyExt on JSAny {
  bool parseBool() {
    if (isA<JSBoolean>()) {
      return (this as JSBoolean).toDart;
    }
    if (isA<JSNumber>()) {
      return (this as JSNumber).toDartInt == 1;
    }
    return false;
  }
}
