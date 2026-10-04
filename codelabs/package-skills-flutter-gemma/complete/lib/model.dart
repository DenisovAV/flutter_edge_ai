import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// One model, and everything the app needs to install and open it.
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

  /// The web engine reads its own build of the same model.
  String get url => kIsWeb ? webUrl : nativeUrl;

  /// The install id. `isModelInstalled` is keyed by it, so it has to be the
  /// file the URL downloads — a test holds the two together.
  String get fileName => kIsWeb ? webFileName : nativeFileName;

  String get sizeLabel => kIsWeb ? webSize : nativeSize;
}

abstract final class Models {
  /// Gemma 4 E2B needs no Hugging Face token, and it can call tools, which
  /// the colour tool relies on.
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    nativeUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    nativeFileName: 'gemma-4-E2B-it.litertlm',
    nativeSize: '2.6 GB',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    webFileName: 'gemma-4-E2B-it-web.litertlm',
    webSize: '2.0 GB',
    modelType: ModelType.gemma4,
  );
}
