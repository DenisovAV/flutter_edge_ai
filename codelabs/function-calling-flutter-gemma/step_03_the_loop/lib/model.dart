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

  /// Which family's function-call format the SDK should read and write.
  ///
  /// This is not decoration. On a `.litertlm`, `ModelType.functionGemma` puts
  /// the chat on the runtime's tool path: LiteRT-LM renders the declarations
  /// into the developer turn these weights were trained on, and hands the call
  /// back already parsed. Name a different family and the model is served a
  /// prompt it never saw, in a syntax it never emits — so every turn comes
  /// back as plain text and nothing says why.
  final ModelType modelType;

  final String sizeLabel;
}

/// The one model this step ships.
///
/// The repository is ungated, so nothing here needs a Hugging Face token and
/// no run needs `--dart-define`.
abstract final class Models {
  /// A 270M model whose whole job is function calling.
  ///
  /// 284 MB — small enough to download while you read this page, and small
  /// enough that it does very little else: ask it a general question and the
  /// answer will be thin. That is the trade this step is making on purpose.
  /// Calling a function is a narrow skill, and a model specialised for it can
  /// be a fraction of the size of one that also has to hold a conversation.
  static const functionGemma = ModelChoice(
    label: 'FunctionGemma 270M',
    url:
        'https://huggingface.co/sasha-denisov/function-gemma-270M-it/'
        'resolve/main/functiongemma-270M-it.litertlm',
    fileName: 'functiongemma-270M-it.litertlm',
    modelType: ModelType.functionGemma,
    sizeLabel: '284 MB',
  );
}
