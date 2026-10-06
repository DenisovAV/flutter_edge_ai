import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// One model this app knows how to install.
///
/// [fileName] doubles as the model's id: `FlutterEdgeAi.isModelInstalled` takes
/// the file name the model was installed under, not a display name.
///
/// Exactly one of [url] and [path] is set. A downloaded model has a URL; a
/// model you built yourself in Step 4 has a path on this machine, and nothing
/// else about it is different — which is the point of that step.
class ModelChoice {
  const ModelChoice({
    required this.label,
    required this.fileName,
    required this.modelType,
    required this.sizeLabel,
    required this.supportsThinking,
    required this.supportsRequiredToolChoice,
    this.url,
    this.path,
    this.maxTokens = 4096,
    this.preferredBackend,
  }) : assert(
         (url == null) != (path == null),
         'a model comes from a URL or from a file, not both and not neither',
       );

  /// A `.litertlm` already on this machine — the file `litetune convert`
  /// wrote, or any other one.
  ///
  /// The family is fixed to FunctionGemma because that is what Step 4
  /// produces, and nothing on disk records which family a `.litertlm` belongs
  /// to. Tune a different base and this is the line to change.
  factory ModelChoice.fromDisk(String path) {
    final fileName = path.split(RegExp(r'[/\\]')).last;
    return ModelChoice(
      label: fileName,
      fileName: fileName,
      path: path,
      modelType: ModelType.functionGemma,
      sizeLabel: 'on this machine',
      supportsThinking: false,
      supportsRequiredToolChoice: false,
    );
  }

  final String label;
  final String fileName;

  /// Which family's function-call format the SDK writes and reads.
  ///
  /// This is not decoration. On a `.litertlm` both families go through the
  /// runtime's own tool path — the declarations travel as structured
  /// `tools_json`, the call comes back parsed — but each family has its own
  /// wire format underneath, and the runtime picks it from this name. Name the
  /// wrong family and the model is handed a prompt these weights never saw and
  /// waits for a syntax they never emit — every turn comes back as plain text
  /// and nothing says why.
  final ModelType modelType;

  final String sizeLabel;

  /// Where the bytes are. Exactly one of these is non-null.
  final String? url;
  final String? path;

  /// The context window `getActiveModel` opens this model with — prompt,
  /// history, declarations, tool calls, tool responses and the reply all
  /// share it. It is NOT a reply-length cap; `maxOutputTokens` on the session
  /// is.
  final int maxTokens;

  /// The backend to ask for, or `null` to let the engine choose. Set only
  /// where one file needs it — see [Models.functionGemma].
  final PreferredBackend? preferredBackend;

  /// Can these weights reason out loud before answering?
  ///
  /// A property of the checkpoint, not of the app: `enableThinking: true` on a
  /// model with no thinking training does not produce reasoning, it produces
  /// an empty channel. FunctionGemma is a 270M model specialised for one
  /// thing, and reasoning is not it.
  final bool supportsThinking;

  /// Can this model be *forced* to call a tool?
  ///
  /// `ToolChoice.required` needs a way to say "you must call a function" in
  /// the prompt the model actually reads, and neither of these has one. On a
  /// `.litertlm` both families hand their declarations to the runtime as
  /// `tools_json`, which carries no `tool_choice`, so `required` is `auto` for
  /// both — and the SDK's old FunctionGemma warning is not even reached, since
  /// that lived on the path where the SDK wrote the declarations itself.
  /// Reasonable behaviour, and very confusing to watch if the app does not
  /// say so.
  final bool supportsRequiredToolChoice;

  /// Points an install at wherever this model's bytes are.
  ///
  /// The two branches are the whole difference between a model you downloaded
  /// and a model you tuned: `fromNetwork` fetches the file, `fromFile`
  /// registers one that is already here. Everything after this line — the
  /// session, the tools, the loop — cannot tell them apart.
  InferenceInstallationBuilder locate(InferenceInstallationBuilder builder) =>
      path != null ? builder.fromFile(path!) : builder.fromNetwork(url!);
}

/// The two models this app ships.
///
/// Both repositories are ungated, so nothing here needs a Hugging Face token
/// and no run needs `--dart-define`.
abstract final class Models {
  /// A 270M model whose whole job is function calling.
  ///
  /// 284 MB, and it does very little else — ask it a general question and the
  /// answer will be thin. That is the trade: calling a function is a narrow
  /// skill, and a model specialised for it can be a fraction of the size of
  /// one that also has to hold a conversation. It is also the base Step 4
  /// fine-tunes.
  static const functionGemma = ModelChoice(
    label: 'FunctionGemma 270M',
    url:
        'https://huggingface.co/sasha-denisov/function-gemma-270M-it/'
        'resolve/main/functiongemma-270M-it.litertlm',
    fileName: 'functiongemma-270M-it.litertlm',
    modelType: ModelType.functionGemma,
    sizeLabel: '284 MB',
    supportsThinking: false,
    supportsRequiredToolChoice: false,
    // What Steps 1–3 open it with. 1024 is the context this checkpoint was
    // built and measured at. The CPU is a workaround for this FILE: it was
    // converted before litetune 0.1.4 began setting
    // `prefer_activation_type=fp32`, and without that key the GPU path
    // answers every prompt with `<pad>` to the token limit. A model you
    // re-convert in Step 4 carries the key, so `fromDisk` keeps the defaults.
    maxTokens: 1024,
    preferredBackend: PreferredBackend.cpu,
  );

  /// The reason to pay 2.59 GB instead of 284 MB.
  ///
  /// Same four tools, same loop — but these weights can reason out loud
  /// before deciding which function to call, and they hold a conversation
  /// either side of it. Nine times the download for the thing the small model
  /// cannot do at all.
  ///
  /// What it does NOT buy is `ToolChoice.required`: its declarations reach the
  /// runtime as `tools_json`, which has no `tool_choice` field, so `required`
  /// is `auto` here exactly as it is on FunctionGemma — see
  /// [supportsRequiredToolChoice].
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    fileName: 'gemma-4-E2B-it.litertlm',
    modelType: ModelType.gemma4,
    sizeLabel: '2.59 GB',
    supportsThinking: true,
    supportsRequiredToolChoice: false,
  );

  /// The ones with a download, in the order the list shows them.
  static const downloadable = [gemma4, functionGemma];
}
