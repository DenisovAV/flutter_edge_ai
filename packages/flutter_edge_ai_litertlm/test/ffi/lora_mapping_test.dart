// Core's LoRA on a .litertlm model: a session's loraPath (openSession,
// openChat, the legacy createSession) becomes litertlm_dart's LoraConfig, and
// the adapter reaches the native conversation config.
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal.dart' show conversationConfig;
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;

import 'ffi_test_support.dart';

/// A client whose conversations are fakes, keeping the extras of each.
class _Client extends LiteRtLmFfiClient {
  final extras = <ConversationExtras>[];

  @override
  BundleSampler get bundleSampler => const BundleSampler();

  @override
  Future<LiteRtLmConversationHandle> createConversationHandle({
    String? systemMessage,
    String? toolsJson,
    String? messagesJson,
    required Sampler sampling,
    required bool samplingExplicit,
    int? maxOutputTokens,
    required MediaOrder multimodalOrder,
    Constraint? constraint,
    required bool filterChannelContent,
    ConversationExtras extras = ConversationExtras.none,
  }) async {
    this.extras.add(extras);
    return LiteRtLmConversationHandle.forTest(this);
  }
}

void main() {
  late Directory dir;
  late String adapter;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lora_mapping');
    adapter = '${dir.path}/task_lora.tflite';
    File(adapter).writeAsBytesSync([0]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  FfiInferenceModel model(_Client client) {
    final m = ffiModelForClient(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.functionGemma,
      activeBackend: PreferredBackend.cpu,
      openSessionBacking: OpenSessionBacking.virtual,
      onClose: () {},
    );
    addTearDown(m.close);
    return m;
  }

  test('an open session with loraPath gets the adapter as its LoraConfig, '
      'down to the native conversation config', () async {
    final client = _Client();
    final session =
        await model(client).openEngineSession(SessionRequest(loraPath: adapter))
            as FfiInferenceModelSession;
    expect(
      conversationConfig(session.conversation).loraConfig?.loraPath,
      adapter,
    );
    expect(client.extras.single.loraPath, adapter);
    await session.close();
  });

  test(
    'the legacy singleton session (createSession) takes loraPath too',
    () async {
      final client = _Client();
      // ignore: deprecated_member_use
      final session = await model(client).createSession(loraPath: adapter);
      expect(client.extras.single.loraPath, adapter);
      await session.close();
    },
  );

  test('a session without loraPath has no LoraConfig', () async {
    final client = _Client();
    final session =
        await model(client).openEngineSession(SessionRequest())
            as FfiInferenceModelSession;
    expect(conversationConfig(session.conversation).loraConfig, isNull);
    await session.close();
  });

  test('a loraPath that is not there is refused by name, before any '
      'conversation', () async {
    final client = _Client();
    await expectLater(
      model(client).openEngineSession(
        SessionRequest(loraPath: '${dir.path}/missing.tflite'),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(client.extras, isEmpty);
  });
}
