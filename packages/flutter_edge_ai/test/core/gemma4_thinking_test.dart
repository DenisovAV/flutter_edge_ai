import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/extensions.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_response.dart';

void main() {
  group('Gemma 4 thinking - filterThinkingStream', () {
    Stream<ModelResponse> makeStream(List<String> chunks) {
      return Stream.fromIterable(chunks.map((c) => TextResponse(c)));
    }

    test(
      'complete block in single chunk yields ThinkingResponse + TextResponse',
      () async {
        final stream = makeStream([
          '<|channel>thought\nI need to think about this.<channel|>The answer is 42.',
        ]);

        final results = await ModelThinkingFilter.filterThinkingStream(
          stream,
          modelType: ModelType.gemmaIt,
        ).toList();

        expect(results, [
          const ThinkingResponse('I need to think about this.'),
          const TextResponse('The answer is 42.'),
        ]);
      },
    );

    test('thinking split across multiple chunks buffers correctly', () async {
      final stream = makeStream([
        '<|channel>thought\nI am ',
        'thinking hard',
        '<channel|>Final answer.',
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.gemmaIt,
      ).toList();

      // Intermediate thinking chunks are yielded as they arrive
      final thinkingParts = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      final textParts = results
          .whereType<TextResponse>()
          .map((r) => r.token)
          .join();

      expect(thinkingParts, 'I am thinking hard');
      expect(textParts, 'Final answer.');
    });

    test('no thinking block passes through as TextResponse', () async {
      final stream = makeStream(['Hello, ', 'world!']);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.gemmaIt,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();
      expect(text, 'Hello, world!');
      expect(results.whereType<ThinkingResponse>(), isEmpty);
    });

    test('multiple thinking blocks in one response', () async {
      final stream = makeStream([
        '<|channel>thought\nFirst thought.<channel|>Text between.<|channel>thought\nSecond thought.<channel|>Final text.',
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.gemmaIt,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .toList();
      final text = results
          .whereType<TextResponse>()
          .map((r) => r.token)
          .toList();

      expect(thinking, ['First thought.', 'Second thought.']);
      expect(text, ['Text between.', 'Final text.']);
    });

    test('partial start marker at stream end is flushed as text', () async {
      final stream = makeStream(['Some text<|chan']);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.gemmaIt,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();
      expect(text, 'Some text<|chan');
    });

    test('partial end marker at stream end is flushed as thinking', () async {
      final stream = makeStream(['<|channel>thought\nThinking content<chan']);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.gemmaIt,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      expect(thinking, 'Thinking content<chan');
    });

    test('empty thinking block yields only TextResponse', () async {
      final stream = makeStream(['<|channel>thought\n<channel|>The answer.']);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.gemmaIt,
      ).toList();

      expect(results.whereType<ThinkingResponse>(), isEmpty);
      expect(
        results.whereType<TextResponse>().map((r) => r.token).join(),
        'The answer.',
      );
    });

    test('start marker split across chunks', () async {
      final stream = makeStream([
        'Hello <|channel>',
        'thought\nThinking.<channel|>Done.',
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.gemmaIt,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(thinking, 'Thinking.');
      expect(text, 'Hello Done.');
    });
  });

  group('Gemma 4 thinking - removeThinkingFromText', () {
    test('strips thinking blocks from text', () {
      const input =
          'Prefix <|channel>thought\nSome reasoning.<channel|> Suffix';
      final result = ModelThinkingFilter.removeThinkingFromText(
        input,
        modelType: ModelType.gemmaIt,
      );
      expect(result, 'Prefix  Suffix');
    });

    test('strips multiple thinking blocks', () {
      const input =
          '<|channel>thought\nA<channel|>Text<|channel>thought\nB<channel|>End';
      final result = ModelThinkingFilter.removeThinkingFromText(
        input,
        modelType: ModelType.gemmaIt,
      );
      expect(result, 'TextEnd');
    });

    test('no thinking blocks returns text unchanged', () {
      const input = 'Just regular text';
      final result = ModelThinkingFilter.removeThinkingFromText(
        input,
        modelType: ModelType.gemmaIt,
      );
      expect(result, 'Just regular text');
    });

    test('multiline thinking content is stripped', () {
      const input =
          '<|channel>thought\nLine 1\nLine 2\nLine 3<channel|>Answer.';
      final result = ModelThinkingFilter.removeThinkingFromText(
        input,
        modelType: ModelType.gemmaIt,
      );
      expect(result, 'Answer.');
    });
  });

  group('DeepSeek thinking', () {
    test('basic DeepSeek format', () async {
      final stream = Stream.fromIterable([
        const TextResponse('I think '),
        const TextResponse('about this</think>'),
        const TextResponse('The answer.'),
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.deepSeek,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(thinking.contains('I think '), isTrue);
      expect(text, 'The answer.');
    });

    test('partial </think> split across tokens', () async {
      final stream = Stream.fromIterable([
        const TextResponse('thinking</th'),
        const TextResponse('ink>answer'),
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.deepSeek,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(thinking, 'thinking');
      expect(text, 'answer');
    });
  });

  group('Qwen thinking', () {
    test('Qwen3 with <think> tags', () async {
      final stream = Stream.fromIterable([
        const TextResponse('<think>reasoning</think>answer'),
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.qwen3,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(thinking, 'reasoning');
      expect(text, 'answer');
    });

    test('Qwen3 tags split across multiple tokens', () async {
      final stream = Stream.fromIterable([
        const TextResponse('<think>I am '),
        const TextResponse('thinking</think>'),
        const TextResponse('The answer.'),
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.qwen3,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(thinking, 'I am thinking');
      expect(text, 'The answer.');
    });

    test('partial <think> split across tokens', () async {
      final stream = Stream.fromIterable([
        const TextResponse('<thi'),
        const TextResponse('nk>reasoning</think>answer'),
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.qwen3,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(thinking, 'reasoning');
      expect(text, 'answer');
    });

    test('partial </think> split across tokens', () async {
      final stream = Stream.fromIterable([
        const TextResponse('<think>thinking</th'),
        const TextResponse('ink>answer'),
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.qwen3,
      ).toList();

      final thinking = results
          .whereType<ThinkingResponse>()
          .map((r) => r.content)
          .join();
      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(thinking, 'thinking');
      expect(text, 'answer');
    });

    test('Qwen2.5 no thinking tags — passthrough', () async {
      final stream = Stream.fromIterable([
        const TextResponse('Hello, '),
        const TextResponse('world!'),
      ]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.qwen3,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();
      expect(text, 'Hello, world!');
      expect(results.whereType<ThinkingResponse>(), isEmpty);
    });

    test('partial <think> at end of stream flushed as text', () async {
      final stream = Stream.fromIterable([const TextResponse('Some text<thi')]);

      final results = await ModelThinkingFilter.filterThinkingStream(
        stream,
        modelType: ModelType.qwen3,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();
      expect(text, 'Some text<thi');
    });
  });
}
