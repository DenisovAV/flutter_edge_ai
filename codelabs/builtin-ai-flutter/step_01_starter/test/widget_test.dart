import 'package:flutter_test/flutter_test.dart';
import 'package:builtin_ai_codelab/main.dart';

void main() {
  testWidgets('the starter explains the next step', (tester) async {
    await tester.pumpWidget(const BuiltInAiApp());
    expect(find.textContaining('engine is registered'), findsOneWidget);
  });
}
