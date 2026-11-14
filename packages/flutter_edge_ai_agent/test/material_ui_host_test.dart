// The agent's widgets are built on package:flutter/material.dart. An app built
// on package:material_ui hosts them through MaterialUiCompatibilityBridge in
// MaterialApp.builder; these tests pump them in such an app.
// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart' as legacy;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show InferenceChat;
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _FakeChat extends InferenceChat {
  _FakeChat() : super(sessionCreator: null, maxTokens: 1024);

  @override
  Future<void> initSession() async {}

  @override
  Future<void> close() async {}
}

class _FakeExecutor extends SkillExecutor {
  @override
  String get name => 'fake';

  @override
  bool canExecuteSkill(Skill skill) => true;

  @override
  Future<SkillResult> execute(Skill skill, String dataJson, {String? secret}) =>
      Future.value(const TextResult('ok'));
}

Skill _skill(String name) => Skill(
  name: name,
  description: 'desc for $name',
  instructions: 'do the thing',
  type: SkillType.textOnly,
  metadata: const SkillMetadata(),
);

Future<void> _pumpInMaterialUiApp(WidgetTester tester, Widget body) =>
    tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            MaterialUiCompatibilityBridge(child: child!),
        home: Scaffold(body: body),
      ),
    );

void main() {
  testWidgets('AgentChatView builds without a legacy Material ancestor', (
    tester,
  ) async {
    final session = AgentSession(
      chat: _FakeChat(),
      registry: SkillRegistry()..add(_skill('alpha'), selected: true),
      executors: [_FakeExecutor()],
    );
    addTearDown(session.close);

    await _pumpInMaterialUiApp(
      tester,
      AgentChatView(session: session, hintText: 'ask me'),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(legacy.TextField), findsOneWidget);
    await tester.enterText(find.byType(legacy.TextField), 'hello');
    expect(tester.takeException(), isNull);
  });

  testWidgets('SkillManagerView builds inline and reports a failed add in a '
      'dialog', (tester) async {
    final registry = SkillRegistry()..add(_skill('alpha'), selected: true);

    await _pumpInMaterialUiApp(
      tester,
      SkillManagerView(
        registry: registry,
        onImport: () async => throw StateError('no file'),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('alpha'), findsOneWidget);

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    // The disclaimer comes first; agree to it.
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(legacy.AlertDialog), findsOneWidget);
    expect(find.textContaining('Could not add skill'), findsOneWidget);
  });

  testWidgets('McpManagerView reports a failed connect in a dialog', (
    tester,
  ) async {
    await _pumpInMaterialUiApp(
      tester,
      McpManagerView(servers: const [], onChanged: (_) {}),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(legacy.TextField, 'Server URL'),
      'https://host.invalid/mcp',
    );
    await tester.tap(find.text('Add'));
    // flutter_test answers every HTTP request with 400, so connect fails.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(legacy.AlertDialog), findsOneWidget);
    expect(find.textContaining('could not connect'), findsOneWidget);
  });
}
