// The agent's widgets are built on package:flutter/material.dart. An app built
// on package:material_ui hosts them through MaterialUiCompatibilityBridge in
// MaterialApp.builder; these tests pump them in such an app.
// ignore_for_file: deprecated_member_use

import 'dart:async';

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

  testWidgets('SkillTesterView builds inline', (tester) async {
    await _pumpInMaterialUiApp(
      tester,
      SkillTesterView(skill: _skill('alpha'), executors: [_FakeExecutor()]),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(legacy.TextField), findsOneWidget);
  });

  group('in a package:flutter/material.dart app', () {
    testWidgets('a failed add inline shows a snack bar', (tester) async {
      await tester.pumpWidget(
        legacy.MaterialApp(
          home: legacy.Scaffold(
            body: SkillManagerView(
              registry: SkillRegistry(),
              onImport: () async => throw StateError('no file'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand'));
      await tester.pumpAndSettle();

      expect(find.byType(legacy.SnackBar), findsOneWidget);
      expect(find.byType(legacy.AlertDialog), findsNothing);
    });

    testWidgets('a failed add in the bottom sheet shows a dialog above it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        legacy.MaterialApp(
          home: legacy.Scaffold(
            body: Builder(
              builder: (context) => legacy.TextButton(
                onPressed: () => SkillManagerView.showAdaptive(
                  context,
                  registry: SkillRegistry(),
                  onImport: () async => throw StateError('no file'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I understand'));
      await tester.pumpAndSettle();

      expect(find.byType(legacy.AlertDialog), findsOneWidget);
      expect(find.textContaining('Could not add skill'), findsOneWidget);
    });
  });

  testWidgets('McpManagerView reports a server added after it closed', (
    tester,
  ) async {
    final reported = <List<McpServerConfig>>[];
    final show = ValueNotifier(true);
    final gate = Completer<void>();
    await _pumpInMaterialUiApp(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: show,
        builder: (context, visible, _) => visible
            ? McpManagerView(
                servers: const [],
                onChanged: reported.add,
                clientFactory: (config) => _GatedClient(config, gate.future),
              )
            : const SizedBox(),
      ),
    );

    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(legacy.TextField, 'Server URL'),
      'https://host.invalid/mcp',
    );
    await tester.tap(find.text('Add'));
    await tester.pump();

    show.value = false; // the view closes while the server connects
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(reported, hasLength(1));
    expect(reported.single.single.url, 'https://host.invalid/mcp');
  });
}

/// A client whose connect fails once [gate] completes.
class _GatedClient extends McpClient {
  _GatedClient(McpServerConfig config, this.gate) : super(config: config);

  final Future<void> gate;

  @override
  Future<McpServerConfig> connect() async {
    await gate;
    throw McpException('offline');
  }
}
