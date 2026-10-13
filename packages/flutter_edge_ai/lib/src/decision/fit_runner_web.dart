// Web: no isolates to spare, so the fit runs inline, after one event-loop
// turn. A large `linear` fit blocks the page while it runs.

import 'decider_fit.dart';

/// Runs [fitDecider] on this isolate.
Future<DeciderFit> runDeciderFit(DeciderFitRequest request) async {
  await Future<void>.delayed(Duration.zero);
  return fitDecider(request);
}
