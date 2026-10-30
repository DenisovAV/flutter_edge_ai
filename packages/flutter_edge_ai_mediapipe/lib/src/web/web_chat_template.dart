// Which chat format the web session writes its turns in. Platform-neutral: the
// caller hands over how to read the first bytes of the file, so VM tests cover
// every branch.
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';

import 'task_chat_format.dart';
import 'web_prompt.dart';

/// The turn markers of a loaded file: what it declares, else what its
/// [modelType] implies, else none (the turns are written as plain text).
///
/// A file that carries `prompt_templates` (field 17) gets none: the runtime
/// reads that message itself and may add its own markers, so ours on top of
/// them would write each turn twice.
///
/// What goes wrong is printed, because [edgeAiLog] is silent in a release
/// build and a model that answers badly because of this is where it gets
/// reported.
Future<WebChatTemplate?> resolveWebChatTemplate({
  required Future<Uint8List> Function() readPrefix,
  required ModelType modelType,
}) async {
  String? readError;
  try {
    final format = readTaskChatFormat(await readPrefix());
    if (format != null && format.hasRuntimePromptTemplates) {
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_mediapipe] The model file carries prompt templates '
        'for the runtime; the turns are sent without markers of our own.',
      );
      return null;
    }
    if (format?.template case final declared?) {
      edgeAiLog('[MediaPipe Web] chat format from the model file: $declared');
      return declared;
    }
  } catch (e) {
    readError = '$e';
  }
  final implied = switch (modelType) {
    ModelType.gemma4 => WebChatTemplate.gemma4,
    ModelType.gemmaIt => WebChatTemplate.gemma3,
    _ => null,
  };
  final fallback = implied == null
      ? 'the turns are sent as plain text'
      : 'using the format of $modelType';
  // ignore: avoid_print
  print(
    readError == null
        ? '[flutter_edge_ai_mediapipe] The model file declares no chat format; '
              '$fallback.'
        : '[flutter_edge_ai_mediapipe] The model file could not be read for '
              'its chat format ($readError); $fallback.',
  );
  return implied;
}
