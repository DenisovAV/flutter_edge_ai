// litertlm_dart throws LiteRtLmNativeException for a failed LiteRT-LM call;
// core's apps keep catching what they always caught.
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

import '../ffi/ffi_test_support.dart';

class _FailingClient extends LiteRtLmFfiClient {
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
  }) async => throw const lm.LiteRtLmNativeException(
    'Failed to create conversation (INTERNAL)',
  );
}

void main() {
  for (final backing in OpenSessionBacking.values) {
    test('a conversation LiteRT-LM did not create is a plain Exception to '
        'core ($backing backing)', () async {
      final model = ffiModelForClient(
        ffiClient: _FailingClient(),
        maxTokens: 1024,
        modelType: ModelType.gemmaIt,
        activeBackend: PreferredBackend.cpu,
        openSessionBacking: backing,
        onClose: () {},
      );
      final Matcher plain = isA<Exception>()
          .having((e) => e, 'type', isNot(isA<lm.LiteRtLmException>()))
          .having(
            (e) => '$e',
            'text',
            'Exception: Failed to create conversation (INTERNAL)',
          );
      // ignore: deprecated_member_use
      await expectLater(model.createSession(), throwsA(plain));
      if (backing == OpenSessionBacking.native) {
        await expectLater(model.openSession(), throwsA(plain));
      }
    });
  }

  test('a failed tokenize is the StateError core always got', () async {
    await expectLater(
      liteRtLmAsStateError<int>(
        () async => throw const lm.LiteRtLmNativeException('tokenize failed'),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'tokenize failed',
        ),
      ),
    );
    expect(await liteRtLmAsStateError(() async => 3), 3);
  });
}
