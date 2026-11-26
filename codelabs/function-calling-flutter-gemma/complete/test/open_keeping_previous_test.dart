import 'package:edge_ai_quickstart/chat_page.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Switching to `required` on a device whose runtime cannot apply a tool
  // choice must not strand the page on its load error: the engine refuses at
  // open, and the chat reopens with the setting that worked.
  test(
    'a refused setting reopens with the previous one and says why',
    () async {
      final opened = <(ToolChoice, bool)>[];
      final result = await openKeepingPrevious(
        (choice, thinking) async {
          opened.add((choice, thinking));
          if (choice == ToolChoice.required) {
            throw UnsupportedError(
              'ToolChoice.required cannot be applied here',
            );
          }
          return 'chat';
        },
        next: (ToolChoice.required, false),
        previous: (ToolChoice.auto, false),
      );
      expect(opened, [(ToolChoice.required, false), (ToolChoice.auto, false)]);
      expect(result.chat, 'chat');
      expect(result.settings, (ToolChoice.auto, false));
      expect(result.refusal, contains('ToolChoice.required'));
    },
  );

  test('an accepted setting opens once, with no refusal', () async {
    final result = await openKeepingPrevious(
      (choice, thinking) async => '$choice',
      next: (ToolChoice.none, true),
      previous: (ToolChoice.auto, false),
    );
    expect(result.settings, (ToolChoice.none, true));
    expect(result.refusal, isNull);
  });

  test('any other failure is thrown', () async {
    await expectLater(
      openKeepingPrevious<String>(
        (choice, thinking) async => throw StateError('closed'),
        next: (ToolChoice.required, false),
        previous: (ToolChoice.auto, false),
      ),
      throwsStateError,
    );
  });
}
