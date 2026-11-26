// A conversation's LoRA adapters (ConversationConfig.loraConfig, as Kotlin's
// LoraConfig): what is refused before any native call, what reaches the
// session config, and that a conversation with an adapter has its own native
// conversation where conversations otherwise share one by replay.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import '../litertlm_container_fixture.dart';

/// A client whose conversations are fakes; it keeps the extras each create
/// was given, and can fail the create as a libLiteRtLm without text LoRA
/// does.
class _LoraClient extends LiteRtLmFfiClient {
  _LoraClient({this.createError});

  final Object? createError;
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
    if (createError case final error?) throw error;
    return LiteRtLmConversationHandle.forTest(this);
  }
}

/// A `.litertlm` whose main model's `decode` signature has the one input
/// [decodeInput].
Uint8List _bundle(String decodeInput) => litertlmContainer([
  (
    type: sectionTfliteModel,
    modelType: 'tf_lite_prefill_decode',
    bytes: buildFlatBuffer(
      FbTable({
        0: FbU32(3), // Model.version
        7: FbTables([
          // SignatureDef: inputs, signature_key, subgraph_index.
          FbTable({
            0: FbTables([
              FbTable({0: FbString(decodeInput), 1: FbU32(0)}),
            ]),
            2: FbString('decode'),
            4: FbU32(0),
          }),
        ]),
      }),
    ),
  ),
]);

void main() {
  late Directory dir;
  late String loraModel;
  late String plainModel;
  late String adapter;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('conversation_lora');
    loraModel = '${dir.path}/lora.litertlm';
    File(loraModel).writeAsBytesSync(_bundle('lora_atten_q_a_prime_weight_0'));
    plainModel = '${dir.path}/plain.litertlm';
    File(plainModel).writeAsBytesSync(_bundle('input_pos'));
    adapter = '${dir.path}/task_lora.tflite';
    File(adapter).writeAsBytesSync([0]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('LoraConfig needs a path and refuses an empty one', () {
    expect(LoraConfig.new, throwsArgumentError);
    expect(() => LoraConfig(loraPath: ''), throwsArgumentError);
    expect(() => LoraConfig(audioLoraPath: ''), throwsArgumentError);
    expect(LoraConfig(loraPath: 'a'), LoraConfig(loraPath: 'a'));
    expect(
      LoraConfig(loraPath: 'a'),
      isNot(LoraConfig(loraPath: 'a', audioLoraPath: 'b')),
    );
  });

  test('a negative LoRA rank is refused; 0 and null are allowed', () {
    expect(
      () => EngineConfig(modelPath: 'm', loraRank: -1),
      throwsArgumentError,
    );
    expect(
      () => EngineConfig(modelPath: 'm', audioLoraRank: -4),
      throwsArgumentError,
    );
    expect(EngineConfig(modelPath: 'm', loraRank: 0).loraRank, 0);
    expect(EngineConfig(modelPath: 'm', audioLoraRank: 16).audioLoraRank, 16);
  });

  test('the adapters reach the session config, and the conversation has its '
      'own native conversation where conversations share one', () async {
    final client = _LoraClient();
    final engine = engineForTest(
      client,
      backing: OpenSessionBacking.virtual,
      modelPath: loraModel,
    );
    final audio = '${dir.path}/audio_lora.tflite';
    File(audio).writeAsBytesSync([0]);

    final plain = await engine.createConversation();
    expect(conversationHandle(plain), isA<VirtualConversationHandle>());
    final lora = await engine.createConversation(
      ConversationConfig(
        loraConfig: LoraConfig(loraPath: adapter, audioLoraPath: audio),
      ),
    );
    expect(conversationHandle(lora), isA<RecoveringConversationHandle>());
    expect(client.extras, hasLength(1));
    expect(client.extras.single.loraPath, adapter);
    expect(client.extras.single.audioLoraPath, audio);
    await plain.close();
    await lora.close();
  });

  test('a file that is not there is refused before any native call', () async {
    final client = _LoraClient();
    final engine = engineForTest(client, modelPath: loraModel);
    for (final config in [
      LoraConfig(loraPath: '${dir.path}/missing.tflite'),
      LoraConfig(loraPath: adapter, audioLoraPath: '${dir.path}/no.tflite'),
    ]) {
      await expectLater(
        engine.createConversation(ConversationConfig(loraConfig: config)),
        throwsA(isA<ArgumentError>()),
      );
    }
    expect(client.extras, isEmpty);
  });

  test('a model without LoRA inputs is refused, because LiteRT-LM would '
      'take the adapter and leave it without effect', () async {
    final client = _LoraClient();
    final engine = engineForTest(client, modelPath: plainModel);
    await expectLater(
      engine.createConversation(
        ConversationConfig(loraConfig: LoraConfig(loraPath: adapter)),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('no LoRA inputs'),
        ),
      ),
    );
    expect(client.extras, isEmpty);
    // The audio encoder's adapter is not checked against the text model.
    final audioOnly = await engine.createConversation(
      ConversationConfig(loraConfig: LoraConfig(audioLoraPath: adapter)),
    );
    expect(client.extras.single.audioLoraPath, adapter);
    await audioOnly.close();
  });

  test('the NPU is refused before any native call', () async {
    final client = _LoraClient();
    final engine = engineForTest(
      client,
      backend: const Backend.npu(),
      modelPath: loraModel,
    );
    await expectLater(
      engine.createConversation(
        ConversationConfig(loraConfig: LoraConfig(loraPath: adapter)),
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(client.extras, isEmpty);
  });

  test("a libLiteRtLm without text LoRA (LiteRT-LM's public source) is an "
      'UnsupportedError that names the backport; other failures pass '
      'through', () async {
    final refusing = engineForTest(
      _LoraClient(
        createError: StateError(
          'litert_lm_conversation_create failed with status INVALID_ARGUMENT '
          '(3): INVALID_ARGUMENT: Lora is not supported.',
        ),
      ),
      modelPath: loraModel,
    );
    await expectLater(
      refusing.createConversation(
        ConversationConfig(loraConfig: LoraConfig(loraPath: adapter)),
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('section 33'),
        ),
      ),
    );
    final failing = engineForTest(
      _LoraClient(createError: StateError('out of memory')),
      modelPath: loraModel,
    );
    await expectLater(
      failing.createConversation(
        ConversationConfig(loraConfig: LoraConfig(loraPath: adapter)),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
