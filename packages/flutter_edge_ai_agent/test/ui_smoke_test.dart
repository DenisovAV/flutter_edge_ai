import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show InferenceChat;
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal [InferenceChat] so an [AgentSession] (and thus [AgentChatView]) can
/// be constructed without a real model — mirrors `agent_session_test.dart`.
class _FakeChat extends InferenceChat {
  _FakeChat() : super(sessionCreator: null, maxTokens: 1024);

  @override
  Future<void> initSession() async {}

  @override
  Future<void> close() async {}
}

/// A `SkillExecutor` handling one [SkillType] so the session resolves an
/// executor at construction (the loop is built eagerly).
class _FakeExecutor extends SkillExecutor {
  @override
  String get name => 'fake';

  @override
  bool canExecuteSkill(Skill skill) => true;

  @override
  Future<SkillResult> execute(Skill skill, String dataJson, {String? secret}) =>
      Future.value(const TextResult('ok'));
}

/// A 1x1 transparent PNG used to smoke-test [ImageResult] rendering.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQAY3Y2wAAAAAElFTkSuQmCC',
);

Skill _skill(
  String name, {
  SkillType type = SkillType.textOnly,
  bool requireSecret = false,
}) => Skill(
  name: name,
  description: 'desc for $name',
  instructions: 'do the thing',
  type: type,
  metadata: SkillMetadata(
    requireSecret: requireSecret,
    secretDescription: requireSecret ? 'paste your key' : null,
  ),
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('SkillResultView renders every variant without throwing', () {
    testWidgets('TextResult', (tester) async {
      await _pump(tester, const SkillResultView(result: TextResult('hi')));
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('ImageResult', (tester) async {
      await _pump(tester, SkillResultView(result: ImageResult(_png)));
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('WidgetResult renders the native widget verbatim', (
      tester,
    ) async {
      await _pump(
        tester,
        const SkillResultView(result: WidgetResult(Text('native widget'))),
      );
      expect(find.text('native widget'), findsOneWidget);
    });

    testWidgets('ErrorResult', (tester) async {
      await _pump(tester, const SkillResultView(result: ErrorResult('boom')));
      expect(find.text('boom'), findsOneWidget);
    });

    testWidgets('WebviewResult (non-iframe) shows an open card', (
      tester,
    ) async {
      await _pump(
        tester,
        const SkillResultView(
          result: WebviewResult('https://example.com', iframe: false),
        ),
      );
      expect(find.text('Open web page'), findsOneWidget);
    });
  });

  group('SkillManagerView', () {
    testWidgets('lists skills and toggles selection', (tester) async {
      final registry = SkillRegistry()
        ..add(_skill('alpha'), selected: true)
        ..add(_skill('beta'));

      await _pump(tester, SkillManagerView(registry: registry));

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);

      // Toggle 'beta' on via its switch.
      final betaSwitch = find.descendant(
        of: find.ancestor(
          of: find.text('beta'),
          matching: find.byType(ListTile),
        ),
        matching: find.byType(Switch),
      );
      await tester.tap(betaSwitch);
      await tester.pump();
      expect(registry.isSelected('beta'), isTrue);
    });

    testWidgets('empty state when no skills', (tester) async {
      await _pump(tester, SkillManagerView(registry: SkillRegistry()));
      expect(find.textContaining('No skills yet'), findsOneWidget);
    });
  });

  group('McpManagerView', () {
    testWidgets('empty state + add button', (tester) async {
      await _pump(tester, McpManagerView(servers: const [], onChanged: (_) {}));
      expect(find.text('Add server'), findsOneWidget);
      expect(find.textContaining('No MCP servers'), findsOneWidget);
    });

    testWidgets('lists a server and its tools', (tester) async {
      const server = McpServerConfig(
        url: 'https://host/mcp',
        name: 'Test Server',
        tools: [McpTool(name: 'echo', description: 'echoes input')],
      );
      await _pump(
        tester,
        McpManagerView(servers: const [server], onChanged: (_) {}),
      );
      expect(find.text('Test Server'), findsOneWidget);
    });
  });

  group('SkillTesterView', () {
    testWidgets('constructs and reports no executor', (tester) async {
      await _pump(
        tester,
        SkillTesterView(skill: _skill('alpha'), executors: const []),
      );
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);

      await tester.tap(find.text('Run'));
      await tester.pump();
      expect(find.textContaining('No registered executor'), findsOneWidget);
    });
  });

  group('dialogs construct without throwing', () {
    testWidgets('AddSkillDisclaimerDialog (skill + mcp)', (tester) async {
      await _pump(tester, AddSkillDisclaimerDialog(onConfirm: () {}));
      expect(find.text('Add skill'), findsOneWidget);

      await _pump(
        tester,
        AddSkillDisclaimerDialog(kind: DisclaimerKind.mcp, onConfirm: () {}),
      );
      expect(find.text('Add MCP server'), findsOneWidget);
    });

    testWidgets('SecretEditorDialog stores into the SecretStore', (
      tester,
    ) async {
      final store = SecretStore();
      await _pump(
        tester,
        SecretEditorDialog(
          skill: _skill('keyed', requireSecret: true),
          store: store,
        ),
      );
      expect(find.text('Secret for keyed'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'sk-123');
      await tester.tap(find.text('Done'));
      await tester.pump();
      expect(store.get('keyed'), 'sk-123');
    });

    testWidgets('McpToolCallPermissionDialog shows tool + args', (
      tester,
    ) async {
      await _pump(
        tester,
        const McpToolCallPermissionDialog(
          toolName: 'echo',
          argumentJson: '{"text":"hi"}',
          serverName: 'Test Server',
        ),
      );
      expect(find.text('echo'), findsOneWidget);
      expect(find.text('Always allow'), findsOneWidget);
      expect(find.text('Allow once'), findsOneWidget);
      expect(find.text("Don't allow"), findsOneWidget);
    });
  });

  group('SkillManagerView.showAdaptive', () {
    // A button that opens the adaptive manager, wrapped so the surrounding
    // MediaQuery width drives the branch (sheet vs side panel).
    Widget trigger(SkillRegistry registry, Size size) => MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  SkillManagerView.showAdaptive(context, registry: registry),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    testWidgets('wide window (>= 600 dp) → right-aligned side panel', (
      tester,
    ) async {
      final registry = SkillRegistry()..add(_skill('alpha'), selected: true);
      await tester.pumpWidget(trigger(registry, const Size(900, 800)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Skills'), findsOneWidget);
      expect(find.text('alpha'), findsOneWidget);
    });

    testWidgets('narrow window (< 600 dp) → modal bottom sheet', (
      tester,
    ) async {
      final registry = SkillRegistry()..add(_skill('alpha'), selected: true);
      await tester.pumpWidget(trigger(registry, const Size(400, 800)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // A bottom sheet (no side-panel Dialog); the drag handle confirms the
      // showModalBottomSheet branch.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('alpha'), findsOneWidget);
    });
  });

  group('AgentChatView', () {
    AgentSession session() => AgentSession(
      chat: _FakeChat(),
      registry: SkillRegistry()..add(_skill('alpha'), selected: true),
      executors: [_FakeExecutor()],
    );

    testWidgets('constructs over a session and shows the hint + empty state', (
      tester,
    ) async {
      final s = session();
      addTearDown(s.close);
      await _pump(
        tester,
        AgentChatView(
          session: s,
          hintText: 'ask me',
          emptyState: const Text('nothing yet'),
        ),
      );

      // Empty transcript: the custom empty state shows and the input hint is
      // present, with no exception thrown building the widget tree.
      expect(find.text('nothing yet'), findsOneWidget);
      expect(find.text('ask me'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
