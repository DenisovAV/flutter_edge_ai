import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// One model this app knows how to install.
///
/// [fileName] doubles as the model's id: `FlutterEdgeAi.isModelInstalled` takes
/// the file name the model was installed under, not a display name.
class ModelChoice {
  const ModelChoice({
    required this.label,
    required this.url,
    required this.fileName,
    required this.modelType,
    required this.sizeLabel,
    required this.requiresToken,
  });

  final String label;
  final String url;
  final String fileName;
  final ModelType modelType;
  final String sizeLabel;

  /// Hugging Face serves this repo behind a licence gate. Accept the licence
  /// once on the model page, then run with `--dart-define=HF_TOKEN=hf_...`.
  final bool requiresToken;
}

/// The models this quickstart offers.
///
/// All of them are `.litertlm`, the format the LiteRT-LM engine reads on
/// Android, iOS, desktop and the web — but the browser engine
/// (`@litert-lm/core`) only runs a `.litertlm` file exported for it. [gemma3]
/// and [gemma4] are native builds: they install fine on web and then fail when
/// the engine starts. [gemma4Web] is this app's one web-exported model, and
/// `main.dart` picks it there instead. (`.task` files are MediaPipe-only — a
/// different engine package, and no desktop support.)
abstract final class Models {
  /// The plugin's namesake. `ekv4096` in the file name is the KV-cache the
  /// weights were built for, so this model can carry a 4096-token context.
  static const gemma3 = ModelChoice(
    label: 'Gemma 3 1B',
    url:
        'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/'
        'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    fileName: 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    modelType: ModelType.gemmaIt,
    sizeLabel: '0.6 GB',
    requiresToken: true,
  );

  /// No Hugging Face account? This repo is ungated. Same code path — the only
  /// thing that changes is which constant you hand to the app. It is also the
  /// largest of the three: 2.59 GB, and a phone with 6 GB of RAM or more.
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    fileName: 'gemma-4-E2B-it.litertlm',
    modelType: ModelType.gemma4,
    sizeLabel: '2.59 GB',
    requiresToken: false,
  );

  /// The web build. The browser engine (`@litert-lm/core`) runs only models
  /// exported for it — the native files above install on web and then fail
  /// when the engine starts — and Gemma 4 E2B is the smallest one published.
  static const gemma4Web = ModelChoice(
    label: 'Gemma 4 E2B (web build)',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    fileName: 'gemma-4-E2B-it-web.litertlm',
    modelType: ModelType.gemma4,
    sizeLabel: '2.0 GB',
    requiresToken: false,
  );
}

/// The speech-to-text model: moonshine tiny, English, 109 MB.
///
/// Two files, not one. The `.tflite` turns audio into token ids and the
/// `tokenizer.json` turns those ids back into words, and they come from two
/// different repositories. [SttModelType.moonshine] tells the speech package
/// which pipeline to run over them.
abstract final class Moonshine {
  static const modelUrl =
      'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/'
      'moonshine_tiny_5s_f32.tflite';
  static const tokenizerUrl =
      'https://huggingface.co/UsefulSensors/moonshine/resolve/main/'
      'ctranslate2/tiny/tokenizer.json';

  /// What `isModelInstalled` is keyed by: the last segment of [modelUrl].
  static const fileName = 'moonshine_tiny_5s_f32.tflite';

  /// The `5s` in the file name is the model's input window. Audio past it is
  /// cut off, not transcribed, so the app stops recording at this length.
  static const maxRecording = Duration(seconds: 5);
}

/// The text-to-speech model: Inflect-Nano-v2, English, about 36 MB.
///
/// A bundle rather than a file. Its two networks are 8 MB; the rest is the
/// pronunciation data it shares with Matcha-TTS — a word dictionary and a small
/// network for words the dictionary does not have — which the installer
/// fetches from the Matcha repository on its own. [TtsModelType.inflect] names
/// the bundle, so this one URL is all the app gives it.
abstract final class Inflect {
  static const baseUrl =
      'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/';
}
