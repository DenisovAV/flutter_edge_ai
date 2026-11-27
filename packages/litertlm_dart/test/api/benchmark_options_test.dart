// benchmark()'s Kotlin options on the VM: loraConfig reaches the benchmark
// conversation's session config and repetitionPenaltyConfig the message's
// send. A fake EngineHost stands in for the native engine create and a fake
// client for the conversation; the run itself then fails reading a native
// record that is not there, after both have been handed over.
@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:litertlm_dart/bindings.dart' show LiteRtLmConversation;
import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import '../litertlm_container_fixture.dart';

/// Keeps the extras of each conversation it creates and the options of each
/// send, which completes at once.
class _Client extends LiteRtLmFfiClient {
  final extras = <ConversationExtras>[];
  var _next = 0x7300;

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
    final conversation = Pointer<LiteRtLmConversation>.fromAddress(
      _next += 0x10,
    );
    registerLiveForTest(conversation);
    structuredSendForTest = (c, _) {
      final send = newTurnForTest(c);
      Future.microtask(send.finished);
      return send;
    };
    return LiteRtLmConversationHandle.forTest(this, conversation: conversation);
  }
}

class _Host extends EngineHost {
  _Host(this.client);

  final _Client client;

  @override
  String get abi => 'macos_arm64';

  @override
  LiteRtLmFfiClient createClient() => client;

  @override
  Future<bool?> linearAttentionState(String path) async => false;

  @override
  Future<void> initializeClient(
    LiteRtLmFfiClient client, {
    required String modelPath,
    required String backend,
    required int? maxTokens,
    int? maxVisionTokensPerImage,
    int? contextWindow,
    required String? cacheDir,
    required bool enableVision,
    required String visionBackend,
    required int maxNumImages,
    required bool enableAudio,
    required String audioBackend,
    required bool? enableSpeculativeDecoding,
    required int? speculativeDecodingMode,
    double? speculativeDecodingLenience,
    List<String>? selectedSignatures,
    int? loraRank,
    int? audioLoraRank,
    required int? numThreads,
    required int? activationDataType,
    required GpuActivationReason? gpuActivationReason,
    required NpuDispatch? npuDispatch,
    required LiteRtLmLogLevel? nativeLogLevel,
    BenchmarkTokens? benchmarkTokens,
  }) async {}
}

/// A `.litertlm` whose main model's `decode` signature takes a LoRA input.
Uint8List _loraBundle() => litertlmContainer([
  (
    type: sectionTfliteModel,
    modelType: 'tf_lite_prefill_decode',
    bytes: buildFlatBuffer(
      FbTable({
        0: FbU32(3),
        7: FbTables([
          FbTable({
            0: FbTables([
              FbTable({
                0: FbString('lora_atten_q_a_prime_weight_0'),
                1: FbU32(0),
              }),
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
  late _Client client;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('benchmark_options');
    client = _Client();
    debugEngineHost = _Host(client);
  });
  tearDown(() {
    debugEngineHost = null;
    dir.deleteSync(recursive: true);
  });

  test('loraConfig reaches the conversation and repetitionPenaltyConfig the '
      'send', () async {
    final model = (File(
      '${dir.path}/m.litertlm',
    )..writeAsBytesSync(_loraBundle())).path;
    final adapter = (File('${dir.path}/a.tflite')..writeAsBytesSync([0])).path;
    final penalty = RepetitionPenaltyConfig(repetitionPenalty: 1.2);
    await expectLater(
      benchmark(
        modelPath: model,
        backend: const Backend.cpu(),
        loraConfig: LoraConfig(loraPath: adapter),
        repetitionPenaltyConfig: penalty,
      ),
      throwsA(anything),
      reason: 'no native benchmark record behind the fake',
    );
    expect(client.extras.single.loraPath, adapter);
    expect(client.lastSendOptionsForTest?.repetitionPenalty, same(penalty));
  });

  test('without them: no LoRA, no penalty', () async {
    final model = (File(
      '${dir.path}/m.litertlm',
    )..writeAsBytesSync(_loraBundle())).path;
    await expectLater(
      benchmark(modelPath: model, backend: const Backend.cpu()),
      throwsA(anything),
    );
    expect(client.extras.single.loraPath, isNull);
    expect(client.lastSendOptionsForTest?.repetitionPenalty, isNull);
  });
}
