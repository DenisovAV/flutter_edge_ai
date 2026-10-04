import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/disclosures/disclosure_gate_screen.dart';
import '../features/disclosures/disclosures_notifier.dart';
import '../features/disclosures/disclosures_screen.dart';
import '../features/home/home_screen.dart';

abstract final class Routes {
  static const home = '/';
  static const gate = '/welcome';
  static const disclosures = '/disclosures';
}

/// The router. The `redirect` is the disclosure gate (ADR 0004): until the
/// current disclosure version has been acknowledged, every route goes to the
/// gate, and the full disclosures page stays reachable from it.
final routerProvider = Provider<GoRouter>((ref) {
  final acknowledged = ref.watch(disclosuresAcknowledgedProvider);
  return GoRouter(
    initialLocation: Routes.home,
    redirect: (context, state) {
      final atGate = state.matchedLocation == Routes.gate;
      final atDisclosures = state.matchedLocation == Routes.disclosures;
      if (!acknowledged && !atGate && !atDisclosures) return Routes.gate;
      if (acknowledged && atGate) return Routes.home;
      return null;
    },
    routes: [
      GoRoute(path: Routes.home, builder: (context, state) => const HomeScreen()),
      GoRoute(path: Routes.gate, builder: (context, state) => const DisclosureGateScreen()),
      GoRoute(path: Routes.disclosures, builder: (context, state) => const DisclosuresScreen()),
    ],
  );
});
