import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/registry/skill_executor_registry.dart';
import 'package:flutter_edge_ai/core/registry/skill_executor_provider.dart';

class _FakeExecutor implements SkillExecutorProvider {
  _FakeExecutor(this.name, this._canExecute, {this.priority = 0});
  @override
  final String name;
  @override
  final int priority;
  final bool Function(String) _canExecute;
  @override
  bool canExecute(String skillType) => _canExecute(skillType);
}

void main() {
  setUp(() => SkillExecutorRegistry.instance.reset());

  test('findFor returns the first executor whose canExecute is true', () {
    final text = _FakeExecutor('Text', (t) => t == 'text');
    final js = _FakeExecutor('Js', (t) => t == 'js');
    SkillExecutorRegistry.instance.registerAll([text, js]);
    expect(SkillExecutorRegistry.instance.findFor('text'), same(text));
    expect(SkillExecutorRegistry.instance.findFor('js'), same(js));
  });

  test('findFor returns null when no executor can handle the type', () {
    SkillExecutorRegistry.instance.registerAll([
      _FakeExecutor('Text', (t) => t == 'text'),
    ]);
    expect(SkillExecutorRegistry.instance.findFor('mcp'), isNull);
  });

  test('higher priority wins when two executors both canExecute', () {
    final inPkg = _FakeExecutor('InPkg', (_) => true, priority: 0);
    final third = _FakeExecutor('ThirdParty', (_) => true, priority: 10);
    SkillExecutorRegistry.instance.registerAll([inPkg, third]);
    expect(SkillExecutorRegistry.instance.findFor('text'), same(third));
  });

  test('equal priority -> first registered wins', () {
    final a = _FakeExecutor('A', (_) => true);
    final b = _FakeExecutor('B', (_) => true);
    SkillExecutorRegistry.instance.registerAll([a, b]);
    expect(SkillExecutorRegistry.instance.findFor('text'), same(a));
  });

  test('registered exposes all executors in registration order', () {
    final a = _FakeExecutor('A', (_) => false);
    final b = _FakeExecutor('B', (_) => false);
    SkillExecutorRegistry.instance.registerAll([a, b]);
    expect(SkillExecutorRegistry.instance.registered.map((e) => e.name), [
      'A',
      'B',
    ]);
  });

  test('hasAny reflects registration state', () {
    expect(SkillExecutorRegistry.instance.hasAny, isFalse);
    SkillExecutorRegistry.instance.registerAll([
      _FakeExecutor('A', (_) => true),
    ]);
    expect(SkillExecutorRegistry.instance.hasAny, isTrue);
  });

  test('duplicate registration is ignored (identity-based)', () {
    final a = _FakeExecutor('A', (_) => true);
    SkillExecutorRegistry.instance.registerAll([a]);
    SkillExecutorRegistry.instance.registerAll([a]);
    expect(SkillExecutorRegistry.instance.registered.length, 1);
  });
}
