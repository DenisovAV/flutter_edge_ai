// The web model and session (lib/src/adapter/web_inference_model.dart) on the
// VM, over a fake engine and conversation handle: what reaches litertlm_dart
// for core's sampling (an unset sampler is the model's default, never the
// caller's choice, so LiteRT-LM#2080's warning stays quiet), tools only for
// models whose tool calling the runtime runs, the turn's message, the
// generation lock across sessions, and how a stop and a consumer that leaves
// reach the conversation.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/web_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal.dart'
    show
        ConversationHandle,
        NativeBenchmark,
        NativeLastTurnEnd,
        SendOptions,
        StoppedTurnRewind,
        conversationForTest;
import 'package:litertlm_dart/internal.dart' as rt show BenchmarkInfo;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

final class _Handle implements ConversationHandle {
  final sent = <String>[];
  int cancels = 0;
  StreamController<String>? reply;

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) {
    sent.add(messageJson);
    return (reply = StreamController<String>()).stream;
  }

  @override
  void cancelGeneration() => cancels++;

  int closes = 0;

  /// Holds [close] open until completed; null closes at once.
  Completer<void>? closeGate;

  @override
  Future<void> close() async {
    closes++;
    await closeGate?.future;
  }

  @override
  Future<int?> tokenCount(String text) async => null;

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => throw UnimplementedError();

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => throw UnimplementedError();

  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(Map<String, Object?>? r) =>
      throw UnimplementedError();

  @override
  rt.BenchmarkInfo getSessionMetrics() => const rt.BenchmarkInfo();

  @override
  NativeBenchmark? getNativeBenchmark() => null;

  @override
  NativeLastTurnEnd? get lastTurnEnd => null;

  @override
  int? get lastTurnCode => null;
}

final class _Engine implements WebLlmEngine {
  final configs = <lm.ConversationConfig>[];
  final defaults = <lm.SamplerConfig?>[];
  final handles = <_Handle>[];

  @override
  Future<lm.Conversation> openConversation(
    lm.ConversationConfig config,
    lm.SamplerConfig? defaultSamplerConfig,
  ) async {
    configs.add(config);
    defaults.add(defaultSamplerConfig);
    final handle = _Handle();
    handles.add(handle);
    return conversationForTest(handle, config: config);
  }

  int closes = 0;

  @override
  Future<void> close() async => closes++;
}

LiteRtLmWebInferenceModel _model(_Engine engine, ModelType type) =>
    LiteRtLmWebInferenceModel(
      createEngine: () async => engine,
      maxTokens: 1024,
      modelType: type,
      onClose: () {},
    );

final _tool = const Tool(
  name: 'get_weather',
  description: 'The weather',
  parameters: {'type': 'object'},
);

void main() {
  test('an unset sampler goes as the model default, never as the caller\'s '
      'choice; a set one as the caller\'s', () async {
    final engine = _Engine();
    final model = _model(engine, ModelType.gemma4);
    await model.openSession();
    expect(engine.configs.single.samplerConfig, isNull);
    final resolved = SamplingParams.resolve(
      const SamplingParams(),
      modelType: ModelType.gemma4,
    );
    expect(engine.defaults.single, isNotNull);
    expect(engine.defaults.single!.topK, resolved.topK);
    expect(engine.defaults.single!.topP, resolved.topP);
    expect(engine.defaults.single!.temperature, resolved.temperature);

    await model.openSession(temperature: 0.3);
    expect(engine.configs.last.samplerConfig?.temperature, 0.3);
    expect(engine.defaults.last, isNull);
    await model.close();
  });

  test('tools reach the runtime only for a model whose tool calling it runs; '
      'thinking and the reply cap go with the conversation', () async {
    final engine = _Engine();
    final gemma4 = _model(engine, ModelType.gemma4);
    await gemma4.openSession(
      tools: [_tool],
      enableThinking: true,
      maxOutputTokens: 64,
      systemInstruction: 'Be brief.',
    );
    final config = engine.configs.single;
    expect(config.tools.single.name, 'get_weather');
    expect(config.thinkingConfig?.enableThinking, isTrue);
    expect(config.maxOutputTokens, 64);
    expect(config.systemInstruction, 'Be brief.');
    await gemma4.close();

    final other = _Engine();
    final gemmaIt = _model(other, ModelType.gemmaIt);
    await gemmaIt.openSession(tools: [_tool]);
    expect(other.configs.single.tools, isEmpty);
    await gemmaIt.close();
  });

  test('automatic tool calling is off: a tool call reaches the session as '
      'the runtime wrote it, and nothing is sent for it', () async {
    final engine = _Engine();
    final model = _model(engine, ModelType.gemma4);
    final session =
        await model.openSession(tools: [_tool]) as LiteRtLmWebSession;
    expect(engine.configs.single.automaticToolCalling, isFalse);
    final handle = engine.handles.single;
    await session.addQueryChunk(const Message(text: 'Paris?', isUser: true));
    final reply = session.getResponseAsync().toList();
    await pumpEventQueue();
    const call =
        '{"role":"assistant","tool_calls":[{"type":"function",'
        '"function":{"name":"get_weather","arguments":{"city":"Paris"}}}]}';
    handle.reply!.add(call);
    unawaited(handle.reply!.close());
    await reply;
    expect(handle.sent, hasLength(1));
    expect(session.lastRawResponse, call);
    await model.close();
  });

  test('a stop asks the conversation to stop; a consumer that leaves does '
      'too, and frees the generation lock for the next turn', () async {
    final engine = _Engine();
    final model = _model(engine, ModelType.gemmaIt);
    final session = await model.openSession();
    final handle = engine.handles.single;

    await session.addQueryChunk(const Message(text: 'Hi', isUser: true));
    final sub = session.getResponseAsync().listen((_) {});
    await pumpEventQueue();
    expect(jsonDecode(handle.sent.single), {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Hi'},
      ],
    });
    unawaited(sub.cancel());
    await pumpEventQueue();
    expect(handle.cancels, 1, reason: 'the runtime was not asked to stop');
    unawaited(handle.reply!.close());
    await pumpEventQueue();

    await session.addQueryChunk(const Message(text: 'Again', isUser: true));
    final next = session.getResponseAsync().toList();
    await pumpEventQueue();
    expect(handle.sent, hasLength(2), reason: 'the generation lock was kept');
    await session.stopGeneration();
    expect(handle.cancels, 2);
    unawaited(handle.reply!.close());
    await next;
    await model.close();
  });

  group('a model closed while its engine loads', () {
    late _Engine engine;
    late Completer<WebLlmEngine> loading;
    late LiteRtLmWebInferenceModel model;
    setUp(() {
      engine = _Engine();
      loading = Completer<WebLlmEngine>();
      model = LiteRtLmWebInferenceModel(
        createEngine: () => loading.future,
        maxTokens: 1024,
        modelType: ModelType.gemmaIt,
        onClose: () {},
      );
    });

    test('closes the engine once it has loaded', () async {
      final session = model.openSession().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await pumpEventQueue();
      final closing = model.close();

      loading.complete(engine);
      await closing;

      expect(engine.closes, 1);
      expect(
        await session,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Model was closed while'),
        ),
      );
    });

    test('createSession refuses the session it built', () async {
      final session = model.createSession().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await pumpEventQueue();
      final closing = model.close();

      loading.complete(engine);
      await closing;

      expect(
        await session,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Model was closed while'),
        ),
      );
      expect(engine.handles.single.closes, 1);
    });
  });

  test('a session closed twice: the second close completes when the first '
      'has, and the conversation is closed once', () async {
    final engine = _Engine();
    final model = _model(engine, ModelType.gemmaIt);
    final session = await model.openSession();
    final handle = engine.handles.single..closeGate = Completer<void>();

    final first = session.close();
    var secondDone = false;
    final second = session.close().then((_) => secondDone = true);
    await pumpEventQueue();

    expect(secondDone, isFalse, reason: 'returned before the first close');
    handle.closeGate!.complete();
    await first;
    await second;
    expect(handle.closes, 1);
    await model.close();
  });

  test(
    'a legacy createSession that waits for the previous session\'s close '
    'while the model closes fails with the closed-model StateError',
    () async {
      final engine = _Engine();
      final model = _model(engine, ModelType.gemmaIt);
      // ignore: deprecated_member_use
      await model.createSession();
      final handle = engine.handles.single..closeGate = Completer<void>();

      // ignore: deprecated_member_use
      final second = model.createSession().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await pumpEventQueue();
      final closing = model.close();
      await pumpEventQueue();
      handle.closeGate!.complete();
      await closing;

      expect(
        await second,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Model was closed while'),
        ),
      );
      expect(
        engine.handles,
        hasLength(1),
        reason: 'no conversation after close',
      );
    },
  );

  test('an engine that fails to load reaches core with the line in core\'s '
      'terms, as natively', () async {
    final model = LiteRtLmWebInferenceModel(
      createEngine: () async => throw const lm.LiteRtLmEngineCreateException(
        'Load it on the CPU (Backend.cpu()).',
      ),
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      onClose: () {},
    );

    await expectLater(
      model.openSession(),
      throwsA(
        isA<lm.LiteRtLmEngineCreateException>().having(
          (e) => e.message,
          'message',
          contains(
            'In flutter_edge_ai: preferredBackend: PreferredBackend.cpu',
          ),
        ),
      ),
    );
    await model.close();
  });
}
