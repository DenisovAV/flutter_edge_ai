import 'package:flutter_edge_ai/engine.dart'
    show
        InferenceChat,
        InferenceModel,
        SkillExecutorProvider,
        SkillExecutorRegistry;
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal [InferenceChat] so an [AgentSession] can be constructed without a
/// real model. Construction is all we need: the constructor builds the
/// [AgentLoop] eagerly, which is where executor resolution happens.
class _FakeChat extends InferenceChat {
  _FakeChat() : super(sessionCreator: null, maxTokens: 1024);

  @override
  Future<void> initSession() async {}

  @override
  Future<void> close() async {}
}

/// A `SkillExecutor` (so it can drive the loop) handling one [SkillType].
class _FakeExecutor extends SkillExecutor {
  _FakeExecutor(this._type, {this.name = 'fake'});

  final SkillType _type;

  @override
  final String name;

  @override
  bool canExecuteSkill(Skill skill) => skill.type == _type;

  @override
  Future<SkillResult> execute(Skill skill, String dataJson, {String? secret}) =>
      Future.value(const TextResult('ok'));
}

/// A bare [SkillExecutorProvider] that is NOT a [SkillExecutor] — simulates a
/// third party implementing only core's contract. The agent loop can't run it.
class _BareProvider implements SkillExecutorProvider {
  @override
  String get name => 'bare';

  @override
  int get priority => 0;

  @override
  bool canExecute(String skillType) => true;
}

/// An [InferenceModel] with nothing behind it: creating a chat on it fails
/// with a [NoSuchMethodError], so a test can tell whether a call got that far.
class _NoModel extends InferenceModel {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('AgentSession executor resolution', () {
    setUp(SkillExecutorRegistry.instance.reset);
    tearDown(SkillExecutorRegistry.instance.reset);

    test('explicit executors construct even with an empty registry', () {
      // The registry is empty; passing executors explicitly must still work
      // (the explicit path never consults the registry).
      expect(
        () => AgentSession(
          chat: _FakeChat(),
          registry: SkillRegistry(),
          executors: [_FakeExecutor(SkillType.textOnly, name: 'explicit')],
        ),
        returnsNormally,
      );
    });

    test('null executors fall back to the core registry', () {
      SkillExecutorRegistry.instance.registerAll([
        _FakeExecutor(SkillType.intent, name: 'registered'),
      ]);

      // No throw means resolution found the registered executor.
      expect(
        () => AgentSession(chat: _FakeChat(), registry: SkillRegistry()),
        returnsNormally,
      );
    });

    test('null executors + empty registry throws a clear StateError', () {
      expect(
        () => AgentSession(chat: _FakeChat(), registry: SkillRegistry()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('No skill executors'), contains('skillExecutors:')),
          ),
        ),
      );
    });

    test('a registered bare provider (not a SkillExecutor) is rejected', () {
      SkillExecutorRegistry.instance.registerAll([_BareProvider()]);

      expect(
        () => AgentSession(chat: _FakeChat(), registry: SkillRegistry()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('bare'), contains('does not')),
          ),
        ),
      );
    });
  });

  group('AgentSession.fromModel', () {
    test('a negative retry count is refused before a chat is created', () {
      expect(
        AgentSession.fromModel(
          _NoModel(),
          registry: SkillRegistry(),
          executors: [_FakeExecutor(SkillType.textOnly)],
          emptyAfterSkillRetries: -1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('AgentSession.buildSystemPrompt', () {
    final registry = SkillRegistry()
      ..add(
        const Skill(
          name: 'packing-list',
          description: 'Suggest what to pack for a trip.',
          instructions: 'List what to pack.',
          type: SkillType.textOnly,
        ),
        selected: true,
      );

    test('the on-demand prompt takes the skill list like the default', () {
      final prompt = AgentSession.buildSystemPrompt(
        registry,
        systemPromptTemplate: onDemandAgentSystemPrompt,
      );

      expect(prompt, contains('- packing-list: Suggest what to pack'));
      expect(prompt, isNot(contains('__SKILLS__')));
      expect(prompt, contains('Only when a request needs one of these skills'));
      expect(prompt, contains('call loadSkill'));
      expect(prompt, contains('no tool call'));
    });

    test('the default prompt is still the one used without a template', () {
      final prompt = AgentSession.buildSystemPrompt(registry);

      expect(prompt, contains('For EVERY new task or request or question'));
      expect(prompt, contains('- packing-list: Suggest what to pack'));
      expect(prompt, isNot(contains('Only when a request needs')));
    });
  });
}
