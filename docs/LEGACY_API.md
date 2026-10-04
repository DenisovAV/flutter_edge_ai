# Legacy API (Deprecated) ⚠️

> **⚠️ DEPRECATED:** This API is maintained for backwards compatibility only.
> For new projects, use the [Modern API](../packages/flutter_edge_ai/README.md#quick-start) instead.
> The RAG examples in this document describe the pre-2.0 core/plugin API and do
> **not** compile against current `flutter_edge_ai`. RAG now lives in
> `flutter_edge_ai_rag`; follow the
> [2.0 migration guide](../packages/flutter_edge_ai/MIGRATION.md#flutter-edge-ai-1x--20-rag-leaves-core).
>
> **Why migrate?**
> - ✅ **Modern API:** Fluent builder pattern, type-safe sources, callback-based progress, better error messages
> - ⚠️ **Legacy API:** Direct method calls, stream-based progress, manual state management
>
> **Migration Guide:** See [Migration from Legacy to Modern API](#migration-from-legacy-to-modern-api) at the end of this document.


The new API splits functionality into two parts:

* **ModelFileManager**: Manages model and LoRA weights file handling.
* **InferenceModel**: Handles model initialization and response generation.

The updated API splits the functionality into two main parts:

* Import and access the plugin:

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

final gemma = FlutterEdgeAiPlugin.instance;
```

* Managing Model Files with ModelFileManager

```dart
final modelManager = gemma.modelManager;
```

Place the model in the assets or upload it to a network drive, such as Firebase.
#### ATTENTION!! You do not need to load the model every time the application starts; it is stored in the system files and only needs to be done once. Please carefully review the example application. You should use loadAssetModel and loadNetworkModel methods only when you need to upload the model to device

1.**Loading Models from assets (available only in debug mode):**

Don't forget to add your model to pubspec.yaml

1) Loading from assets (loraUrl is optional)
```dart
    await modelManager.installModelFromAsset('model.bin', loraPath: 'lora_weights.bin');
```

2) Loading from assets with Progress Status (loraUrl is optional)
```dart
    modelManager.installModelFromAssetWithProgress('model.bin', loraPath: 'lora_weights.bin').listen(
    (progress) {
      print('Loading progress: $progress%');
    },
    onDone: () {
      print('Model loading complete.');
    },
    onError: (error) {
      print('Error loading model: $error');
    },
  );
```

2.**Loading Models from network:**

* For web usage, you will also need to enable CORS (Cross-Origin Resource Sharing) for your network resource. To enable CORS in Firebase, you can follow the guide in the Firebase documentation: [Setting up CORS](https://firebase.google.com/docs/storage/web/download-files#cors_configuration)

    1) Loading from the network (loraUrl is optional).
```dart
   await modelManager.downloadModelFromNetwork('https://example.com/model.bin', loraUrl: 'https://example.com/lora_weights.bin');
```

2) Loading from the network with Progress Status (loraUrl is optional)
```dart
    modelManager.downloadModelFromNetworkWithProgress('https://example.com/model.bin', loraUrl: 'https://example.com/lora_weights.bin').listen(
    (progress) {
      print('Loading progress: $progress%');
    },
    onDone: () {
      print('Model loading complete.');
    },
    onError: (error) {
      print('Error loading model: $error');
    },
);
```

3. **Loading LoRA Weights**

1) Loading LoRA weight from the network.
```dart
await modelManager.downloadLoraWeightsFromNetwork('https://example.com/lora_weights.bin');
```

2) Loading LoRA weight from assets.
```dart
await modelManager.installLoraWeightsFromAsset('lora_weights.bin');
```

4. **Model Management**
   You can set model and weights paths manually
```dart
await modelManager.setModelPath('model.bin');
await modelManager.setLoraWeightsPath('lora_weights.bin');
```

**Model Replace Policy**

Configure how the plugin handles switching between different models:

```dart
// Set policy to keep all models (default behavior)
await modelManager.setReplacePolicy(ModelReplacePolicy.keep);

// Set policy to replace old models (saves storage space)
await modelManager.setReplacePolicy(ModelReplacePolicy.replace);

// Check current policy
final currentPolicy = modelManager.replacePolicy;
```

**Automatic Model Management**

Use `ensureModelReady()` for seamless model switching that handles all scenarios automatically:

```dart
// Handles all cases:
// - Same model already loaded: does nothing
// - Different model with KEEP policy: loads new model, keeps old one
// - Different model with REPLACE policy: deletes old model, loads new one
// - Corrupted/invalid model: re-downloads automatically
await modelManager.ensureModelReady(
  'gemma-3n-E4B-it-int4.task',
  'https://huggingface.co/google/gemma-3n-E4B-it-litert-preview/resolve/main/gemma-3n-E4B-it-int4.task'
);
```

You can delete the model and weights from the device. Deleting the model or LoRA weights will automatically close and clean up the inference. This ensures that there are no lingering resources or memory leaks when switching models or updating files.
```dart
await modelManager.deleteModel();
await modelManager.deleteLoraWeights();
```

5.**Initialize:**

Before performing any inference, you need to create a model instance. This ensures that your application is ready to handle requests efficiently.

**Text-Only Models:**
```dart
final inferenceModel = await FlutterEdgeAiPlugin.instance.createModel(
  modelType: ModelType.gemmaIt, // Required, model type to create
  preferredBackend: PreferredBackend.gpu, // Optional, backend type, default is PreferredBackend.gpu
  maxTokens: 512, // Optional, default is 1024
  loraRanks: [4, 8], // Optional, LoRA rank configuration for fine-tuned models
);
```

**🖼️ Multimodal Models:**
```dart
final inferenceModel = await FlutterEdgeAiPlugin.instance.createModel(
  modelType: ModelType.gemmaIt, // Required, model type to create
  preferredBackend: PreferredBackend.gpu, // Optional, backend type
  maxTokens: 4096, // Recommended for multimodal models
  supportImage: true, // Enable image support
  maxNumImages: 1, // Optional, maximum number of images per message
  loraRanks: [4, 8], // Optional, LoRA rank configuration for fine-tuned models
);
```

**PreferredBackend Options:**

| Backend | Android | iOS | Web | Desktop |
|---------|---------|-----|-----|---------|
| `cpu` | ✅ | ✅ | ❌ | ✅ |
| `gpu` | ✅ | ✅ | ✅ (required) | ✅ |
| `npu` | ✅ (.litertlm) | ❌ | ❌ | ❌ |

- **NPU**: Qualcomm Snapdragon only — the Android archive ships the Qualcomm QNN dispatch stack and nothing for MediaTek or Google Tensor.
- **Web**: GPU only (MediaPipe limitation). CPU models will fail to initialize.
- **Desktop**: GPU uses Metal (macOS), DirectX 12 (Windows), Vulkan (Linux).

6.**Using Sessions for Single Inferences:**

If you need to generate individual responses without maintaining a conversation history, use sessions. Sessions allow precise control over inference and must be properly closed to avoid memory leaks.

1) **Text-Only Session:**

```dart
final session = await inferenceModel.createSession(
  temperature: 1.0, // Optional, default: 0.8
  randomSeed: 1, // Optional, default: 1
  topK: 1, // Optional, default: 1
  // topP: 0.9, // Optional nucleus sampling parameter
  // loraPath: 'path/to/lora.bin', // Optional LoRA weights path
  // enableVisionModality: true, // Enable vision for multimodal models
);

await session.addQueryChunk(Message.text(text: 'Tell me something interesting', isUser: true));
String response = await session.getResponse();
print(response);

await session.close(); // Always close the session when done
```

2) **🖼️ Multimodal Session:**

```dart
import 'dart:typed_data'; // For Uint8List

final session = await inferenceModel.createSession(
  enableVisionModality: true, // Enable image processing
);

// Text + Image message
final imageBytes = await loadImageBytes(); // Your image loading method
await session.addQueryChunk(Message.withImage(
  text: 'What do you see in this image?',
  imageBytes: imageBytes,
  isUser: true,
));

// Note: session.getResponse() returns String directly
String response = await session.getResponse();
print(response);

await session.close();
```

3) **Asynchronous Response Generation:**

```dart
final session = await inferenceModel.createSession();
await session.addQueryChunk(Message.text(text: 'Tell me something interesting', isUser: true));

// Note: session.getResponseAsync() returns Stream<String>
session.getResponseAsync().listen((String token) {
  print(token);
}, onDone: () {
  print('Stream closed');
}, onError: (error) {
  print('Error: $error');
});

await session.close(); // Always close the session when done
```

7.**Chat Scenario with Automatic Session Management**

For chat-based applications, you can create a chat instance. Unlike sessions, the chat instance manages the conversation context and refreshes sessions when necessary.

**Text-Only Chat:**
```dart
final chat = await inferenceModel.createChat(
  temperature: 0.8, // Controls response randomness, default: 0.8
  randomSeed: 1, // Ensures reproducibility, default: 1
  topK: 1, // Limits vocabulary scope, default: 1
  // topP: 0.9, // Optional nucleus sampling parameter
  // tokenBuffer: 256, // Token buffer size, default: 256
  // loraPath: 'path/to/lora.bin', // Optional LoRA weights path
  // supportImage: false, // Enable image support, default: false
  // tools: [], // List of available tools, default: []
  // supportsFunctionCalls: false, // Enable function calling, default: false
  // isThinking: false, // Enable thinking mode, default: false
  // modelType: ModelType.gemmaIt, // Model type, default: ModelType.gemmaIt
);
```

**🖼️ Multimodal Chat:**
```dart
final chat = await inferenceModel.createChat(
  temperature: 0.8, // Controls response randomness
  randomSeed: 1, // Ensures reproducibility
  topK: 1, // Limits vocabulary scope
  supportImage: true, // Enable image support in chat
  // tokenBuffer: 256, // Token buffer size for context management
);
```

**🧠 Thinking Mode Chat (DeepSeek Models):**
```dart
final chat = await inferenceModel.createChat(
  temperature: 0.8,
  randomSeed: 1,
  topK: 1,
  isThinking: true, // Enable thinking mode for DeepSeek models
  modelType: ModelType.deepSeek, // Specify DeepSeek model type
  // supportsFunctionCalls: true, // Enable function calling for DeepSeek models
);
```

1) **Synchronous Chat:**

```dart
await chat.addQueryChunk(Message.text(text: 'User: Hello, who are you?', isUser: true));
ModelResponse response = await chat.generateChatResponse();
if (response is TextResponse) {
  print(response.token);
}

await chat.addQueryChunk(Message.text(text: 'User: Are you sure?', isUser: true));
ModelResponse response2 = await chat.generateChatResponse();
if (response2 is TextResponse) {
  print(response2.token);
}
```

2) **🖼️ Multimodal Chat Example:**

```dart
// Add text message
await chat.addQueryChunk(Message.text(text: 'Hello!', isUser: true));
ModelResponse response1 = await chat.generateChatResponse();
if (response1 is TextResponse) {
  print(response1.token);
}

// Add image message
final imageBytes = await loadImageBytes();
await chat.addQueryChunk(Message.withImage(
  text: 'Can you analyze this image?',
  imageBytes: imageBytes,
  isUser: true,
));
ModelResponse response2 = await chat.generateChatResponse();
if (response2 is TextResponse) {
  print(response2.token);
}

// Add image-only message
await chat.addQueryChunk(Message.imageOnly(imageBytes: imageBytes, isUser: true));
ModelResponse response3 = await chat.generateChatResponse();
if (response3 is TextResponse) {
  print(response3.token);
}
```

3) **Asynchronous Chat (Streaming):**

```dart
await chat.addQueryChunk(Message.text(text: 'User: Hello, who are you?', isUser: true));

chat.generateChatResponseAsync().listen((ModelResponse response) {
  if (response is TextResponse) {
    print(response.token);
  } else if (response is FunctionCallResponse) {
    print('Function call: ${response.name}');
  } else if (response is ThinkingResponse) {
    print('Thinking: ${response.content}');
  }
}, onDone: () {
  print('Chat stream closed');
}, onError: (error) {
  print('Chat error: $error');
});
```

8. **🛠️ Function Calling**

Enable your models to call external functions and integrate with other services. **Note: Function calling is only supported by specific models - see the [Model Support](#model-function-calling-support) section below.**

**Step 1: Define Tools**

Tools define the functions your model can call:

```dart
final List<Tool> _tools = [
  const Tool(
    name: 'change_background_color',
    description: "Changes the background color of the app. The color should be a standard web color name like 'red', 'blue', 'green', 'yellow', 'purple', or 'orange'.",
    parameters: {
      'type': 'object',
      'properties': {
        'color': {
          'type': 'string',
          'description': 'The color name',
        },
      },
      'required': ['color'],
    },
  ),
  const Tool(
    name: 'show_alert',
    description: 'Shows an alert dialog with a custom message and title.',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {
          'type': 'string',
          'description': 'The title of the alert dialog',
        },
        'message': {
          'type': 'string',
          'description': 'The message content of the alert dialog',
        },
      },
      'required': ['title', 'message'],
    },
  ),
];
```

**Step 2: Create Chat with Tools**

```dart
final chat = await inferenceModel.createChat(
  temperature: 0.8,
  randomSeed: 1,
  topK: 1,
  tools: _tools, // Pass your tools
  supportsFunctionCalls: true, // Enable function calling (required for tools)
  toolChoice: ToolChoice.auto, // auto (default) | required | none
);
```

**ToolChoice modes:**
| Mode | Behavior |
|------|----------|
| `ToolChoice.auto` | Model decides whether to call a tool (default) |
| `ToolChoice.required` | Model must respond with a function call |
| `ToolChoice.none` | Tools are hidden, model responds with text only |

**Step 3: Handle Response Types**

The model can return text, a single function call, or multiple parallel function calls:

```dart
await chat.addQueryChunk(Message.text(text: 'Change the background to blue', isUser: true));

// Sync mode
final response = await chat.generateChatResponse();

if (response is TextResponse) {
  print('Text: ${response.token}');
} else if (response is FunctionCallResponse) {
  // Single function call
  print('Call: ${response.name}(${response.args})');
  _handleFunctionCall(response);
} else if (response is ParallelFunctionCallResponse) {
  // Multiple function calls (e.g. "Change title and background color")
  for (final call in response.calls) {
    print('Call: ${call.name}(${call.args})');
    await _handleFunctionCall(call);
  }
}

// Streaming mode — same types arrive via stream
await for (final response in chat.generateChatResponseAsync()) {
  if (response is TextResponse) {
    print(response.token);
  } else if (response is FunctionCallResponse) {
    _handleFunctionCall(response);
  } else if (response is ParallelFunctionCallResponse) {
    for (final call in response.calls) {
      await _handleFunctionCall(call);
    }
  }
}
```

**Step 4: Execute Function and Send Response Back**

```dart
Future<void> _handleFunctionCall(FunctionCallResponse functionCall) async {
  // Execute the requested function
  Map<String, dynamic> toolResponse;
  
  switch (functionCall.name) {
    case 'change_background_color':
      final color = functionCall.args['color'] as String?;
      // Your implementation here
      toolResponse = {'status': 'success', 'message': 'Color changed to $color'};
      break;
    case 'show_alert':
      final title = functionCall.args['title'] as String?;
      final message = functionCall.args['message'] as String?;
      // Show alert dialog
      toolResponse = {'status': 'success', 'message': 'Alert shown'};
      break;
    default:
      toolResponse = {'error': 'Unknown function: ${functionCall.name}'};
  }
  
  // Send the tool response back to the model
  final toolMessage = Message.toolResponse(
    toolName: functionCall.name,
    response: toolResponse,
  );
  await chat.addQueryChunk(toolMessage);
  
  // The model will then generate a final response explaining what it did
  final finalResponse = await chat.generateChatResponse();
  if (finalResponse is TextResponse) {
    print('Model: ${finalResponse.token}');
  }
}
```

**Function Calling Best Practices:**

- Use descriptive function names and clear descriptions
- Specify required vs optional parameters
- Always handle function execution errors gracefully
- Send meaningful responses back to the model
- The model will only call functions when explicitly requested by the user

### FunctionGemma - Specialized Function Calling Model

[FunctionGemma](https://huggingface.co/google/functiongemma-270m-it) is a specialized 270M parameter model from Google, optimized for function calling on mobile devices.

#### Pre-converted Models

Ready-to-use `.task` files:

| Model | Description | Link |
|-------|-------------|------|
| **FunctionGemma 270M IT** | Original Google model | [sasha-denisov/function-gemma-270M-it](https://huggingface.co/sasha-denisov/function-gemma-270M-it) |
| **FunctionGemma Flutter Demo** | Fine-tuned for example app (`change_background_color`, `change_app_title`, `show_alert`) | [sasha-denisov/functiongemma-flutter-gemma-demo](https://huggingface.co/sasha-denisov/functiongemma-flutter-gemma-demo) |

#### Usage

```dart
// Install FunctionGemma
await FlutterEdgeAi.installModel(
  modelType: ModelType.functionGemma,
).fromNetwork(
  'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.task',
).install();

// Create model
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 1024,
  preferredBackend: PreferredBackend.gpu,
);

// Use with function calling
final chat = await model.createChat(
  tools: myTools,
  supportsFunctionCalls: true,
);
```

#### Platform Support

| Platform | Status |
|----------|--------|
| Android | ✅ Full support |
| iOS | ✅ Full support |
| Web | ❌ Not supported yet |
| Desktop | ✅ Full support |

#### Fine-tuning FunctionGemma

You can fine-tune FunctionGemma for your custom functions using the provided Colab notebooks:

**Pipeline:**
1. [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/DenisovAV/flutter_edge_ai/blob/main/colabs/functiongemma_finetuning.ipynb) Fine-tune the model on your training data
2. [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/DenisovAV/flutter_edge_ai/blob/main/colabs/functiongemma_to_tflite.ipynb) Convert PyTorch → TFLite
3. [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/DenisovAV/flutter_edge_ai/blob/main/colabs/functiongemma_tflite_to_task.ipynb) Bundle TFLite → MediaPipe `.task`

**Training Data Format** (`training_data.jsonl`):
```json
{"user_content": "make it red", "tool_name": "change_background_color", "tool_arguments": "{\"color\": \"red\"}"}
{"user_content": "show welcome message", "tool_name": "show_alert", "tool_arguments": "{\"title\": \"Welcome\", \"message\": \"Hello!\"}"}
```

**Requirements:**
- Google Colab with A100 GPU
- HuggingFace account with [accepted Gemma license](https://huggingface.co/google/functiongemma-270m-it)
- HuggingFace token with write access (for uploading)

#### FunctionGemma Format

FunctionGemma uses a special format (different from JSON-based function calling):

**Function Call Output:**
```
<start_function_call>call:change_background_color{color:<escape>red<escape>}<end_function_call>
```

The `flutter_edge_ai` plugin handles this format automatically via `FunctionCallParser`.
This is the `.task` (MediaPipe) path. Since `flutter_gemma` 1.8.4 a `.litertlm`
FunctionGemma goes through LiteRT-LM's own tool path instead: the runtime renders the
declarations and returns the call already parsed, and results go back as role-`tool`
messages. The format above is still what `FunctionCallParser` falls back to when the call
arrives as text — on the web SDK, or from a `.litertlm` exported without the FunctionGemma
model type.

9. **🧠 Thinking Mode (DeepSeek, Qwen3 & Gemma 4 Models)**

DeepSeek, Qwen3, and Gemma 4 (E2B/E4B) models support "thinking mode" where you can see the model's reasoning process before it generates the final response. This provides transparency into how the model approaches problems.

> **Note:** Qwen3 generates thinking blocks by default. When `isThinking: false`, thinking content is automatically stripped from the response. Set `isThinking: true` to see the reasoning process.

**Enable Thinking Mode (DeepSeek):**

```dart
final chat = await inferenceModel.createChat(
  temperature: 0.8,
  randomSeed: 1,
  topK: 1,
  isThinking: true, // Enable thinking mode
  modelType: ModelType.deepSeek, // Required for DeepSeek models
  supportsFunctionCalls: true, // DeepSeek also supports function calls
  tools: _tools, // Optional: add tools for function calling
);
```

**Handle Thinking Responses:**

```dart
chat.generateChatResponseAsync().listen((response) {
  if (response is ThinkingResponse) {
    // Model's reasoning process
    print('Model is thinking: ${response.content}');
    // Show thinking bubble in UI
    _showThinkingBubble(response.content);
    
  } else if (response is TextResponse) {
    // Final response after thinking
    print('Final answer: ${response.token}');
    _updateFinalResponse(response.token);
    
  } else if (response is FunctionCallResponse) {
    // DeepSeek can also call functions while thinking
    print('Function call: ${response.name}');
    _handleFunctionCall(response);
  }
});
```

**Enable Thinking Mode (Gemma 4):**

```dart
final chat = await inferenceModel.createChat(
  temperature: 1.0,
  topK: 64,
  topP: 0.95,
  isThinking: true, // Enable thinking mode
  modelType: ModelType.gemmaIt, // Gemma 4 E2B/E4B
);
// <|think|> is auto-injected into systemInstruction — no manual prompt needed.
```

**Thinking Mode Features:**
- ✅ **Transparent Reasoning**: See how the model thinks through problems
- ✅ **Interactive UI**: Show/hide thinking bubbles with expandable content
- ✅ **Streaming Support**: Thinking content streams in real-time
- ✅ **Function Integration**: Models can think before calling functions
- ✅ **Supported Models**: DeepSeek R1 and Gemma 4 E2B/E4B

**Example Thinking Flow:**
1. User asks: "Change the background to blue and explain why blue is calming"
2. Model thinks: "I need to change the color first, then explain the psychology"
3. Model calls: `change_background_color(color: 'blue')`
4. Model explains: "Blue is calming because it's associated with sky and ocean..."

10. **📊 Text Embeddings & RAG (Retrieval-Augmented Generation)**

Generate vector embeddings from text and perform semantic search with local vector storage. This enables RAG applications with on-device inference and privacy-preserving semantic search.

### Platform Support

| Feature | Android | iOS | Web | Desktop |
|---------|---------|-----|-----|---------|
| **Embedding Generation** | ✅ Full | ✅ Full | ✅ Full | ✅ Full |
| **VectorStore (RAG)** | ✅ SQLite | ✅ SQLite | ✅ SQLite WASM | ✅ SQLite |

- **Mobile (Android/iOS)**: Full RAG support with SQLite-based VectorStore
- **Web**: Full RAG support with SQLite WASM (wa-sqlite + OPFS) - see [Web Setup](#web-setup-embeddings--vectorstore) below
- **Desktop (macOS/Windows/Linux)**: Full RAG support. Embeddings use LiteRT C API via `dart:ffi` (no gRPC, no JVM). VectorStore uses SQLite.

### Supported Embedding Models

- **EmbeddingGemma-300M** - 300M parameters, generates 768D embeddings with varying max sequence lengths (256, 512, 1024, 2048 tokens)
- **Gecko-110m** - 110M parameters, generates 768D embeddings with varying max sequence lengths (64, 256, 512 tokens)

**Note:** Numbers in model names (64, 256, 512, 1024, 2048) refer to **max sequence length** (context window size in tokens), **NOT** embedding dimension. All these models output **768-dimensional embeddings** regardless of sequence length.

### Install Embedding Model

```dart
// Install from network with progress tracking
await FlutterEdgeAi.installEmbedder()
  .modelFromNetwork(
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq1024_mixed-precision.tflite',
    token: 'hf_your_token_here',  // Required for gated models
  )
  .tokenizerFromNetwork(
    'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
  )
  .withModelProgress((progress) => print('Model: $progress%'))
  .withTokenizerProgress((progress) => print('Tokenizer: $progress%'))
  .install();

// Or from assets
await FlutterEdgeAi.installEmbedder()
  .modelFromAsset('models/embeddinggemma.tflite')
  .tokenizerFromAsset('models/sentencepiece.model')
  .install();
```

### iOS: Tokenizer Compatibility

> **Important:** On iOS, SentencePiece `.model` tokenizers are not supported due to a protobuf
> conflict between SentencePiece C++ and TensorFlow Lite. Use `.json` tokenizers instead.

Pre-converted tokenizer files are available on GitHub CDN (hosted on the v0.12.5 release as a stable bundle — they don't change between plugin versions):
- **EmbeddingGemma:** `https://github.com/DenisovAV/flutter_edge_ai/releases/download/v0.12.5/embeddinggemma_tokenizer.json`
- **Gecko:** `https://github.com/DenisovAV/flutter_edge_ai/releases/download/v0.12.5/gecko_tokenizer.json`

```dart
await FlutterEdgeAi.installEmbedder()
  .modelFromNetwork(modelUrl, token: hfToken)
  .tokenizerFromNetwork(
    'https://huggingface.co/.../sentencepiece.model',
    token: hfToken,
    iosPath: 'https://github.com/DenisovAV/flutter_edge_ai/releases/download/v0.12.5/embeddinggemma_tokenizer.json',
  )
  .install();
```

On Android and Web, the original `sentencepiece.model` URL is used. On iOS, the `iosPath` is
automatically selected. If `iosPath` is not provided and the tokenizer URL ends with `.model`,
an error is thrown with instructions.

To convert your own tokenizer, use the provided script:
```bash
pip install -r tools/requirements.txt
python tools/convert_sentencepiece_to_json.py --input path/to/sentencepiece.model --output tokenizer.json
```

### Generate Text Embeddings

```dart
// Create embedding model instance
// `preferredBackend` is accepted but not applied to embeddings: native runs on
// CPU and web lets the runtime pick. Read embeddingModel.activeBackend.
final embeddingModel = await FlutterEdgeAi.getActiveEmbedder();

// Generate query embedding (for search)
final queryEmb = await embeddingModel.generateEmbedding('What is Flutter?');
print('Query embedding: ${queryEmb.take(5)}...'); // Show first 5 dimensions

// Generate document embedding (for indexing) — uses document prefix
final docEmb = await embeddingModel.generateEmbedding(
  'Flutter is a UI framework by Google',
  taskType: TaskType.retrievalDocument,
);

// Batch embeddings
final embeddings = await embeddingModel.generateEmbeddings(
  ['Hello, world!', 'How are you?', 'Flutter is awesome!'],
  taskType: TaskType.retrievalDocument, // optional, default is retrievalQuery
);
print('Generated ${embeddings.length} embeddings');

// Get embedding model dimension
final dimension = await embeddingModel.getDimension();
print('Model dimension: $dimension');

// Calculate cosine similarity between embeddings
double cosineSimilarity(List<double> a, List<double> b) {
  double dotProduct = 0.0;
  double normA = 0.0;
  double normB = 0.0;

  for (int i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }

  return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
}

final similarity = cosineSimilarity(embeddings[0], embeddings[1]);
print('Similarity: $similarity');

// Note: EmbeddingGemma and Gecko return L2-normalized vectors (‖v‖ ≈ 1.0),
// so dot product alone equals cosine similarity — you can skip normalization.

// Close model when done
await embeddingModel.close();
```

### RAG with VectorStore

**Full cross-platform support:** VectorStore uses SQLite on mobile (Android/iOS) and SQLite WASM (wa-sqlite + OPFS) on web with identical API and behavior.

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:path_provider/path_provider.dart';

// Step 1: Initialize VectorStore
final appDir = await getApplicationDocumentsDirectory();
final dbPath = '${appDir.path}/my_vector_store.db';
await FlutterEdgeAiPlugin.instance.initializeVectorStore(dbPath);

// Step 2: Add documents with embeddings
final documents = [
  'Flutter is a UI toolkit for building apps',
  'Dart is the programming language used with Flutter',
  'Machine learning enables AI capabilities',
];

for (final doc in documents) {
  // Generate document embedding (uses document prefix for better retrieval)
  final embedding = await embeddingModel.generateEmbedding(
    doc,
    taskType: TaskType.retrievalDocument,
  );

  // Add to vector store
  await FlutterEdgeAiPlugin.instance.addDocumentWithEmbedding(
    id: 'doc_${documents.indexOf(doc)}',
    content: doc,
    embedding: embedding,
    metadata: {'source': 'example', 'index': documents.indexOf(doc)},
  );
}

// Step 3: Search for similar documents
final query = 'What is Flutter?';
final queryEmbedding = await embeddingModel.generateEmbedding(query);

final results = await FlutterEdgeAiPlugin.instance.searchSimilar(
  queryEmbedding: queryEmbedding,
  topK: 3,              // Return top 3 results
  threshold: 0.7,       // Minimum similarity score (0.0-1.0)
);

// Step 4: Use results
for (final result in results) {
  print('Score: ${result.similarity}');
  print('Content: ${result.content}');
  print('Metadata: ${result.metadata}');
}

// Step 5: RAG with inference model
final context = results.map((r) => r.content).join('\n');
final prompt = 'Context:\n$context\n\nQuestion: $query';

final inferenceModel = await FlutterEdgeAi.getActiveModel();
final session = await inferenceModel.createSession();
await session.addQueryChunk(Message.text(text: prompt, isUser: true));
final answer = await session.getResponse();
print('Answer: $answer');

await session.close();
await inferenceModel.close();
await embeddingModel.close();
```

### Web Setup (Embeddings + VectorStore)

**Option 1: Use CDN (Recommended for most users)**

Add script tags to your `index.html`:
```html
<!-- Load from jsDelivr CDN (version 0.14.0) -->
<script src="https://cdn.jsdelivr.net/gh/DenisovAV/flutter_edge_ai@0.14.0/web/cache_api.js"></script>
<script type="module" src="https://cdn.jsdelivr.net/gh/DenisovAV/flutter_edge_ai@0.14.0/web/litert_embeddings.js"></script>
<script type="module" src="https://cdn.jsdelivr.net/gh/DenisovAV/flutter_edge_ai@0.14.0/web/sqlite_vector_store.js"></script>
```

**Option 2: Use the package-provided SQLite vector store**

`flutter_edge_ai_sqlite` ships a custom `sqlite3.wasm` with `sqlite-vec`
linked in. Copy it into your app as described in the package's
[Setup guide](../packages/flutter_edge_ai_sqlite/README.md#setup):

```bash
mkdir -p web/rag
cp <flutter_edge_ai_sqlite_package_path>/web/rag/sqlite3.wasm web/rag/sqlite3.wasm
```

### Legacy API (Still supported)

<details>
<summary>Click to expand Legacy API for embeddings</summary>

```dart
// Create embedding model specification
final embeddingSpec = MobileModelManager.createEmbeddingSpec(
  name: 'EmbeddingGemma 1024',
  modelUrl: 'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq1024_mixed-precision.tflite',
  tokenizerUrl: 'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
);

// Download with progress tracking
final mobileManager = FlutterEdgeAiPlugin.instance.modelManager as MobileModelManager;
mobileManager.downloadModelWithProgress(embeddingSpec, token: 'your_hf_token').listen(
  (progress) => print('Download progress: ${progress.overallProgress}%'),
  onError: (error) => print('Download error: $error'),
  onDone: () => print('Download completed'),
);

// Create embedding model instance
final embeddingModel = await FlutterEdgeAiPlugin.instance.createEmbeddingModel(
  modelPath: '/path/to/embeddinggemma-300M_seq1024_mixed-precision.tflite',
  tokenizerPath: '/path/to/sentencepiece.model',
  preferredBackend: PreferredBackend.gpu,
);
```

</details>

### Important Notes

- ✅ EmbeddingGemma models require HuggingFace authentication token for gated repositories
- ✅ Embedding models use the same unified download and management system as inference models
- ✅ Each embedding model consists of both model file (.tflite) and tokenizer file (.model)
- ✅ Different sequence length options allow trade-offs between accuracy and performance
- ✅ Modern API provides separate progress tracking for model and tokenizer downloads
- ✅ **VectorStore (RAG) is available on ALL platforms** - Android/iOS use native SQLite, Web uses SQLite WASM (wa-sqlite + OPFS)

### VectorStore Performance

VectorStore stores embeddings as binary BLOBs in SQLite, auto-detects embedding dimension (256D-4096D), and uses HNSW (Hierarchical Navigable Small World) for O(log n) approximate nearest neighbor search on large datasets — falling back to brute-force on small ones. The same `searchSimilar()` API works on Android, iOS, and Web.

```dart
// HNSW is enabled by default. To disable for small datasets:
FlutterEdgeAiPlugin.instance.enableHnsw = false;
```

See the core package [CHANGELOG.md](../packages/flutter_edge_ai/CHANGELOG.md) for the full performance history.

11. **Checking Token Usage**
You can check the token size of a prompt before inference. The accumulated context should not exceed maxTokens to ensure smooth operation.

```dart
int tokenCount = await session.sizeInTokens('Your prompt text here');
print('Prompt size in tokens: $tokenCount');
```

12. **Closing the Model**

When you no longer need to perform any further inferences, call the close method to release resources:

```dart
await inferenceModel.close();
```

If you need to use the inference again later, remember to call `createModel` again before generating responses.

## Migration from Legacy to Modern API

If you're upgrading from the Legacy API, here are common migration patterns:

### Installing Models

<table>
<tr>
<th>Legacy API</th>
<th>Modern API</th>
</tr>
<tr>
<td>

```dart
// Network download
final spec = MobileModelManager.createInferenceSpec(
  name: 'model.bin',
  modelUrl: 'https://example.com/model.bin',
);

await FlutterEdgeAiPlugin.instance.modelManager
  .downloadModelWithProgress(spec, token: token)
  .listen((progress) {
    print('${progress.overallProgress}%');
  });
```

</td>
<td>

```dart
// Network download
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
)
  .fromNetwork(
    'https://example.com/model.bin',
    token: token,
  )
  .withProgress((progress) {
    print('$progress%');
  })
  .install();
```

</td>
</tr>
<tr>
<td>

```dart
// From assets
await modelManager.installModelFromAssetWithProgress(
  'model.bin',
  loraPath: 'lora.bin',
).listen((progress) {
  print('$progress%');
});
```

</td>
<td>

```dart
// From assets
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
)
  .fromAsset('model.bin')
  .withProgress((progress) {
    print('$progress%');
  })
  .install();

// LoRA weights can be installed with the model
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
)
  .fromAsset('model.bin')
  .withLoraFromAsset('lora.bin')
  .install();
```

</td>
</tr>
</table>

### Checking Model Installation

<table>
<tr>
<th>Legacy API</th>
<th>Modern API</th>
</tr>
<tr>
<td>

```dart
final spec = MobileModelManager.createInferenceSpec(
  name: 'model.bin',
  modelUrl: url,
);

final isInstalled = await FlutterEdgeAiPlugin
  .instance.modelManager
  .isModelInstalled(spec);
```

</td>
<td>

```dart
final isInstalled = await FlutterEdgeAi
  .isModelInstalled('model.bin');
```

</td>
</tr>
</table>

### Key Migration Notes

- ✅ **Simpler imports**: Use `package:flutter_edge_ai/core/api/flutter_edge_ai.dart`
- ✅ **Builder pattern**: Chain methods for cleaner code
- ✅ **Callback-based progress**: Simpler than streams for most cases
- ✅ **Type-safe sources**: Compile-time validation of source types
- ⚠️ **Breaking change**: Progress values are now `int` (0-100) instead of `DownloadProgress` object
- ⚠️ **Separate files**: Model and LoRA weights installed independently

### Model Creation and Inference

**Modern API (Recommended):**

```dart
// Create model with runtime configuration
final inferenceModel = await FlutterEdgeAi.getActiveModel(
  maxTokens: 2048,
  preferredBackend: PreferredBackend.gpu,
);

final chat = await inferenceModel.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello!', isUser: true));
final response = await chat.generateChatResponse();
```

**Legacy API (Still supported):**

```dart
// Works with both Legacy and Modern installation methods
final inferenceModel = await FlutterEdgeAiPlugin.instance.createModel(
  modelType: ModelType.gemmaIt,
  preferredBackend: PreferredBackend.gpu,
  maxTokens: 2048,
);

final chat = await inferenceModel.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello!', isUser: true));
final response = await chat.generateChatResponse();
```
