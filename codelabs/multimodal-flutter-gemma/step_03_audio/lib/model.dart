import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// One model this app knows how to install.
///
/// [fileName] doubles as the model's id: `FlutterEdgeAi.isModelInstalled` takes
/// the file name the model was installed under, not a display name.
class ModelChoice {
  const ModelChoice({
    required this.label,
    required this.nativeUrl,
    required this.nativeFileName,
    required this.nativeSize,
    required this.webUrl,
    required this.webFileName,
    required this.webSize,
    required this.modelType,
  });

  final String label;
  final String nativeUrl;
  final String nativeFileName;
  final String nativeSize;
  final String webUrl;
  final String webFileName;
  final String webSize;
  final ModelType modelType;

  /// `flutter_edge_ai_litertlm`'s web arm is a separate build of the same
  /// checkpoint — the native file is not the one to hand it.
  String get url => kIsWeb ? webUrl : nativeUrl;

  /// The install id. `isModelInstalled` is keyed by it, so it has to be the
  /// file the URL downloads — a test holds the two together.
  String get fileName => kIsWeb ? webFileName : nativeFileName;

  String get sizeLabel => kIsWeb ? webSize : nativeSize;
}

/// The model this step swaps to, and the one `complete` ships.
///
/// The repository is ungated, so nothing here needs a Hugging Face token and
/// no run needs `--dart-define`.
abstract final class Models {
  /// Gemma 4 E2B reads pictures and listens to audio with the same weights.
  ///
  /// Step 2's SmolVLM2 has no audio encoder, and a session flag cannot switch
  /// on something the checkpoint does not carry — so audio costs a second
  /// download, seven times the first at 2.59 GB. You pay it once: both
  /// modalities come out of these weights, so nothing here ever holds two
  /// models open to cover two kinds of input.
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    nativeUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    nativeFileName: 'gemma-4-E2B-it.litertlm',
    nativeSize: '2.59 GB',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    webFileName: 'gemma-4-E2B-it-web.litertlm',
    webSize: '2.0 GB',
    modelType: ModelType.gemma4,
  );
}
