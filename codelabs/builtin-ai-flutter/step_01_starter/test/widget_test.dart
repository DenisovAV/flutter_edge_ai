import 'package:builtin_ai_codelab/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the starter shows the card and a disabled composer', (
    tester,
  ) async {
    await tester.pumpWidget(const BuiltInAiApp());

    expect(find.text('Device status'), findsOneWidget);
    expect(find.textContaining('engine is registered'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
