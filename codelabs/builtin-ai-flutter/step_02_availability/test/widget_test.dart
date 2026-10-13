import 'package:builtin_ai_codelab/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the availability card before plugin calls complete', (
    tester,
  ) async {
    BuiltInAi.debugProbeTimeout = Duration.zero;
    addTearDown(() {
      BuiltInAi.debugProbeTimeout = const Duration(seconds: 20);
    });
    await tester.pumpWidget(const MaterialApp(home: AvailabilityPage()));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Device status'), findsOneWidget);
  });
}
