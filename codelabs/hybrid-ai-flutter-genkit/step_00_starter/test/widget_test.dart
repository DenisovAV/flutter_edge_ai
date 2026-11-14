import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:workshop_genkit_flutter_hybrid_ai/main.dart';
import 'package:workshop_genkit_flutter_hybrid_ai/models/message_model.dart';
import 'package:workshop_genkit_flutter_hybrid_ai/widgets/message_bubble.dart';

void main() {
  testWidgets('the shell runs and invites the first message', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('AI Chat'), findsOneWidget);
    expect(find.text('Send a message to start chatting'), findsOneWidget);
  });

  testWidgets('a bubble takes its side from isUser', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            MessageBubble(message: ChatMessage(text: 'hi', isUser: true)),
            MessageBubble(message: ChatMessage(text: 'hello', isUser: false)),
          ],
        ),
      ),
    );

    Alignment sideOf(String text) =>
        tester
                .widget<Align>(
                  find
                      .ancestor(
                        of: find.text(text),
                        matching: find.byType(Align),
                      )
                      .first,
                )
                .alignment
            as Alignment;

    expect(sideOf('hi'), Alignment.centerRight);
    expect(sideOf('hello'), Alignment.centerLeft);
  });
}
