// Calls the protected engine SPI to verify the package's qualification table.
// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/structured_output_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the generated C API 1.0 bindings pass both constraint setters', () {
    final providers = <int>[];
    var constraintType = -1;
    final constraints = <String>[];
    final keep = <NativeCallable>[];
    Pointer<Void> retain(NativeCallable callable) {
      keep.add(callable);
      return callable.nativeFunction.cast();
    }

    final symbols = <String, Pointer<Void>>{
      'litert_lm_get_last_error_message': retain(
        NativeCallable<Pointer<Char> Function()>.isolateLocal(() => nullptr),
      ),
      'litert_lm_conversation_config_set_constraint_provider': retain(
        NativeCallable<
          UnsignedInt Function(Pointer<LiteRtLmConversationConfig>, UnsignedInt)
        >.isolateLocal((Pointer<LiteRtLmConversationConfig> _, int value) {
          providers.add(value);
          return 0;
        }, exceptionalReturn: 1),
      ),
      'litert_lm_conversation_optional_args_set_constraint': retain(
        NativeCallable<
          UnsignedInt Function(
            Pointer<LiteRtLmConversationOptionalArgs>,
            UnsignedInt,
            Pointer<Char>,
          )
        >.isolateLocal((
          Pointer<LiteRtLmConversationOptionalArgs> _,
          int type,
          Pointer<Char> text,
        ) {
          constraintType = type;
          constraints.add(text.cast<Utf8>().toDartString());
          return 0;
        }, exceptionalReturn: 1),
      ),
    };
    addTearDown(() {
      for (final callable in keep) {
        callable.close();
      }
    });
    final bindings = LiteRtLmBindings.fromLookup(
      <T extends NativeType>(String name) => symbols[name]!.cast<T>(),
    );
    final schema = '{"type":"string"}'.toNativeUtf8();
    addTearDown(() => calloc.free(schema));

    expect(
      bindings.litert_lm_conversation_config_set_constraint_provider(
        Pointer.fromAddress(0x10),
        LiteRtLmConstraintProviderType
            .kLiteRtLmConstraintProviderTypeLlGuidance,
      ),
      0,
    );
    expect(
      bindings.litert_lm_conversation_optional_args_set_constraint(
        Pointer.fromAddress(0x20),
        LiteRtLmConstraintType.kLiteRtLmConstraintTypeJsonSchema,
        schema.cast(),
      ),
      0,
    );
    final client = LiteRtLmFfiClient()..bindingsForTest = bindings;
    client
      ..constraintProviderForTest(Pointer.fromAddress(0x30), null)
      ..constraintProviderForTest(
        Pointer.fromAddress(0x40),
        '{"type":"string"}',
      )
      ..constraintForTest(Pointer.fromAddress(0x50), null)
      ..constraintForTest(Pointer.fromAddress(0x60), '{"type":"string"}');
    expect(providers, [1, 1], reason: 'plain conversation gets no provider');
    expect(constraintType, 2);
    expect(constraints, ['{"type":"string"}', '{"type":"string"}']);
  });

  test('only the device-run table advertises the whole dialect', () {
    const expected = <LiteRtLmStructuredOutputRow>{
      (
        abi: 'macos_arm64',
        backend: PreferredBackend.cpu,
        androidGpu: null,
        npuVendor: null,
      ),
      (
        abi: 'macos_arm64',
        backend: PreferredBackend.gpu,
        androidGpu: null,
        npuVendor: null,
      ),
      (
        abi: 'linux_x64',
        backend: PreferredBackend.cpu,
        androidGpu: null,
        npuVendor: null,
      ),
      (
        abi: 'linux_x64',
        backend: PreferredBackend.gpu,
        androidGpu: null,
        npuVendor: null,
      ),
      (
        abi: 'windows_x64',
        backend: PreferredBackend.cpu,
        androidGpu: null,
        npuVendor: null,
      ),
      (
        abi: 'windows_x64',
        backend: PreferredBackend.gpu,
        androidGpu: null,
        npuVendor: null,
      ),
    };
    expect(liteRtLmStructuredOutputRows, expected);
    for (final row in liteRtLmStructuredOutputCandidateRows) {
      final support = liteRtLmStructuredOutputSupport(
        abi: row.abi,
        backend: row.backend,
        androidGpu: row.androidGpu,
        npuVendor: row.npuVendor,
      );
      if (expected.contains(row)) {
        expect(support.isSupported, isTrue, reason: '$row');
        expect(support.keywords, ResponseFormat.dialect, reason: '$row');
      } else {
        expect(support.isSupported, isFalse, reason: '$row');
        expect(support.reason, contains('discriminating device run'));
      }
    }
  });

  test('an unknown Android GPU family and an unknown backend stay refused', () {
    expect(
      liteRtLmStructuredOutputSupport(
        abi: 'android_arm64',
        backend: PreferredBackend.gpu,
      ).isSupported,
      isFalse,
    );
    expect(
      liteRtLmStructuredOutputSupport(
        abi: 'macos_arm64',
        backend: null,
      ).isSupported,
      isFalse,
    );
  });

  test('only LLGuidance CreateConstraint failures become schema refusals', () {
    const schema = '{"type":"string"}';
    expect(
      liteRtLmConstraintFailure(
        schema,
        'Failed to create LLGuidance constraint: unsupported schema',
      ),
      isA<ResponseFormatUnsupportedException>(),
    );
    expect(
      liteRtLmConstraintFailure(
        schema,
        'INTERNAL: Failed to create LLGuidance constraint: incompatible types',
      ),
      isA<ResponseFormatUnsupportedException>(),
    );
    expect(
      liteRtLmConstraintFailure(null, 'Failed to create LLGuidance constraint'),
      isNull,
    );
    expect(
      liteRtLmConstraintFailure(schema, 'INTERNAL: decode failed'),
      isNull,
    );
  });

  test('native handles pass their fixed schema on every send; plain handles '
      'never do', () async {
    const schema = '{"type":"string","enum":["PASS"]}';
    final client = LiteRtLmFfiClient();
    final native = _installConstraintRecorder(client);
    final seen = <String?>[];
    final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
    client.structuredSendForTest = (conv, jsonSchema) {
      seen.add(jsonSchema);
      final send = client.newTurnForTest(conv);
      sends.add(send);
      return send;
    };
    final structured = LiteRtLmConversationHandle.forTest(
      client,
      conversation: Pointer.fromAddress(0x1000),
      jsonSchema: schema,
    );
    final plain = LiteRtLmConversationHandle.forTest(
      client,
      conversation: Pointer.fromAddress(0x2000),
    );

    Future<void> turn(LiteRtLmConversationHandle handle) async {
      final result = handle.chatRawMessage('{}').toList();
      await pumpEventQueue();
      sends.last.finished();
      await result;
    }

    await turn(structured);
    await turn(plain);
    await turn(structured);
    expect(seen, [schema, null, schema]);
    expect(native.schemas, [schema, schema]);
    expect(
      native.constraintTypes,
      everyElement(
        LiteRtLmConstraintType.kLiteRtLmConstraintTypeJsonSchema.value,
      ),
    );
    expect(native.providerCalls, isEmpty);
  });

  test('virtual creation and every send retain each session schema across '
      'switches, context and failed-send rebuilds', () async {
    const schema = '{"type":"string","enum":["PASS"]}';
    final client = LiteRtLmFfiClient();
    final native = _installConstraintRecorder(client);
    final creates = <String?>[];
    final sent = <String?>[];
    final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
    final sentOn = <Pointer<LiteRtLmConversation>>[];
    var nextAddress = 0x3000;
    client
      ..structuredCreateForTest = (_, jsonSchema) async {
        creates.add(jsonSchema);
        final conv = Pointer<LiteRtLmConversation>.fromAddress(nextAddress);
        nextAddress += 0x10;
        client.registerLiveForTest(conv);
        return conv;
      }
      ..structuredSendForTest = (conv, jsonSchema) {
        sent.add(jsonSchema);
        sentOn.add(conv);
        final send = client.newTurnForTest(conv);
        sends.add(send);
        return send;
      };
    final sampling = SamplingParams.resolve(
      const SamplingParams(),
      modelType: ModelType.gemmaIt,
    );
    final structured = Object();
    final plain = Object();

    Future<void> turn(
      Object token,
      String? jsonSchema, {
      NativeLastTurnEnd end = NativeLastTurnEnd.completed,
      bool fail = false,
    }) async {
      final result = client
          .startVirtualTurn(
            conversationToken: token,
            messageJson: '{}',
            history: const [],
            sampling: sampling,
            samplingExplicit: false,
            thinking: false,
            jsonSchema: jsonSchema,
          )
          .toList();
      await pumpEventQueue();
      final send = sends.last;
      client.recordTurnEndForTest(sentOn.last, end);
      if (fail) {
        send.failed(StateError('injected send failure'));
        await expectLater(result, throwsStateError);
      } else {
        send.finished();
        await result;
      }
      await pumpEventQueue();
    }

    await turn(structured, schema); // initial structured conversation
    await turn(plain, null); // structured -> plain switch
    await turn(structured, schema); // plain -> structured switch
    await turn(
      structured,
      schema,
      end: NativeLastTurnEnd.contextFull,
      fail: true,
    );
    await turn(structured, schema); // rebuild after context-full
    await turn(
      structured,
      schema,
      end: NativeLastTurnEnd.cancelled,
      fail: true,
    );
    await turn(structured, schema); // rebuild after a stopped send
    await turn(structured, schema, fail: true);
    await turn(structured, schema); // rebuild after a failed send

    expect(sent, [
      schema,
      null,
      schema,
      schema,
      schema,
      schema,
      schema,
      schema,
      schema,
    ]);
    expect(creates, [schema, null, schema, schema, schema, schema]);
    expect(native.providerCalls, hasLength(5));
    expect(native.schemas, List.filled(8, schema));
    expect(
      native.constraintTypes,
      everyElement(
        LiteRtLmConstraintType.kLiteRtLmConstraintTypeJsonSchema.value,
      ),
    );
  });

  test('a structured virtual stop during conversation creation reports '
      'stopped, never sends, and preserves later metrics', () async {
    final client = LiteRtLmFfiClient();
    _installConstraintRecorder(client);
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x5800);
    final createStarted = Completer<void>();
    final finishCreate = Completer<void>();
    final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
    client
      ..structuredCreateForTest = (_, _) async {
        createStarted.complete();
        await finishCreate.future;
        return conv;
      }
      ..structuredSendForTest = (conversation, _) {
        final send = client.newTurnForTest(conversation);
        sends.add(send);
        return send;
      }
      ..metricsForTest = (_) => SessionMetrics(tokensPerSecond: 51);
    final model = FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.gpu,
      openSessionBacking: OpenSessionBacking.virtual,
      structuredOutput: const StructuredOutputSupport(
        keywords: ResponseFormat.dialect,
      ),
      onClose: () {},
    );
    final session = await model.openSession(
      responseFormat: ResponseFormat.jsonSchema(const {
        'type': 'string',
        'enum': ['PASS'],
      }),
    );

    await session.addQueryChunk(const Message(text: 'first', isUser: true));
    final stopped = session.getResponse();
    await createStarted.future;
    await session.stopGeneration();
    finishCreate.complete();
    await expectLater(
      stopped,
      throwsA(
        isA<IncompleteStructuredOutputException>().having(
          (error) => error.end,
          'end',
          TurnEnd.stopped,
        ),
      ),
    );
    expect(sends, isEmpty, reason: 'the pending stop must prevent native send');

    await session.addQueryChunk(const Message(text: 'second', isUser: true));
    final answered = session.getResponse();
    await pumpEventQueue();
    sends.single
      ..chunk(
        '{"role":"assistant","content":['
        '{"type":"text","text":"\\"PASS\\""}]}',
      )
      ..finished();
    expect(await answered, '"PASS"');
    await pumpEventQueue();
    expect(session.getSessionMetrics().tokensPerSecond, 51);

    await session.close();
    await model.close();
  });

  test('native recovery and a chat replacement keep the same schema', () async {
    const schema = '{"type":"string","enum":["PASS"]}';
    final client = _SchemaClient();
    final native = _installConstraintRecorder(client);
    final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
    final sentSchemas = <String?>[];
    client.structuredSendForTest = (conv, jsonSchema) {
      sentSchemas.add(jsonSchema);
      final send = NativeTurnStream(
        NativeTurns<Pointer<LiteRtLmConversation>>(
          cancelNative: (_) {},
          deleteNative: (_) {},
        ),
        conv,
      );
      sends.add(send);
      return send;
    };
    final model = FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
      openSessionBacking: OpenSessionBacking.native,
      linearAttentionState: null,
      structuredOutput: const StructuredOutputSupport(
        keywords: ResponseFormat.dialect,
      ),
      onClose: () {},
    );
    final format = ResponseFormat.jsonSchema(const {
      'type': 'string',
      'enum': ['PASS'],
    });

    Future<void> beginAndFinish(InferenceModelSession session) async {
      await session.addQueryChunk(const Message(text: 'x', isUser: true));
      final result = session.getResponseAsync().toList();
      await pumpEventQueue();
      sends.last
        ..chunk(
          '{"role":"assistant","content":['
          '{"type":"text","text":"\\"PASS\\""}]}',
        )
        ..finished();
      await result;
    }

    final session = await model.openSession(responseFormat: format);
    await beginAndFinish(session);
    await session.addQueryChunk(const Message(text: 'full', isUser: true));
    final failed = session.getResponseAsync().toList();
    await pumpEventQueue();
    client.recordTurnEndForTest(
      client.conversations.last,
      NativeLastTurnEnd.contextFull,
    );
    sends.last.failed(StateError('injected context limit'));
    await expectLater(failed, throwsA(isA<ContextLimitException>()));
    await beginAndFinish(session);
    await session.close();

    final chat = await model.openChat(responseFormat: format);
    await chat.addQueryChunk(const Message(text: 'x', isUser: true));
    final chatResult = chat.generateChatResponseAsync().toList();
    await pumpEventQueue();
    sends.last
      ..chunk(
        '{"role":"assistant","content":['
        '{"type":"text","text":"\\"PASS\\""}]}',
      )
      ..finished();
    await chatResult;

    await chat.addQueryChunk(const Message(text: 'full', isUser: true));
    final failedChat = chat.generateChatResponseAsync().toList();
    await pumpEventQueue();
    client.recordTurnEndForTest(
      client.conversations.last,
      NativeLastTurnEnd.contextFull,
    );
    sends.last.failed(StateError('injected chat context limit'));
    await expectLater(failedChat, throwsA(isA<ContextLimitException>()));

    await chat.addQueryChunk(const Message(text: 'after', isUser: true));
    final replacementResult = chat.generateChatResponseAsync().toList();
    await pumpEventQueue();
    sends.last
      ..chunk(
        '{"role":"assistant","content":['
        '{"type":"text","text":"\\"PASS\\""}]}',
      )
      ..finished();
    await replacementResult;
    await chat.close();
    await model.close();

    expect(client.createdSchemas, everyElement(schema));
    expect(sentSchemas, everyElement(schema));
    expect(client.createdSchemas.length, greaterThanOrEqualTo(4));
    expect(native.providerCalls, hasLength(client.createdSchemas.length));
    expect(native.schemas, sentSchemas);
    expect(
      native.constraintTypes,
      everyElement(
        LiteRtLmConstraintType.kLiteRtLmConstraintTypeJsonSchema.value,
      ),
    );
  });

  test('the loaded model reports the support supplied by its engine', () {
    const support = StructuredOutputSupport(keywords: ResponseFormat.dialect);
    final model = FfiInferenceModel(
      ffiClient: LiteRtLmFfiClient(),
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
      structuredOutput: support,
      onClose: () {},
    );

    expect(model.engineStructuredOutputSupport, same(support));
  });

  test('a model loaded with a thinking budget refuses formats', () {
    final model = FfiInferenceModel(
      ffiClient: _BudgetClient(),
      maxTokens: 1024,
      modelType: ModelType.gemma4,
      activeBackend: PreferredBackend.cpu,
      structuredOutput: const StructuredOutputSupport(
        keywords: ResponseFormat.dialect,
      ),
      onClose: () {},
    );

    expect(
      model.refusalFor(ResponseFormat.jsonObject()),
      isA<ResponseFormatUnsupportedException>().having(
        (error) => error.message,
        'message',
        contains('thinkingTokenBudget'),
      ),
    );
  });
}

class _BudgetClient extends LiteRtLmFfiClient {
  @override
  int? get thinkingTokenBudget => 64;
}

class _SchemaClient extends LiteRtLmFfiClient {
  final createdSchemas = <String?>[];
  final conversations = <Pointer<LiteRtLmConversation>>[];

  _SchemaClient() {
    structuredCreateForTest = (_, jsonSchema) async {
      createdSchemas.add(jsonSchema);
      final conv = Pointer<LiteRtLmConversation>.fromAddress(
        0x6000 + conversations.length * 0x10,
      );
      conversations.add(conv);
      return conv;
    };
  }
}

_ConstraintRecorder _installConstraintRecorder(LiteRtLmFfiClient client) {
  final recorder = _ConstraintRecorder();
  client
    ..bindingsForTest = recorder.bindings
    ..metricsForTest = (_) => SessionMetrics();
  addTearDown(recorder.close);
  return recorder;
}

class _ConstraintRecorder {
  _ConstraintRecorder() {
    final symbols = <String, Pointer<Void>>{
      'litert_lm_get_last_error_message': _retain(
        NativeCallable<Pointer<Char> Function()>.isolateLocal(() => nullptr),
      ),
      'litert_lm_conversation_config_set_constraint_provider': _retain(
        NativeCallable<
          UnsignedInt Function(Pointer<LiteRtLmConversationConfig>, UnsignedInt)
        >.isolateLocal((Pointer<LiteRtLmConversationConfig> _, int provider) {
          providerCalls.add(provider);
          return 0;
        }, exceptionalReturn: 1),
      ),
      'litert_lm_conversation_optional_args_set_constraint': _retain(
        NativeCallable<
          UnsignedInt Function(
            Pointer<LiteRtLmConversationOptionalArgs>,
            UnsignedInt,
            Pointer<Char>,
          )
        >.isolateLocal((
          Pointer<LiteRtLmConversationOptionalArgs> _,
          int type,
          Pointer<Char> schema,
        ) {
          constraintTypes.add(type);
          schemas.add(schema.cast<Utf8>().toDartString());
          return 0;
        }, exceptionalReturn: 1),
      ),
      'litert_lm_conversation_delete': _retain(
        NativeCallable<
          Void Function(Pointer<LiteRtLmConversation>)
        >.isolateLocal((Pointer<LiteRtLmConversation> _) {}),
      ),
      'litert_lm_conversation_cancel_process': _retain(
        NativeCallable<
          UnsignedInt Function(Pointer<LiteRtLmConversation>)
        >.isolateLocal(
          (Pointer<LiteRtLmConversation> _) => 0,
          exceptionalReturn: 1,
        ),
      ),
    };
    bindings = LiteRtLmBindings.fromLookup(
      <T extends NativeType>(String name) => symbols[name]!.cast<T>(),
    );
  }

  final providerCalls = <int>[];
  final constraintTypes = <int>[];
  final schemas = <String>[];
  final _callables = <NativeCallable>[];
  late final LiteRtLmBindings bindings;

  Pointer<Void> _retain(NativeCallable callable) {
    _callables.add(callable);
    return callable.nativeFunction.cast();
  }

  void close() {
    for (final callable in _callables) {
      callable.close();
    }
  }
}
