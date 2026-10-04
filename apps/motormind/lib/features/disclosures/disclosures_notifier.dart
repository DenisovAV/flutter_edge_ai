import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/prefs.dart';

const _ackKey = 'disclosures.acknowledgedVersion';

/// True when the user has acknowledged the *current* disclosure wording.
/// Any change to a disclosure bumps `Disclosures.gateVersion` and re-prompts.
final disclosuresAcknowledgedProvider = NotifierProvider<DisclosuresAcknowledgedNotifier, bool>(
  DisclosuresAcknowledgedNotifier.new,
);

class DisclosuresAcknowledgedNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getInt(_ackKey) == Disclosures.gateVersion;
  }

  Future<void> acknowledge() async {
    await ref.read(sharedPreferencesProvider).setInt(_ackKey, Disclosures.gateVersion);
    state = true;
  }

  /// For the "wipe my data" action and for tests.
  Future<void> reset() async {
    await ref.read(sharedPreferencesProvider).remove(_ackKey);
    state = false;
  }
}
