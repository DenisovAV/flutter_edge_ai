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
  });

  final String label;
  final String url;
  final String fileName;

  /// Which family's chat template and tool-call format the SDK uses.
  ///
  /// An agent is a tool loop, so this matters from Step 2 on: on a
  /// `.litertlm`, `ModelType.gemma4` puts the chat on the runtime's tool path,
  /// where LiteRT-LM renders the tool declarations into the prompt and hands
  /// each call back already parsed. Name a different family and every turn
  /// comes back as plain text, with nothing to say why.
  final ModelType modelType;

  final String sizeLabel;
}

/// The one model this codelab runs.
///
/// The repository is ungated, so nothing here needs a Hugging Face token and
/// no run needs `--dart-define`.
abstract final class Models {
  /// Gemma 4 E2B: about 2 billion effective parameters.
  ///
  /// An agent asks more of a model than a single function call does. It reads
  /// a list of skills, decides which one fits, loads its instructions, calls a
  /// tool, reads the result and only then answers — several turns of the same
  /// conversation, each one a decision. The 270M FunctionGemma of the function
  /// calling codelab picks a function well and holds no conversation; this one
  /// does both. It wants a phone with 6 GB of RAM or a desktop.
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    fileName: 'gemma-4-E2B-it.litertlm',
    modelType: ModelType.gemma4,
    sizeLabel: '2.59 GB',
  );
}
