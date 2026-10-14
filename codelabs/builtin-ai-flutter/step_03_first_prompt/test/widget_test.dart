import 'package:builtin_ai_codelab/main.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('starts with the device status card', (tester) async {
    BuiltInAi.debugProbeTimeout = Duration.zero;
    addTearDown(() {
      BuiltInAi.debugProbeTimeout = const Duration(seconds: 20);
    });
    await tester.pumpWidget(const BuiltInAiApp());
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Device status'), findsOneWidget);
  });
}
