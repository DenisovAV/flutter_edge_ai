import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether [model] runs on web from a MediaPipe `-web.task` file: a `.task`
/// entry whose web URL, or local asset, is one.
bool _isWebTask(Model model) =>
    model.fileType == ModelFileType.task &&
    [
      model.webUrl,
      if (model.localModel) model.baseUrl,
    ].any((url) => url != null && url.endsWith('-web.task'));

void main() {
  // MediaPipe web has no thinking API (enableThinking is only logged) and
  // ignores `tools`. The catalog drives the example's capability chips and
  // filters and what chat_screen asks for, so a flag here offers a toggle
  // that does nothing. Gemma 4's `-web.task` entries used to claim both.
  test('no -web.task entry offers thinking or function calling', () {
    final webTask = Model.values.where(_isWebTask).toList();
    expect(
      webTask,
      containsAll([Model.gemma4_E2B_web, Model.gemma4_E4B_web]),
      reason: 'the rule must cover the Gemma 4 -web.task entries',
    );

    for (final model in webTask) {
      expect(model.supportsThinking, isFalse, reason: model.name);
      expect(model.supportsFunctionCalls, isFalse, reason: model.name);
    }
  });
}
