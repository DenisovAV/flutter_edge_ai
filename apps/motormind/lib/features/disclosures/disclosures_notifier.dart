import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/prefs.dart';

/// True when the user has acknowledged the *current* disclosure wording.
/// Any change to a disclosure bumps `Disclosures.gateVersion` and re-prompts.
final disclosuresAcknowledgedProvider = NotifierProvider<DisclosuresAcknowledgedNotifier, bool>(
  DisclosuresAcknowledgedNotifier.new,
);

/// Whether the current disclosure version has been acknowledged; the gate
/// redirects until it has.
class DisclosuresAcknowledgedNotifier extends Notifier<bool> {
  /// Preferences key holding the acknowledged disclosure version.
  static const ackKey = 'disclosures.acknowledgedVersion';

  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getInt(ackKey) == Disclosures.gateVersion;
  }

  Future<void> acknowledge() async {
    await ref.read(sharedPreferencesProvider).setInt(ackKey, Disclosures.gateVersion);
    state = true;
  }

  /// For the "wipe my data" action and for tests.
  Future<void> reset() async {
    await ref.read(sharedPreferencesProvider).remove(ackKey);
    state = false;
  }
}
