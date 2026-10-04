import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// One model this app knows how to install.
///
/// [fileName] doubles as the model's id: `FlutterEdgeAi.isModelInstalled` takes
/// the file name the model was installed under, not a display name.
class ModelChoice {
  const ModelChoice({
    required this.nativeLabel,
    required this.nativeUrl,
    required this.nativeFileName,
    required this.nativeModelType,
    required this.nativeSize,
    required this.webLabel,
    required this.webUrl,
    required this.webFileName,
    required this.webModelType,
    required this.webSize,
  });

  final String nativeLabel;
  final String nativeUrl;
  final String nativeFileName;
  final ModelType nativeModelType;
  final String nativeSize;
  final String webLabel;
  final String webUrl;
  final String webFileName;
  final ModelType webModelType;
  final String webSize;

  /// The browser `.litertlm` runtime only ever runs a dedicated web export,
  /// and SmolVLM2 publishes none — a native file installs fine and then fails
  /// at engine creation. So on the web this app installs the Gemma 4 E2B web
  /// build instead: the same pair Step 3 installs natively, just early and
  /// staying text-only (that build's browser arm has no vision executor
  /// either — see Step 4).
  ///
  /// `modelType` follows: `general` for SmolVLM2, `gemma4` for the
  /// substitute — every call site reads it through this getter, so the two
  /// never drift apart.
  String get label => kIsWeb ? webLabel : nativeLabel;
  String get url => kIsWeb ? webUrl : nativeUrl;
  String get fileName => kIsWeb ? webFileName : nativeFileName;
  ModelType get modelType => kIsWeb ? webModelType : nativeModelType;
  String get sizeLabel => kIsWeb ? webSize : nativeSize;
}

/// The model this step runs.
///
/// The repository is ungated, so nothing here needs a Hugging Face token and
/// no run needs `--dart-define`.
abstract final class Models {
  /// A vision-language model small enough to feel like a text model. 0.36 GB
  /// is roughly what a photo-heavy app already spends on its image cache, so
  /// this is the version of "multimodal" you can put in a shipping app
  /// without an argument about download size — about a minute of download,
  /// and then it is looking at your photograph.
  ///
  /// It cannot hear, and that is not a gap in this step: it is a
  /// vision-language model, and the plugin lists audio input for Gemma 4 and
  /// Gemma 3n only (`flutter_edge_ai/README.md`). A session flag cannot switch
  /// on an encoder the checkpoint does not carry. It is why Step 3
  /// changes models, and it is the model half of the question `complete` asks
  /// at the end — a half that says no here while the device, happily holding
  /// a microphone, says yes.
  /// Run on macOS 2026-09-07: installs (0.36 GB) and answers "RED" to a
  /// 16x16 red square, with `supportImage` set on both `getActiveModel` and
  /// `createChat`. Nothing in CI runs a model, so this line is the only
  /// evidence these weights were ever executed.
  static const smolVlm2 = ModelChoice(
    nativeLabel: 'SmolVLM2 500M',
    nativeUrl:
        'https://huggingface.co/litert-community/SmolVLM2-500M/resolve/main/'
        'SmolVLM2-500M.litertlm',
    nativeFileName: 'SmolVLM2-500M.litertlm',
    // `general` and not `gemmaIt`: SmolVLM2 is not a Gemma, and the chat
    // template that ships inside the `.litertlm` is the right one to use.
    nativeModelType: ModelType.general,
    nativeSize: '0.36 GB',
    // The web substitute: the same Gemma 4 E2B web build Step 3 uses.
    webLabel: 'Gemma 4 E2B',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    webFileName: 'gemma-4-E2B-it-web.litertlm',
    webModelType: ModelType.gemma4,
    webSize: '2.0 GB',
  );
}
