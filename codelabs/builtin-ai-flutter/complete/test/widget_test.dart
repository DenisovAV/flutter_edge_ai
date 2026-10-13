import 'package:builtin_ai_codelab/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the finished app starts with one clear action', (tester) async {
    await tester.pumpWidget(const BuiltInAiApp());
    expect(find.text('Start built-in AI'), findsOneWidget);
    expect(find.textContaining('prepare the OS model'), findsOneWidget);
  });
}
