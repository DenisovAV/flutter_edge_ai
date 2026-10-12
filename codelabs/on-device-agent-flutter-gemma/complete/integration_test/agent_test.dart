// End-to-end check of the agent on a real device or desktop.
//
// Downloads Gemma 4 E2B (2.59 GB, ungated — no Hugging Face token), opens the
// agent with every skill this codelab adds, and asks three things the model
// cannot do on its own: the time (a native intent), a bill split (this app's
// JS skill) and a SHA-1 (a JS skill the package bundles). The claim under
// test is the codelab's: the model picks the skill, the app runs it, and the
// answer carries what the skill computed.
//
// Not part of CI (needs a device and a 2.59 GB download). Android, iOS, macOS
// or Windows — Linux has no webview for JS skills, and the test skips there:
//   flutter test integration_test/agent_test.dart -d <device-id>
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:on_device_agent/model.dart';
import 'package:on_device_agent/skills.dart';

/// Downloads the model if it is not here, and makes it the active one either
/// way. `install()` is idempotent, so a second run costs nothing.
Future<void> _install(ModelChoice model) async {
  var last = -1;
  await FlutterEdgeAi.installModel(
    modelType: model.modelType,
    fileType: ModelFileType.litertlm,
  ).fromNetwork(model.url).withProgress((p) {
    if (p >= last + 25) {
      last = p;
      debugPrint('[agent] download $p%');
    }
  }).install();
}

/// Runs one request on a fresh agent and returns every event it produced.
Future<List<AgentEvent>> _ask(InferenceModel model, String request) async {
  final agent = await openAgent(model);
  try {
    final events = await agent.ask(request).toList();
    for (final event in events) {
      debugPrint('[agent] $event');
    }
    return events;
  } finally {
    await agent.close();
  }
}

String _answer(List<AgentEvent> events) =>
    events.whereType<DoneEvent>().map((e) => e.text).join();

/// The text of every successful result [tool] returned.
///
/// A turn may also contain errors: a 2B model sometimes calls the wrong tool
/// first, reads the error — which lists what it should have called — and
/// tries again. That recovery is the agent working, so the test asks for the
/// successful call, not for a turn without a single mistake.
String _results(List<AgentEvent> events, String tool) => events
    .whereType<ToolResultEvent>()
    .where((e) => e.toolName == tool)
    .map((e) => e.result)
    .whereType<TextResult>()
    .map((r) => r.text)
    .join();

/// `JsSkillExecutor.isAvailable` is false on Linux, which has no webview: two
/// of the three requests would get an ErrorResult, and the test would fail on
/// a rule of the package rather than on the codelab.
bool get _noWebview => defaultTargetPlatform == TargetPlatform.linux;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the model picks the skill, the app runs it', (tester) async {
    await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);
    const choice = Models.gemma4;
    await _install(choice);
    // CPU, so the test runs the same on any host and does not share the GPU
    // with whatever else is running. The app itself takes the default.
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.cpu,
    );

    try {
      // A native intent: the time comes from the device, not the weights.
      final time = await _ask(model, 'What time is it right now?');
      expect(_results(time, AgentToolNames.runIntent), isNotEmpty);
      expect(_answer(time), isNotEmpty);

      // This app's JS skill: 84 + 15% = 96.60, a third of it 32.20.
      final split = await _ask(
        model,
        'Split a bill of 84 dollars between 3 people with a 15% tip.',
      );
      expect(_results(split, AgentToolNames.runSkill), contains('32.20'));
      expect(_answer(split), contains('32.2'));

      // A JS skill the package bundles. SHA-1 of "hello".
      final hash = await _ask(model, 'Calculate the hash of the text: hello');
      expect(
        _results(hash, AgentToolNames.runSkill),
        contains('aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d'),
      );
    } finally {
      await model.close();
    }
  }, skip: _noWebview);
}
