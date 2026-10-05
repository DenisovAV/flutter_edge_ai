import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_gemma/src/tool_choice_parse.dart';

void main() {
  group('parseToolChoice', () {
    test('maps each valid string to the matching enum', () {
      expect(parseToolChoice('auto'), gemma.ToolChoice.auto);
      expect(parseToolChoice('required'), gemma.ToolChoice.required);
      expect(parseToolChoice('none'), gemma.ToolChoice.none);
    });

    test('null returns auto (unset)', () {
      expect(parseToolChoice(null), gemma.ToolChoice.auto);
    });

    test(
      'an unknown value throws INVALID_ARGUMENT instead of defaulting to auto',
      () {
        // The dangerous case: a 'none' typo must NOT silently re-enable tools.
        expect(
          () => parseToolChoice('non'),
          throwsA(
            isA<GenkitException>()
                .having((e) => e.status, 'status', StatusCodes.INVALID_ARGUMENT)
                .having((e) => e.message, 'message', contains('none')),
          ),
        );
        expect(
          () => parseToolChoice('REQUIRED'),
          throwsA(isA<GenkitException>()),
        );
      },
    );
  });
}
