import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/main.dart';

void main() {
  testWidgets('the shell runs and says there is no model yet', (tester) async {
    await tester.pumpWidget(const QuickstartApp());
    expect(find.textContaining('No model on the device yet'), findsOneWidget);
  });
}
