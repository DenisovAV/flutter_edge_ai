# Flutter Edge AI llama.cpp engine

Run local GGUF chat models through Flutter Edge AI, powered by
[llamadart](https://pub.dev/packages/llamadart). Register the providers, install
a model, then use the usual Edge AI chat API.

The package has runners for Android, iOS, macOS, Windows, Linux and Web.
Tools, thinking, images/audio and native LoRA require compatible models and
runtimes. See [advanced usage](doc/advanced_usage.md) and the
[platform qualification matrix](doc/platforms.md) for their limits.

**Unreleased:** this package is being prepared for upstream contribution.
Use the checked-in example today; a pub.dev install command will follow release.
The minimum is Flutter **3.44 / Dart 3.12**, with core **2.3.2+**,
llamadart **0.11.1+** and Apple companion **0.0.21**. Connector CI uses Flutter
3.47.1 / Dart 3.13.1 for reproducible checks. GGUF embeddings are deferred.

## Try a chat in a few minutes

From `packages/flutter_edge_ai_llama/`:

```sh
python3 tool/fetch_test_model.py
cd example
flutter pub get
flutter run -d macos
```

The downloader verifies a pinned **SmolLM2-135M-Instruct-Q8_0** GGUF
(about 145 MB) and prints its path: `tool/fixtures/chat.gguf`.
This small model is useful for checking the integration; its answers are
limited compared with larger instruction-tuned models. You can also download
the [model file directly](https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/09816acd5d99df7be770d85ea30822623dab342c/SmolLM2-135M-Instruct-Q8_0.gguf).

1. Click **Choose model** and select the downloaded `chat.gguf`.
2. Wait for **Ready**, then send “Say hello in one sentence.”
3. Try a follow-up, **Stop** during a response, or **New chat** to clear history.
4. Restart the app: it reloads the installed model and starts a fresh conversation.

The native picker copies the model into app-owned storage, preserving the
original. Allow disk space for both copies. Model download and first-build
runtime downloads need a network connection; native generation uses local files.
The demo uses a 2,048-token context and 128-token response limit.

For another native platform, run `flutter devices` and replace `macos` with the
device ID, `linux`, or `windows` on a compatible host. The example already
configures Apple SwiftPM and llama.cpp-only packaging; Android/Linux/Windows
select CPU libraries. Its deployment floors are iOS 16.4, macOS 14 and Android
API 24. Passing builds do not qualify every device or GPU.

### Run in a browser

From the package directory, prepare the runtime files before launching:

```sh
python3 tool/fetch_web_assets.py
cd example
flutter pub get
flutter run -d chrome \
  --web-header Cross-Origin-Opener-Policy=same-origin \
  --web-header Cross-Origin-Embedder-Policy=require-corp
```

Paste the direct model-file URL above into **GGUF model URL** and click
**Load URL**. The host must allow CORS and cross-origin resource access. If a
remote host blocks the request, serve the downloaded fixture locally with
`python3 tool/serve_web_fixture.py --model-path tool/fixtures/chat.gguf` in a
second terminal from the package directory, then use
`http://127.0.0.1:8098/chat.gguf`.

The preparation script verifies the pinned llama.cpp bridge files and stages
them under the example's origin. For deployment, build with
`python3 tool/verify.py build --platform web` and host `example/build/web` with
the same COOP/COEP headers on HTML, worker and Wasm responses. `_headers` is
included for hosts that support it. Large models can exceed browser memory.

## Add it to your app

While the package is unreleased, use a path dependency on your clone. Replace
the path below with the package directory relative to your app's pubspec:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_edge_ai: ^2.3.2
  flutter_edge_ai_llama:
    path: ../flutter_edge_ai/packages/flutter_edge_ai_llama
  # Add directly for iOS/macOS SwiftPM linkage:
  llamadart_llama_cpp_flutter: 0.0.21

hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

Merge the hook settings into your **application's** pubspec. In a pub workspace,
put them in the workspace root. Dependency settings do not propagate: without
this selection, llamadart 0.11.1 includes LiteRT-LM too where available.
Registering only the GGUF provider changes routing, not packaged runtime files.
When `flutter_edge_ai_litertlm` is also present, `[llama_cpp]` is mandatory to avoid
duplicate libraries and ambiguous runtime loading. Without the define, builds
fail on Android/Linux/Windows; on iOS without the companion the wrong LiteRT-LM
library can be loaded. On Apple the llama.cpp companion is required too.
Also omit `flutter_edge_ai_litertlm` and `llamadart_litert_lm_flutter` to keep
the app llama.cpp only. Core itself bundles no inference runtime.

On Apple platforms, run `flutter config --enable-swift-package-manager` before
building your app, then use deployment targets
iOS **16.4+** / macOS **14+**, matching the example's Xcode configuration.
The direct companion dependency links the matching llama.cpp XCFramework.
On iOS enable `com.apple.developer.kernel.extended-virtual-addressing` and
`com.apple.developer.kernel.increased-memory-limit`; see the example entitlements.
The LiteRT-LM macOS CocoaPods recipe disables SwiftPM and conflicts with this
companion recipe; that combined setup is not qualified.
Windows users need the Microsoft Visual C++ runtime for the app architecture.
See [platform setup](doc/platforms.md#consumer-setup) for backend selection.

### Stream a response

Replace the model path with an existing instruction-tuned GGUF. This is a
minimal API example; a Flutter UI displays the streamed tokens instead of
printing them.

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterEdgeAi.initialize(
    inferenceEngines: const [LlamaEngineProvider()],
  );

  await FlutterEdgeAi.installModel(
    modelType: ModelType.general,
    fileType: ModelFileType.gguf,
  ).fromFile('/absolute/path/to/chat.gguf').install();

  final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
  try {
    final chat = await model.openChat(maxOutputTokens: 128);
    await chat.addQuery(Message.text(text: 'Hello!', isUser: true));
    await for (final response in chat.generateChatResponseAsync()) {
      if (response is TextResponse) print(response.token);
    }
  } finally {
    await model.close();
  }
}
```

Declare `ModelFileType.gguf`; routing uses the declared type, including for
extensionless paths or URLs. Other file types are handled by their own engines.
On Web, replace
`.fromFile(...)` with `.fromNetwork(modelUrl)` and prepare the assets/headers above.

Models installed by an earlier draft as `binary` must be installed again with
`ModelFileType.gguf`; the connector no longer claims binary specs.

Core restores the installed imported model during initialization. Load it
with `getActiveModel`; conversation history starts fresh. No connector-specific
restore call is needed.

`maxTokens` is the whole context budget (prompt, history and response).
`maxOutputTokens` optionally limits one response; omitted values use the remaining
rendered context. Truncated tool turns and empty answers fail without committing
partial history. Completed tool results survive cancellation or an error. Stop with
`await chat.session.stopGeneration()`; an interrupted turn is discarded so the
conversation can continue. Close the model when your feature is finished.

## Contribution scope

This contribution provides inference only. GGUF embeddings are preserved for a
[follow-up](doc/deferred_embeddings.md) against core's new embedding SPI.

The connector uses core 2.3's public `engine.dart` / `engine_web.dart` APIs.
Dedicated GGUF identity removes the routing conflict with MediaPipe. Core restores
paired LoRA adapters after restart and refuses restoration if an adapter is missing.
They ship in core 2.3.2, the minimum version required by this connector.

## Troubleshooting

| What you see | What to check |
| --- | --- |
| No engine handles the model | Declare `ModelFileType.gguf` and register `LlamaEngineProvider`. |
| Model loading fails | Check the model path, available memory, and that the file is a complete, compatible GGUF. |
| Context budget exceeded | Start a new chat, shorten the prompt, or increase `maxTokens` if memory permits. There is no automatic context compaction. |
| Reply ends early | Increase `maxOutputTokens`; the demo explicitly caps replies at 128 tokens; omit the cap for longer replies. |
| Browser worker/model request fails | Prepare the assets, use COOP/COEP headers, and check model-host CORS. OPFS handles are unsupported; use cacheApi or network URLs. |
| GPU request is rejected | Check that the packaged backend and device support GPU offload. CPU is the baseline; unknown offload is reported as unknown. |

## More details

- [Advanced API usage](doc/advanced_usage.md): tools, thinking, independent chats, media and LoRA.
- [Platform setup and qualification](doc/platforms.md): current capabilities, setup requirements and qualification gaps.
- [Example walkthrough](example/README.md): first run and a short showcase sequence.
- [Contributor checks](doc/development.md): tests, builds and package validation.

## Web setup from an installed package

The installed package includes `tool/fetch_web_assets.py`,
`tool/validate_web_build.py` and the example's Web files. Find its `rootUri` in
your app's `.dart_tool/package_config.json` (resolve it relative to that file).
With Python 3 and curl installed, stage the checksum-verified bridge into your app:

```sh
python3 <package-root>/tool/fetch_web_assets.py --output <app-root>/web/webgpu_bridge
```

Copy `example/web/cache_api.js`, `cache_api.LICENSE` and `_headers` into your
app's `web/` directory. Hosts that ignore `_headers` need equivalent server configuration.
Use the module bootstrap in `example/web/index.html`: it loads the local bridge,
sets its worker/core/Wasm URLs before Flutter starts, and reports load errors.
Build with `flutter build web --wasm`, then run:

```sh
python3 <package-root>/tool/validate_web_build.py <app-root>/build/web
```

Serve the app,
worker and Wasm responses with COOP `same-origin` and COEP `require-corp`.
Model hosts need CORS. See the example `_headers` file for compatible hosts.
Vulkan is included by default on supported native Android/Linux/Windows targets;
the example's root hooks explicitly select CPU-only bundles.
