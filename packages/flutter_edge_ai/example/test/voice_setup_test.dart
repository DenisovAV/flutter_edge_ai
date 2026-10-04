// Device-free widget tests for the Voice Loop setup: the default model trio,
// and the LLM picker's `modelFilter` (it must not offer models the loop can't
// network-install — built-in or localModel asset entries). Pure navigation /
// filtering, no model download / FFI / device.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai_example/model_selection_screen.dart';
import 'package:flutter_edge_ai_example/voice_setup_screen.dart';

void main() {
  testWidgets('VoiceSetupScreen renders the default STT / LLM / TTS trio', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: VoiceSetupScreen()));
    // Defaults are SttModel.moonshineTiny / Model.gemma3_1B / TtsModel.matcha.
    expect(find.text('Moonshine Tiny'), findsOneWidget);
    expect(find.text('Gemma 3 1B IT'), findsOneWidget);
    expect(find.text('Matcha-TTS'), findsOneWidget);
  });

  testWidgets(
    'ModelSelectionScreen.modelFilter excludes localModel asset entries',
    (tester) async {
      // `localModel` entries are kept by every platform filter, so no platform
      // override is needed. Keep ONLY the excluded categories first: the
      // "(Local)" card is in a short list, so it renders — proving the entry
      // exists in the catalog.
      await tester.pumpWidget(
        MaterialApp(
          home: ModelSelectionScreen(modelFilter: (m) => m.localModel),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Gemma 3 1B IT (Local)'),
        findsOneWidget,
        reason: 'the local-asset LLM exists in the catalog',
      );

      // The exact filter the Voice Loop LLM picker uses: the "(Local)" entry is
      // filtered OUT of the list entirely (never built, regardless of scroll).
      await tester.pumpWidget(
        MaterialApp(
          home: ModelSelectionScreen(
            modelFilter: (m) => !m.isBuiltIn && !m.localModel,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Gemma 3 1B IT (Local)'),
        findsNothing,
        reason:
            'the Voice Loop LLM picker must not offer non-network-installable '
            'models — it installs via installModel(...).fromNetwork(url)',
      );
    },
  );
}
