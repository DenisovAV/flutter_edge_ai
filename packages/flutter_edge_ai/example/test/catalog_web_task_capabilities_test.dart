import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether [model] runs on MediaPipe on the web: the model list shows it there
/// (a web URL or a local asset) and its file is one MediaPipe takes.
bool _runsOnMediaPipeWeb(Model model) =>
    (model.localModel || model.webUrl != null) &&
    (model.fileType == ModelFileType.task ||
        model.fileType == ModelFileType.binary);

/// The families whose `<think>` tags core splits from the reply itself, on
/// any engine (ModelThinkingFilter in extensions.dart).
const _thinkTagTypes = {
  ModelType.deepSeek,
  ModelType.qwen,
  ModelType.qwen3,
  ModelType.qwen35,
};

void main() {
  // MediaPipe web ignores `tools` and has no thinking API (enableThinking is
  // only logged). Core makes up for the first by putting the tools in the
  // prompt, except for a format whose tool declarations the runtime injects;
  // for the second it splits <think> tags itself, but only for DeepSeek and
  // Qwen (ModelThinkingFilter in extensions.dart). The catalog drives the
  // example's capability chips and filters and what chat_screen asks for, so
  // a flag there offers a toggle that does nothing. Gemma 4's `-web.task`
  // entries used to claim both.
  test('no MediaPipe web entry offers function calling or thinking that '
      'core cannot provide', () {
    final mediaPipeWeb = Model.values.where(_runsOnMediaPipeWeb).toList();
    expect(
      mediaPipeWeb,
      containsAll([Model.gemma4_E2B_web, Model.gemma4_E4B_web]),
      reason: 'the rule must cover the Gemma 4 -web.task entries',
    );

    for (final model in mediaPipeWeb) {
      if (FunctionCallParser.runtimeInjectsToolDeclarations(
        model.modelType,
        fileType: model.fileType,
      )) {
        expect(model.supportsFunctionCalls, isFalse, reason: model.name);
      }
      if (model.isThinking) {
        expect(model.modelType, isIn(_thinkTagTypes), reason: model.name);
      }
    }
  });
}
