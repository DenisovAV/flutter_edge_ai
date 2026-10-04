import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/embedding/tokenizer_adapter.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show EmbeddingModelSpec;
import 'package:flutter_edge_ai/core/registry/embedding_tokenizer_provider.dart';
import 'package:flutter_edge_ai/core/registry/embedding_tokenizer_registry.dart';

Future<EmbeddingTokenizer> _factoryA(String path) =>
    throw UnimplementedError('A');
Future<EmbeddingTokenizer> _factoryB(String path) =>
    throw UnimplementedError('B');

class _FakeTokenizers implements EmbeddingTokenizerProvider {
  _FakeTokenizers(
    this.name,
    this._canHandle, {
    this.priority = 0,
    this.factory = _factoryA,
  });

  @override
  final String name;
  @override
  final int priority;
  @override
  final EmbeddingTokenizerFactory factory;

  final bool Function(EmbeddingModelSpec) _canHandle;

  @override
  bool canHandle(EmbeddingModelSpec spec) => _canHandle(spec);
}

EmbeddingModelSpec _spec(String name) => EmbeddingModelSpec(
  name: name,
  modelSource: AssetSource('models/$name.tflite'),
  tokenizerSource: AssetSource('models/$name.json'),
);

void main() {
  final registry = EmbeddingTokenizerRegistry.instance;
  tearDown(registry.reset);

  test(
    'an empty registry names the package to add rather than returning null',
    () {
      // The whole point of the provider indirection: a backend that silently
      // fell back to one tokenizer family would return vectors that are quietly
      // the wrong point in the embedding space, which nothing downstream can
      // distinguish from a working model.
      expect(
        () => registry.resolveFor(_spec('gemma')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('flutter_edge_ai_embeddings'),
              contains('embeddingTokenizers'),
              contains('gemma'),
            ),
          ),
        ),
      );
    },
  );

  test('a provider that declines is not selected', () {
    registry.registerAll([_FakeTokenizers('no', (_) => false)]);
    expect(registry.findFor(_spec('gemma')), isNull);
    expect(() => registry.resolveFor(_spec('gemma')), throwsStateError);
  });

  test('higher priority wins regardless of registration order', () {
    final low = _FakeTokenizers('low', (_) => true);
    final high = _FakeTokenizers('high', (_) => true, priority: 10);
    registry.registerAll([low, high]);
    expect(registry.findFor(_spec('gemma'))!.name, 'high');
  });

  test('on equal priority the first registered wins', () {
    final first = _FakeTokenizers('first', (_) => true);
    final second = _FakeTokenizers('second', (_) => true);
    registry.registerAll([first, second]);
    expect(registry.findFor(_spec('gemma'))!.name, 'first');
  });

  test(
    'resolveFor returns the selected provider\'s factory, not any factory',
    () {
      registry.registerAll([
        _FakeTokenizers('low', (_) => true, factory: _factoryA),
        _FakeTokenizers('high', (_) => true, priority: 10, factory: _factoryB),
      ]);
      // Identity, not just "some function": the factory is a top-level tear-off
      // precisely so it survives being sent to the worker isolate, and picking
      // the wrong provider's would tokenize with the wrong convention.
      expect(registry.resolveFor(_spec('gemma')), same(_factoryB));
    },
  );

  test('selection is per spec', () {
    registry.registerAll([
      _FakeTokenizers('gemma-only', (s) => s.name == 'gemma', priority: 10),
      _FakeTokenizers('catch-all', (_) => true),
    ]);
    expect(registry.findFor(_spec('gemma'))!.name, 'gemma-only');
    expect(registry.findFor(_spec('minilm'))!.name, 'catch-all');
  });

  test('registering the same provider twice does not duplicate it', () {
    final p = _FakeTokenizers('one', (_) => true);
    registry.registerAll([p]);
    registry.registerAll([p]);
    expect(registry.registered, hasLength(1));
  });

  test('reset empties the registry', () {
    registry.registerAll([_FakeTokenizers('one', (_) => true)]);
    expect(registry.hasAny, isTrue);
    registry.reset();
    expect(registry.hasAny, isFalse);
  });
}
