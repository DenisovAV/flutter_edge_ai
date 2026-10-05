import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_gemma/src/backend_parse.dart';

void main() {
  group('parsePreferredBackend', () {
    test('maps each valid string to the matching enum', () {
      // npu is exercised ONLY here — the model/embedder tests all use gpu/cpu,
      // so a `case 'npu': return gpu` typo would otherwise ship silently.
      expect(parsePreferredBackend('cpu'), gemma.PreferredBackend.cpu);
      expect(parsePreferredBackend('gpu'), gemma.PreferredBackend.gpu);
      expect(parsePreferredBackend('npu'), gemma.PreferredBackend.npu);
    });

    test('null returns null', () {
      expect(parsePreferredBackend(null), isNull);
    });

    test('unknown value throws INVALID_ARGUMENT naming the field', () {
      // The `field:` label must reach the message so the user learns WHICH
      // parameter was bad — the model-layer invalid test asserts status only.
      expect(
        () => parsePreferredBackend('tpu', field: 'preferredAudioBackend'),
        throwsA(
          isA<GenkitException>()
              .having((e) => e.status, 'status', StatusCodes.INVALID_ARGUMENT)
              .having(
                (e) => e.message,
                'message',
                contains('preferredAudioBackend'),
              ),
        ),
      );
    });
  });
}
