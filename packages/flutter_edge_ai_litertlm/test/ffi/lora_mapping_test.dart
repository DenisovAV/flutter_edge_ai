// Core's LoRA on a .litertlm model: a session's loraPath (openSession,
// openChat, createSession) becomes litertlm_dart's LoraConfig, the adapter
// reaches the native session config, and RuntimeConfig.loraRanks gives the
// engine its one LoRA rank.
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine.dart'
    show liteRtLmLoraRank;
import 'package:flutter_test/flutter_test.dart';
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
    ConversationExtras extras = ConversationExtras.none,
    required bool filterChannelContent,
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
      'down to the native session config', () async {
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

  test('the singleton session (createSession) takes loraPath too', () async {
    final client = _Client();
    // ignore: deprecated_member_use
    final session = await model(client).createSession(loraPath: adapter);
    expect(client.extras.single.loraPath, adapter);
    await session.close();
  });

  test('a session without loraPath has no LoraConfig', () async {
    final client = _Client();
    final session =
        await model(client).openEngineSession(SessionRequest())
            as FfiInferenceModelSession;
    expect(conversationConfig(session.conversation).loraConfig, isNull);
    await session.close();
  });

  test('loraRanks: one rank is the engine rank, none is none, several are '
      'refused by name', () {
    expect(liteRtLmLoraRank(null), isNull);
    expect(liteRtLmLoraRank(const []), isNull);
    expect(liteRtLmLoraRank(const [16]), 16);
    expect(
      () => liteRtLmLoraRank(const [4, 8, 16]),
      throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'loraRanks')),
    );
  });
}
