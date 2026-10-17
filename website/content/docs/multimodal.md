---
title: Multimodal
description: Send image and audio input to models with a vision or audio encoder, e.g. Gemma 4 and Gemma 3n.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

flutter_edge_ai supports **text + image** input (vision) and **audio** input with
the right models. Multimodal models require more memory and are recommended for
devices with 8GB+ RAM.

## Vision (image input)

Vision needs a model with a vision encoder — e.g. **Gemma 4 E2B/E4B**, **Gemma 3n
E2B/E4B** and **FastVLM 0.5B** (desktop); [Models](/docs/models) lists which
models take images. The OS built-in model takes images on Android (Gemini Nano —
see [Built-in AI](/docs/builtin-ai)). **Gemma 4** vision runs on all
four platforms (Android, iOS, Desktop, and Web with the MediaPipe `-web.task`
build, which has no thinking or Gemma 4 function calling); **Gemma3n** vision runs on Android,
iOS, and Desktop only — its web build is `.litertlm`, which is text-only. On the
`.litertlm` engine the
text decoder runs on your chosen backend (on GPU: OpenCL on Android, Metal on
Apple, Vulkan/WebGPU on Linux, DX12/WebGPU on Windows), while the **vision
encoder runs where the bundle says** — its declared `backend_constraint`, else
the NPU it is compiled for, else CPU (the Metal/WebGPU delegates can't prepare
its ops) — so image input works on a GPU text backend with no extra config.

### Enabling vision

Set `supportImage: true` when creating the model:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  preferredBackend: PreferredBackend.gpu,   // drives the text decoder
  supportImage: true,
);
```

`preferredBackend` selects the text decoder's backend. Left unset, the vision
encoder follows the bundle ([where a model runs](/docs/litertlm#where-a-model-runs)):
its declared `backend_constraint` (CPU when that allows it; Gemma 3n's vision
encoder declares GPU), else the NPU its section is compiled for, else CPU (the
Metal/WebGPU delegates can't prepare its `STABLEHLO_COMPOSITE` ops — routing
it to GPU used to hard-fail at model load). Set
`preferredVisionBackend` only where the section allows it —
`readLiteRtLmBundleInfo(path).visionEncoder?.backendConstraint` shows what it
declares, and a backend it excludes is refused before the model loads;
`model.activeVisionBackend` says where it runs.

### Sending an image

The flag goes in **two** places: on `getActiveModel` it loads the vision encoder,
on `createChat` the session declares it will send images. `.litertlm` inherits the
model's flag, but MediaPipe `.task` does not — on Android and iOS a chat created
without it **drops the image and answers about the text alone**, with no error and
no log in a release build. On web the chat follows the model instead: an image sent
to a model loaded without `supportImage: true` throws `ArgumentError`. Set it in
both places either way.

```dart
// Text + Image
final message = Message.withImages(
  text: "What's in this image?",
  imageBytes: [imageBytes],
  isUser: true,
);

// Image only
final imageMessage = Message.imagesOnly(imageBytes: [imageBytes], isUser: true);

final chat = await model.createChat(supportImage: true);
await chat.addQueryChunk(message);
final response = await chat.generateChatResponse();

// Check if a message contains an image
if (message.hasImage) {
  print('This message contains an image');
}
```

<Info>

flutter_edge_ai automatically handles common image formats (JPEG, PNG, etc.) when
using `Message.withImages()` or `Message.withImage()`. The GPU backend speeds up
text decoding; the encoders run where the bundle says
(`model.activeVisionBackend`, `model.activeAudioBackend`): on Gemma 4 image and
audio encoding run on the CPU, on Gemma 3n image encoding runs on the GPU and
audio encoding on the CPU. Neither audio encoder accepts the GPU (see below).

</Info>

## Audio (voice input)

Audio input works with `.litertlm` models that include the audio encoder — e.g.
**Gemma 4 E2B/E4B** and **Gemma 3n** `.litertlm`, and **VibeVoice-ASR** for
transcription (see [Models](/docs/models)).

| Platform | Audio support |
|---|---|
| Android | ✅ Full |
| iOS | ✅ Device only (Simulator is CPU-only / no GPU) |
| Desktop (macOS/Windows/Linux) | ✅ `.litertlm` only (via FFI) |
| Web | ❌ Not supported |

Enable audio with `supportAudio: true`:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  preferredBackend: PreferredBackend.gpu,        // text decoder
  supportImage: true,
  supportAudio: true,                            // the encoder follows the bundle
);
```

Sending audio is `Message.withAudio` — and `audioBytes` is a whole WAV file,
16 kHz mono, header included (the opposite of `flutter_edge_ai_speech`, whose
`transcribe` takes raw PCM):

```dart
final chat = await model.createChat(supportAudio: true);
await chat.addQueryChunk(Message.withAudio(
  text: 'What is said in this recording?',
  audioBytes: wavBytes,
  isUser: true,
));
final response = await chat.generateChatResponse();
```

<Warning>

Audio input needs a model that includes the audio encoder: `.litertlm` on
Android, iOS and desktop. The Gemma 3n MediaPipe `.task` files carry none
(`TF_LITE_AUDIO_ENCODER`), and neither web engine takes audio. Leave
`preferredAudioBackend` unset: the encoder follows the bundle, and the
published Gemma 4 and Gemma 3n audio encoders declare `backend_constraint`
cpu, so `PreferredBackend.gpu` is refused for them
(`readLiteRtLmBundleInfo(path).audioEncoder?.backendConstraint` shows it).
`preferredBackend` only moves the text decoder.

</Warning>

### Order of images, audio and text

The chat template renders a message's parts in the order they arrive, so the
order is chosen by the model type (`flutter_edge_ai` 2.4.0,
`flutter_edge_ai_litertlm` 1.14.0):

- `ModelType.gemma4`: images, then the text, then the audio, as the
  [Gemma 4 model card](https://huggingface.co/google/gemma-4-E2B-it) asks.
  On Galaxy S24 and S25 Ultra phones this order cut failed spoken requests
  ("I don't have any audio input") from 23 to 8 in 160.
- Every other type: images, then the audio, then the text, as before.

A model whose template expects another order takes `multimodalOrder`:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  supportAudio: true,
  multimodalOrder: MultimodalOrder.imagesAudioText, // audio before the text
);
```

`MultimodalOrder.imagesTextAudio` and `MultimodalOrder.imagesAudioText` are the
two presets, and `MultimodalOrder.forModelType(type)` returns the one a type
gets. Any other order is `MultimodalOrder(images:, audio:)`, a `MediaPosition`
(`beforeText`, the default, or `afterText`) for each:

```dart
// The text first, then the images, then the audio.
const textFirst = MultimodalOrder(
  images: MediaPosition.afterText,
  audio: MediaPosition.afterText,
);
```

Media on the same side of the text keep a fixed order, images before audio,
and several images keep the order they were given in. A message with no text
still carries its empty text part, so an audio-only message is the same in
every order.

Only the native `.litertlm` engine reads it. The measurements are in the
[`flutter_edge_ai_litertlm` README](https://pub.dev/packages/flutter_edge_ai_litertlm#multimodal-order).

## Web limitations

The web `.litertlm` path (`@litert-lm/core`, early preview) does **not** support
vision or audio yet — its JS API creates the LLM engine with no vision or audio
executor, so an image or audio message throws `UnsupportedError`. For full
vision on web, use **MediaPipe `.task` web** models (which do support image
input; MediaPipe LLM Inference is maintenance-only — see [MediaPipe](/docs/mediapipe)). See
[Troubleshooting](/docs/troubleshooting#litert-lm-on-web-early-preview) for the
full web `.litertlm` feature matrix.

## Troubleshooting multimodal

- Ensure the model has a vision (or audio) encoder — see [Models](/docs/models).
- Set `supportImage: true` when creating the model (and `supportAudio: true` for audio).
- Check device memory — multimodal models require more RAM.
- Use the GPU backend for faster text decoding. The vision and audio encoders
  follow the bundle when unset (its `backend_constraint`, else the NPU it is
  compiled for, else CPU); set `preferredVisionBackend`/`preferredAudioBackend`
  only where the section allows it, or the load is refused.
- Image input no longer fails at model load on a GPU backend: an encoder whose
  bundle declares nothing runs on CPU in every `flutter_edge_ai_litertlm`
  release (the fix shipped in `flutter_gemma_litertlm` 1.4.2).
- After `stopGeneration()` on a `.litertlm` model on Android, iOS or desktop the
  chat keeps working, with images and audio from earlier turns still in its
  context: the conversation is rewound to before the stopped turn. On the NPU
  it continues from a text copy of the history instead, so send the image again
  if the next question is about it.
