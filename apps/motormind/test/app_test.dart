import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/app/app.dart';
import 'package:motormind/app/prefs.dart';
import 'package:motormind/features/advisor/advisor_surface.dart';
import 'package:motormind/features/advisor/stage_view.dart';
import 'package:motormind/features/disclosures/disclosures_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Widget> _app({int? acknowledgedVersion}) async {
  SharedPreferences.setMockInitialValues({
    DisclosuresAcknowledgedNotifier.ackKey: ?acknowledgedVersion,
  });
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      webPaneBuilderProvider.overrideWithValue(() => const SizedBox(key: Key('browser-pane'))),
    ],
    child: const MotormindApp(),
  );
}

void main() {
  testWidgets('first launch shows the disclosure gate with every disclosure', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gate-acknowledge')), findsOneWidget);
    for (final d in Disclosures.all) {
      expect(find.byKey(ValueKey('disclosure-${d.key}')), findsOneWidget);
    }
  });

  testWidgets('acknowledging the gate opens home and persists', (tester) async {
    await tester.pumpWidget(await _app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gate-acknowledge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-bubble')), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(DisclosuresAcknowledgedNotifier.ackKey), Disclosures.gateVersion);
  });

  testWidgets('an acknowledged current version skips the gate; an old version does not', (
    tester,
  ) async {
    await tester.pumpWidget(await _app(acknowledgedVersion: Disclosures.gateVersion));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-bubble')), findsOneWidget);

    await tester.pumpWidget(await _app(acknowledgedVersion: Disclosures.gateVersion - 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gate-acknowledge')), findsOneWidget);
  });

  testWidgets('the surface cycles collapsed → docked → fullscreen → collapsed', (tester) async {
    await tester.pumpWidget(await _app(acknowledgedVersion: Disclosures.gateVersion));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('surface-bubble')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-docked')), findsOneWidget);
    await tester.tap(find.byKey(const Key('surface-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-fullscreen')), findsOneWidget);
    await tester.tap(find.byKey(const Key('surface-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-bubble')), findsOneWidget);
  });

  test('model requests and the person\'s control both move the surface', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(surfaceProvider.notifier);
    n.request(SurfaceState.fullscreen);
    expect(container.read(surfaceProvider), SurfaceState.fullscreen);
    n.request(SurfaceState.collapsed);
    expect(container.read(surfaceProvider), SurfaceState.collapsed);
    n.userSet(SurfaceState.docked);
    expect(container.read(surfaceProvider), SurfaceState.docked);
  });
}
