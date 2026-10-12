// End-to-end check of the agent on a real device or desktop.
//
// Downloads Gemma 4 E2B (2.59 GB, ungated — no Hugging Face token), opens one
// agent with every skill this codelab adds — one conversation, as the app
// holds — and asks three things the model cannot do on its own: the time (a
// native intent), a bill split (this app's JS skill) and a SHA-1 (a JS skill
// the package bundles). The claim under test is the codelab's: the model
// picks the skill, the app runs it, and the answer carries what the skill
// computed. Sampling is the model's own, so a 2B model can fail a run.
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

/// Runs one request and returns every event it produced. The turn must end
/// with an answer, not at the iteration limit.
Future<List<AgentEvent>> _ask(AgentSession agent, String request) async {
  final events = await agent.ask(request).toList();
  for (final event in events) {
    debugPrint('[agent] $event');
  }
  expect(events.last, isA<DoneEvent>(), reason: request);
  return events;
}

String _answer(List<AgentEvent> events) =>
    events.whereType<DoneEvent>().map((e) => e.text).join();

/// The text of each successful result [tool] returned.
///
/// A turn may also contain errors: a 2B model sometimes calls the wrong tool
/// first, reads the error — which lists what it should have called — and
/// tries again. That recovery is the agent working, so the test asks for the
/// successful call, not for a turn without a single mistake.
List<String> _results(List<AgentEvent> events, String tool) => [
  for (final event in events.whereType<ToolResultEvent>())
    if (event.toolName == tool)
      if (event.result case TextResult(:final text)) text,
];

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

    final agent = await openAgent(model, modelType: choice.modelType);
    try {
      // A native intent: the time comes from the device, not the weights —
      // "2026-10-12T13:05:42 Monday". The answer has to carry it: its minutes
      // or its weekday.
      final time = await _ask(agent, 'What time is it right now?');
      final clock = _results(time, AgentToolNames.runIntent)
          .map(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:(\d\d):\d\d (\w+)$').firstMatch)
          .nonNulls
          .firstOrNull;
      expect(clock, isNotNull, reason: 'no date-time result');
      expect(
        _answer(time),
        anyOf(contains(clock!.group(1)), contains(clock.group(2))),
      );

      // This app's JS skill: 84 + 15% = 96.60, a third of it 32.20.
      final split = await _ask(
        agent,
        'Split a bill of 84 dollars between 3 people with a 15% tip.',
      );
      expect(
        _results(split, AgentToolNames.runSkill),
        contains(contains('Each of 3 pays 32.20')),
      );
      expect(_answer(split), matches(RegExp(r'\b32\.20?\b')));

      // A JS skill the package bundles. SHA-1 of "hello".
      const sha1 = 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d';
      final hash = await _ask(agent, 'Calculate the hash of the text: hello');
      expect(_results(hash, AgentToolNames.runSkill), contains(contains(sha1)));
      expect(_answer(hash), contains(sha1.substring(0, 8)));
    } finally {
      await agent.close();
      await model.close();
    }
  }, skip: _noWebview);
}
